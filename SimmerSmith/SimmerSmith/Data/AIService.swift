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

    /// Resolve the configured provider, route via `ProviderRouter` + `AIClient`, and call it.
    /// The router's `.cloudBYOKey` tier is used for heavy features (weekGen) — this keeps the
    /// SP-A routing seam live so no-key / coming-soon paths are honored.
    /// Throws `AIServiceError.noKeyConfigured` when no key is in Keychain for the chosen
    /// provider, or `AIServiceError.noProviderConfigured` when no provider is selected.
    /// Provider HTTP/parse errors propagate as `AIError.*`.
    func generate(_ request: AIRequest) async throws -> AIResponse {
        let (cloudModel, openAIModel, anthropicModel) = try resolveConfiguration()
        let providerKey = cloudModel == .openAI ? "openai" : "anthropic"
        guard let key = keyStore.key(for: providerKey), !key.isEmpty else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        let provider = BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel
        )
        let router = ProviderRouter(onDeviceAvailable: false, byoKey: cloudModel)
        let client = AIClient(router: router) { tier in
            if case .cloudBYOKey = tier { return provider }
            return nil
        }
        return try await client.generate(request)
    }

    // MARK: - Image generation

    /// Keychain provider ID for the Gemini image key. Separate from the text
    /// provider so an Anthropic-text user can still key in OpenAI/Gemini for images.
    static let keychainGeminiImageKey = "gemini"

    /// True when a Gemini image key is saved in the Keychain.
    var hasGeminiImageKey: Bool { hasKey(for: Self.keychainGeminiImageKey) }

    /// Generate a recipe header image for the given recipe fields.
    ///
    /// Reads `image_provider` from the private plane to pick the provider:
    ///   • `"openai"` (default) — reuses the OpenAI Keychain key (the same one text calls use).
    ///   • `"gemini"` — uses the Gemini Keychain key (separate from the text key).
    ///
    /// Failover: if `image_provider == openai` and the call fails transiently (5xx/429/network)
    /// AND a Gemini key exists in the Keychain, retries once via Gemini. Gemini-primary → no
    /// failover (user chose Gemini explicitly). Ports `recipe_image_ai.generate_recipe_image`.
    ///
    /// Throws `AIServiceError.noKeyConfigured` when the resolved provider has no key.
    func generateRecipeImage(
        name: String,
        cuisine: String = "",
        ingredients: [String] = []
    ) async throws -> (Data, String) {
        guard let store = session.privateStore else {
            throw AIServiceError.noProviderConfigured
        }
        let raw = ((try? store.profileSetting(key: "image_provider"))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let imageProvider: ImageProvider = (raw == "gemini") ? .gemini : .openAI

        let prompt = RecipeImagePrompt.build(name: name, cuisine: cuisine, ingredients: ingredients)
        let provider = ImageGenProvider()

        switch imageProvider {
        case .gemini:
            guard let key = keyStore.key(for: "gemini"), !key.isEmpty else {
                throw AIServiceError.noKeyConfigured("Gemini image")
            }
            return try await provider.generateImage(prompt: prompt, provider: .gemini, key: key)

        case .openAI:
            guard let key = keyStore.key(for: "openai"), !key.isEmpty else {
                throw AIServiceError.noKeyConfigured("OpenAI image")
            }
            do {
                return try await provider.generateImage(prompt: prompt, provider: .openAI, key: key)
            } catch let err as AIError {
                // Transient error + Gemini key available → failover once to Gemini.
                // Decision is isolated in ImageGenProvider.shouldFailoverToGemini (AI-4 F2).
                let geminiKey = keyStore.key(for: "gemini") ?? ""
                if ImageGenProvider.shouldFailoverToGemini(error: err, hasGeminiKey: !geminiKey.isEmpty) {
                    return try await provider.generateImage(
                        prompt: prompt, provider: .gemini, key: geminiKey)
                }
                throw err
            }
        }
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
