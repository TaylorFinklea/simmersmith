import Foundation

// SP-C AI-2 — RecipeURLFetcher: on-device URL fetch for deterministic recipe import.
//
// Safety posture (spec §1, §5): the device is not a server, but a recipe-import URL
// is user-supplied, so we still refuse to probe the local network:
//   • HTTPS-only (reject http:// and any other scheme).
//   • Reject localhost / loopback, RFC-1918 private (10/8, 172.16-31/12, 192.168/16),
//     CGNAT (100.64.0.0/10 — RFC 6598 carrier-grade NAT, routed to internal infra on
//     some networks), link-local (169.254/16, IPv6 fe80::/10), unique-local IPv6
//     (fc00::/7), IPv6 loopback (::1), and `.local` mDNS hostnames.
//   • When the host is a HOSTNAME (not a literal IP), RESOLVE it and reject if ANY
//     resolved address is private/internal — so a public name that points at
//     127.0.0.1 / 169.254.169.254 (cloud metadata) fails the guard (the server does
//     the same in parser.py `_validated_ip_for`, which checks every getaddrinfo
//     record).
//   • Re-validate EACH redirect hop (a public host can 30x to a private one). The
//     production transport drives URLSession through a delegate that re-runs the host
//     guard on every redirect target and cancels on failure, capping the hop count.
//   • Stream the body and abort once it exceeds the cap (~2 MB) so a hostile page
//     can't exhaust memory before the size is checked.
//
// RESIDUAL (documented, not closed here): full DNS-rebinding defense would PIN the
// connection to the exact IP we validated (parser.py `_pinned_connect_url` does this
// server-side). On-device we re-resolve at connect time, so a low-TTL record could in
// principle pass the getaddrinfo check then flip to a private address for the actual
// fetch. This is a much lower threat for a device client than for a server (no
// privileged internal network to reach), so connection pinning is a follow-up.
//
// The HTTP transport is injectable (mirrors AIProviderKit's `HTTPTransport`) so the
// host guard + body cap + redirect decision are headlessly testable with no real
// network.

/// Abstraction over `URLSession` so `RecipeURLFetcher` is headlessly testable.
/// Mirrors AIProviderKit's `HTTPTransport`; kept local so SimmerSmithKit has no
/// hard dependency on AIProviderKit just for fetching.
public protocol RecipeHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default production transport. Backs a `URLSession` whose delegate re-validates
/// every redirect target against the host guard (C1) and caps the redirect count,
/// then streams the response body so the size cap (I1) aborts before a hostile page
/// is fully buffered.
public struct URLSessionRecipeTransport: RecipeHTTPTransport {
    private let maxBytes: Int

    public init(maxBytes: Int = RecipeURLFetcher.defaultMaxBytes) {
        self.maxBytes = maxBytes
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // A fresh delegate-backed session per fetch keeps the redirect validator
        // self-contained (no shared mutable state) and is cheap for a one-shot import.
        let delegate = RedirectValidatingSessionDelegate()
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        // Stream the body so the size cap aborts a hostile page mid-download (I1)
        // rather than buffering the whole thing first.
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RecipeURLFetchError.httpStatus(http.statusCode)
        }
        var data = Data()
        let expected = response.expectedContentLength
        if expected > 0 {
            data.reserveCapacity(min(Int(expected), maxBytes))
        }
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                throw RecipeURLFetchError.bodyTooLarge(data.count)
            }
        }
        return (data, response)
    }
}

