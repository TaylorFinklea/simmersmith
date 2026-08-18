import Foundation

final class AIDataSharingConsentStore {
    static let currentPolicyVersion = 1

    private let defaults: UserDefaults
    private let policyVersion: Int
    private let keyPrefix = "app.simmersmith.ai-data-sharing-consent."

    init(
        defaults: UserDefaults = .standard,
        policyVersion: Int = AIDataSharingConsentStore.currentPolicyVersion
    ) {
        self.defaults = defaults
        self.policyVersion = policyVersion
    }

    func hasConsent(for providerID: String) -> Bool {
        guard let key = storageKey(for: providerID) else { return false }
        return defaults.integer(forKey: key) == policyVersion
    }

    func grant(for providerID: String) {
        guard let key = storageKey(for: providerID) else { return }
        defaults.set(policyVersion, forKey: key)
    }

    func revoke(for providerID: String) {
        guard let key = storageKey(for: providerID) else { return }
        defaults.removeObject(forKey: key)
    }

    private func storageKey(for providerID: String) -> String? {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return keyPrefix + normalized
    }
}
