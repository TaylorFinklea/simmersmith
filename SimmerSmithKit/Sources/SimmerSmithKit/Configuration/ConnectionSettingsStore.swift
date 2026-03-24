import Foundation

public struct ServerConnection: Equatable, Sendable {
    public var serverURLString: String
    public var authToken: String

    public init(serverURLString: String = "", authToken: String = "") {
        self.serverURLString = serverURLString
        self.authToken = authToken
    }
}

public final class ConnectionSettingsStore: @unchecked Sendable {
    public static let shared = ConnectionSettingsStore()

    public enum Keys {
        public static let serverURL = "simmersmith.serverURL"
        public static let authToken = "simmersmith.authToken"
        public static let authTokenFallback = "simmersmith.authTokenFallback"
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = .shared) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func load() -> ServerConnection {
        ServerConnection(
            serverURLString: defaults.string(forKey: Keys.serverURL) ?? "",
            authToken: keychain.string(forKey: Keys.authToken)
                ?? defaults.string(forKey: Keys.authTokenFallback)
                ?? ""
        )
    }

    public func save(serverURLString: String, authToken: String) {
        let normalizedURL = Self.normalizeServerURL(serverURLString)
        defaults.set(normalizedURL, forKey: Keys.serverURL)
        if authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.removeObject(forKey: Keys.authTokenFallback)
            keychain.delete(Keys.authToken)
        } else {
            defaults.set(authToken, forKey: Keys.authTokenFallback)
            keychain.set(authToken, forKey: Keys.authToken)
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.authTokenFallback)
        keychain.delete(Keys.authToken)
    }

    public static func normalizeServerURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var components = URLComponents(string: withScheme),
              let scheme = components.scheme,
              let host = components.host else {
            return withScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let port = components.port.map { ":\($0)" } ?? ""
        let user = components.user.map { "\($0)@" } ?? ""
        let password = components.password.map { ":\($0)" } ?? ""
        components.path = ""
        components.query = nil
        components.fragment = nil
        return "\(scheme)://\(user)\(password)\(host)\(port)"
    }
}