/// `URLSession` delegate that re-validates EACH redirect target (C1). A public host
/// can return a 30x to a private one; `URLSession`'s automatic redirect-following does
/// no per-hop check, so we intercept here, re-run `RecipeURLFetcher.validatedURL` on
/// the new target, and CANCEL (hand the completion handler `nil`) when it fails or the
/// hop cap is exceeded.
private final class RedirectValidatingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirectCount = 0

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectCount += 1
        guard redirectCount <= RecipeURLFetcher.maxRedirects,
              let url = request.url,
              (try? RecipeURLFetcher.validatedURL(url.absoluteString)) != nil
        else {
            // Cancel the redirect: nil tells URLSession to stop following and treat
            // the 30x response as the final one (which then fails the 200 check).
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

public enum RecipeURLFetchError: Error, Equatable {
    /// The URL string could not be parsed into a URL with a host.
    case invalidURL
    /// The scheme is not https.
    case insecureScheme(String)
    /// The host resolves to localhost / a private / link-local range, or is `.local`.
    case privateHost(String)
    /// The server returned a non-200 status.
    case httpStatus(Int)
    /// The body exceeded the size cap.
    case bodyTooLarge(Int)
}

public struct RecipeURLFetcher: Sendable {
    /// ~2 MB body cap (spec §2 "cap body size").
    public static let defaultMaxBytes = 2 * 1024 * 1024
    /// Max redirect hops the production transport follows; each is re-validated.
    public static let maxRedirects = 5

    private let transport: RecipeHTTPTransport
    private let maxBytes: Int

    public init(
        transport: RecipeHTTPTransport? = nil,
        maxBytes: Int = RecipeURLFetcher.defaultMaxBytes
    ) {
        self.transport = transport ?? URLSessionRecipeTransport(maxBytes: maxBytes)
        self.maxBytes = maxBytes
    }

    /// Validate the URL against the host guard, then fetch and return the HTML string.
    /// Throws `RecipeURLFetchError` for guard failures, non-200, or oversize bodies.
    public func fetchHTML(from urlString: String) async throws -> String {
        let url = try Self.validatedURL(urlString)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.data(for: request)
        // Injected test transports (and any transport not streaming through
        // URLSessionRecipeTransport) still get the status + cap checks here.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RecipeURLFetchError.httpStatus(http.statusCode)
        }
        guard data.count <= maxBytes else {
            throw RecipeURLFetchError.bodyTooLarge(data.count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Host guard

    /// Parse + validate a URL string: https-only, host present, host not local/private,
    /// and — for hostnames — not resolving to any private/internal address. Public +
    /// static so the guard (and the redirect re-validation in C1) is unit-testable
    /// without a transport.
    public static func validatedURL(_ urlString: String) throws -> URL {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty
        else {
            throw RecipeURLFetchError.invalidURL
        }
        let scheme = (url.scheme ?? "").lowercased()
        guard scheme == "https" else {
            throw RecipeURLFetchError.insecureScheme(scheme)
        }
        guard !isPrivateHost(host) else {
            throw RecipeURLFetchError.privateHost(host)
        }
        // Literal-IP hosts are already covered by isPrivateHost. For HOSTNAMES, resolve
        // and reject if any A/AAAA record is private/internal (C2b) — defeats a public
        // name pointing at 127.0.0.1 / 169.254.169.254 (the server checks every record).
        if ipv4Octets(host) == nil, !host.contains(":"), hostResolvesToPrivate(host) {
            throw RecipeURLFetchError.privateHost(host)
        }
        return url
    }

    /// True when `host` is localhost, a `.local` mDNS name, or a literal IP in a
    /// loopback / private / CGNAT / link-local / unique-local range.
    public static func isPrivateHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]")) // strip IPv6 brackets

        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "local" || host.hasSuffix(".local") { return true }

        // IPv4 literal?
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        // IPv6 literal?
        if host.contains(":") {
            return isPrivateIPv6(host)
        }
        return false
    }

    /// Resolve `host` via `getaddrinfo` and return true if ANY resolved address is
    /// private/internal (C2b). A resolution failure returns false — the subsequent
    /// fetch will fail on its own; we don't want a transient DNS hiccup to look like a
    /// security rejection. Mirrors parser.py `_validated_ip_for`, which iterates every
    /// `socket.getaddrinfo` record and rejects on the first internal one.
    private static func hostResolvesToPrivate(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC      // both A + AAAA
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
            return false
        }
        defer { freeaddrinfo(head) }

        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            if let sa = current.pointee.ai_addr {
                if let literal = numericAddress(sa, family: current.pointee.ai_family),
                   isPrivateHost(literal) {
                    return true
                }
            }
            node = current.pointee.ai_next
        }
        return false
    }

    /// Render a resolved sockaddr as its numeric IP string (so it can be re-checked by
    /// `isPrivateHost`'s literal-IP path).
    private static func numericAddress(_ sa: UnsafeMutablePointer<sockaddr>, family: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length: socklen_t
        switch family {
        case AF_INET: length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6: length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default: return nil
        }
        guard getnameinfo(sa, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    /// Parse a dotted-quad into 4 octets, or nil if not a well-formed IPv4 literal.
    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber),
                  let value = Int(part), (0...255).contains(value)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ o: [Int]) -> Bool {
        // 0.0.0.0/8 (this host) + 127/8 loopback
        if o[0] == 0 || o[0] == 127 { return true }
        // 10/8
        if o[0] == 10 { return true }
        // 172.16/12 → 172.16.0.0 .. 172.31.255.255
        if o[0] == 172, (16...31).contains(o[1]) { return true }
        // 192.168/16
        if o[0] == 192, o[1] == 168 { return true }
        // 169.254/16 link-local
        if o[0] == 169, o[1] == 254 { return true }
        // 100.64.0.0/10 CGNAT (RFC 6598). The server blocks it too (parser.py
        // `_CGNAT_NETWORK`): some networks route shared-NAT space to internal infra,
        // making it a live SSRF target that the RFC-1918 checks miss.
        if o[0] == 100, (64...127).contains(o[1]) { return true }
        return false
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        // Drop a zone id (fe80::1%en0) and any port already removed by URL.host.
        let addr = host.split(separator: "%").first.map(String.init) ?? host
        if addr == "::1" || addr == "::" { return true }
        if addr.hasPrefix("fe80") || addr.hasPrefix("fe8") || addr.hasPrefix("fe9")
            || addr.hasPrefix("fea") || addr.hasPrefix("feb") {
            return true // fe80::/10 link-local
        }
        if addr.hasPrefix("fc") || addr.hasPrefix("fd") {
            return true // fc00::/7 unique-local
        }
        // IPv4-mapped (::ffff:10.0.0.1) — guard the embedded v4 too.
        if let mapped = addr.split(separator: ":").last.map(String.init),
           mapped.contains("."), let octets = ipv4Octets(mapped) {
            return isPrivateIPv4(octets)
        }
        return false
    }
}
