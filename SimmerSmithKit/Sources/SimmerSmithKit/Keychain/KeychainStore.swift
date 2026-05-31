import Foundation
import Security
import os.log

public final class KeychainStore: @unchecked Sendable {
    public static let shared = KeychainStore()

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.simmersmith.ios",
        category: "keychain"
    )

    private let service: String

    public init(service: String = Bundle.main.bundleIdentifier ?? "app.simmersmith.ios") {
        self.service = service
    }

    public func string(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func set(_ value: String, forKey key: String) -> OSStatus {
        let data = Data(value.utf8)

        // Try insert first, fall back to update on duplicate. This is atomic
        // — no check-then-act TOCTOU window where two concurrent set() calls
        // both see "absent" and both SecItemAdd, dropping the second write
        // with an ignored errSecDuplicateItem (M45).
        var insertQuery = baseQuery(forKey: key)
        insertQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return errSecSuccess
        }
        if addStatus == errSecDuplicateItem {
            let attributes = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery(forKey: key) as CFDictionary,
                attributes as CFDictionary
            )
            if updateStatus != errSecSuccess {
                // Surface the failure instead of swallowing it (M44) — a
                // silent failure leaves a stale/missing token with no
                // diagnostic. Key is a non-sensitive constant; never log
                // the value.
                Self.log.error("Keychain set (update) failed for key \(key, privacy: .public): \(updateStatus)")
            }
            return updateStatus
        }
        Self.log.error("Keychain set (add) failed for key \(key, privacy: .public): \(addStatus)")
        return addStatus
    }

    @discardableResult
    public func delete(_ key: String) -> OSStatus {
        let status = SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        // A missing item is the desired end state, so treat it as success.
        if status == errSecSuccess || status == errSecItemNotFound {
            return errSecSuccess
        }
        Self.log.error("Keychain delete failed for key \(key, privacy: .public): \(status)")
        return status
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            // Explicitly require an unlocked device to access auth tokens, and
            // pin the item to this device only so it is never synced through
            // iCloud Keychain. This prevents the token from traveling to other
            // devices signed into the same Apple ID.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
    }
}
