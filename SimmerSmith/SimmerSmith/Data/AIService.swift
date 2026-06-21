#if canImport(CloudKit)
import Foundation
import AIProviderKit

// SP-C AI-1 — AIService: the single seam every AppState AI method uses.
//
// Responsibilities:
//   • Read the configured provider + model from the private plane (direct store read).
//   • Check whether the user has a key for that provider in the Keychain.
//   • Build a BYOKeyProvider with the KeychainKeyStore.
//   • Route via ProviderRouter and call the provider.
//   • Surface clear typed errors for "no key" and provider failures.
//
// AI setting keys in the private plane (PrivateProfileSetting):
//   "ai_direct_provider"    → "openai" | "anthropic"
//   "ai_openai_model"       → e.g. "gpt-4o"
//   "ai_anthropic_model"    → e.g. "claude-opus-4-5"
//
// Keys NEVER go to the private plane or CloudKit — they live in KeychainKeyStore only.
//
// All callers are @MainActor (AppState extensions) so @MainActor isolation is correct.

@MainActor
final class AIService {

    // MARK: - Setting keys (private plane)

    static let keyProvider = "ai_direct_provider"
    static let keyOpenAIModel = "ai_openai_model"
    static let keyAnthropicModel = "ai_anthropic_model"

    // MARK: - Dependencies

    private let keyStore: KeychainKeyStore
    private let session: HouseholdSession

    init(keyStore: KeychainKeyStore = KeychainKeyStore(), session: HouseholdSession) {
        self.keyStore = keyStore
        self.session = session
    }

    // MARK: - AI call seam

    /// Resolve the configured provider, build a BYOKeyProvider, and call it.
    /// Throws `AIServiceError.noKeyConfigured` when no key is in Keychain for the
    /// chosen provider, or `AIServiceError.noProviderConfigured` when no provider
    /// is selected. Provider HTTP/parse errors propagate as `AIError.*`.
    func generate(_ request: AIRequest) async throws -> AIResponse {
        let (cloudModel, openAIModel, anthropicModel) = try resolveConfiguration()
        let provider = BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel
        )
        let providerKey = cloudModel == .openAI ? "openai" : "anthropic"
        guard let key = keyStore.key(for: providerKey), !key.isEmpty else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        return try await provider.generate(request)
    }

    /// Validate the key by listing models — cheap, no generation. Returns the
    /// provider name ("openai" / "anthropic") on success so the UI can confirm.
    func testKey() async throws -> String {
        let (cloudModel, openAIModel, anthropicModel) = try resolveConfiguration()
        let provider = BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel
        )
        let providerKey = cloudModel == .openAI ? "openai" : "anthropic"
        guard let key = keyStore.key(for: providerKey), !key.isEmpty else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        _ = try await provider.listModels()
        return providerKey
    }

    // MARK: - Key management (Keychain)

    func saveKey(_ key: String, for providerID: String) {
        keyStore.setKey(key.isEmpty ? nil : key, for: providerID)
    }

    func clearKey(for providerID: String) {
        keyStore.setKey(nil, for: providerID)
    }

    func hasKey(for providerID: String) -> Bool {
        guard let k = keyStore.key(for: providerID) else { return false }
        return !k.isEmpty
    }

    // MARK: - Settings reads (direct from private plane store)

    /// Read the AI provider/model settings from the private plane store.
    func loadAISettings() -> (provider: String, openAIModel: String, anthropicModel: String) {
        guard let store = session.privateStore else { return ("", "", "") }
        let provider = (try? store.profileSetting(key: Self.keyProvider))?.value ?? ""
        let oaModel = (try? store.profileSetting(key: Self.keyOpenAIModel))?.value ?? ""
        let anModel = (try? store.profileSetting(key: Self.keyAnthropicModel))?.value ?? ""
        return (provider, oaModel, anModel)
    }

    // MARK: - Provider resolution

    private func resolveConfiguration() throws -> (CloudModel, openAIModel: String, anthropicModel: String) {
        guard let store = session.privateStore else {
            throw AIServiceError.noProviderConfigured
        }
        let providerRaw = ((try? store.profileSetting(key: Self.keyProvider))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !providerRaw.isEmpty else {
            throw AIServiceError.noProviderConfigured
        }
        let cloudModel: CloudModel
        switch providerRaw {
        case "openai":    cloudModel = .openAI
        case "anthropic": cloudModel = .anthropic
        default: throw AIServiceError.unsupportedProvider(providerRaw)
        }
        let rawOpenAI = ((try? store.profileSetting(key: Self.keyOpenAIModel))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAnthropic = ((try? store.profileSetting(key: Self.keyAnthropicModel))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            cloudModel,
            rawOpenAI.isEmpty ? "gpt-4o" : rawOpenAI,
            rawAnthropic.isEmpty ? "claude-opus-4-5" : rawAnthropic
        )
    }
}

// MARK: - AIServiceError

enum AIServiceError: Error, LocalizedError {
    case noProviderConfigured
    case noKeyConfigured(String)
    case unsupportedProvider(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No AI provider is selected. Open Settings → AI and choose OpenAI or Anthropic."
        case .noKeyConfigured(let provider):
            return "No \(provider.capitalized) API key is saved. Open Settings → AI and enter your key."
        case .unsupportedProvider(let p):
            return "Provider \"\(p)\" is not supported in this version."
        }
    }
}
#endif
