import Foundation

// SP-C AI-2 — RecipeURLFetcher: on-device URL fetch for deterministic recipe import.
//
// Safety posture (spec §1, §5): the device is not a server, but a recipe-import URL
// is user-supplied, so we still refuse to probe the local network:
//   • HTTPS-only (reject http:// and any other scheme).
//   • Reject localhost / loopback, RFC-1918 private (10/8, 172.16-31/12, 192.168/16),
//     link-local (169.254/16, IPv6 fe80::/10), unique-local IPv6 (fc00::/7),
//     IPv6 loopback (::1), and `.local` mDNS hostnames.
//   • Cap the response body (~2 MB) so a hostile page can't exhaust memory.
//
// The HTTP transport is injectable (mirrors AIProviderKit's `HTTPTransport`) so the
// host guard + body cap are headlessly testable with no real network.

/// Abstraction over `URLSession` so `RecipeURLFetcher` is headlessly testable.
/// Mirrors AIProviderKit's `HTTPTransport`; kept local so SimmerSmithKit has no
/// hard dependency on AIProviderKit just for fetching.
public protocol RecipeHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default production transport backed by `URLSession.shared`.
public struct URLSessionRecipeTransport: RecipeHTTPTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
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

    private let transport: RecipeHTTPTransport
    private let maxBytes: Int

    public init(
        transport: RecipeHTTPTransport = URLSessionRecipeTransport(),
        maxBytes: Int = RecipeURLFetcher.defaultMaxBytes
    ) {
        self.transport = transport
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
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RecipeURLFetchError.httpStatus(http.statusCode)
        }
        guard data.count <= maxBytes else {
            throw RecipeURLFetchError.bodyTooLarge(data.count)
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Host guard

    /// Parse + validate a URL string: https-only, host present, host not local/private.
    /// Public + static so the guard is unit-testable without a transport.
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
        return url
    }

    /// True when `host` is localhost, a `.local` mDNS name, or a literal IP in a
    /// loopback / private / link-local / unique-local range.
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
