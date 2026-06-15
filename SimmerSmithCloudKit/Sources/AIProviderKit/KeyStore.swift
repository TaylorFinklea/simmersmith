import Foundation

/// BYO-key storage. Keys live in the device Keychain, NEVER in CloudKit (SP-A §7.1:
/// the per-user `ai_*_api_key` ProfileSetting rows are dropped at migration). The
/// protocol lets the router/tests use an in-memory double; production uses Keychain.
public protocol KeyStore: Sendable {
    func key(for provider: String) -> String?
    func setKey(_ key: String?, for provider: String)
}

/// Test/double in-memory store.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()
    public init() {}
    public func key(for provider: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return storage[provider]
    }
    public func setKey(_ key: String?, for provider: String) {
        lock.lock(); defer { lock.unlock() }
        if let key { storage[provider] = key } else { storage[provider] = nil }
    }
}

#if canImport(Security)
import Security

/// Keychain-backed BYO-key store (generic password items, one per provider).
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "app.simmersmith.ai-keys") { self.service = service }

    private func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider]
    }

    public func key(for provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setKey(_ key: String?, for provider: String) {
        SecItemDelete(query(provider) as CFDictionary)   // clear existing
        guard let key, let data = key.data(using: .utf8) else { return }
        var add = query(provider)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
#endif
