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
//   "ai_direct_provider"    → "openai" | "anthropic" | "openmodels"
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
    // Open-models ("openmodels") provider: the selected vendor (ollama|neuralwatt)
    // and its model id. The vendor implies the base URL + Keychain key via ProviderRegistry.
    static let keyOpenModelsVendor = "ai_openmodels_vendor"
    static let keyOpenModelsModel = "ai_openmodels_model"

    /// The Keychain provider id for a resolved cloud model — replaces the old
    /// `cloudModel == .openAI ? "openai" : "anthropic"` ternary so the open vendors map
    /// to their own keys (zai/moonshot/minimax).
    static func keychainKeyID(for model: CloudModel) -> String {
        switch model {
        case .openAI: return "openai"
        case .anthropic: return "anthropic"
        case .gemini: return "gemini"
        case .openRouter: return "openrouter"
        case .openModels(let vendor): return ProviderRegistry.descriptor(for: vendor).keychainKeyID
        }
    }

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
        let (cloudModel, openAIModel, anthropicModel, openModelsModel) = try resolveConfiguration()
        let providerKey = Self.keychainKeyID(for: cloudModel)
        guard let key = keyStore.key(for: providerKey), !key.isEmpty else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        let provider = BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel,
            openModelsModel: openModelsModel
        )
        let router = ProviderRouter(onDeviceAvailable: false, byoKey: cloudModel)
        let client = AIClient(router: router) { tier in
            if case .cloudBYOKey = tier { return provider }
            return nil
        }
        return try await client.generate(request)
    }

    /// Multimodal variant of `generate()` for the vision features (ingredient
    /// identification, cook-check): resolves the same BYO-key provider, then calls
    /// `BYOKeyProvider.generateWithImage` directly instead of routing through
    /// `AIClient` (image bytes aren't part of the generic `AIRequest`/`AIProvider`
    /// seam). Throws the same `AIServiceError.noKeyConfigured` /
    /// `noProviderConfigured` as `generate()`; provider HTTP/parse errors propagate
    /// as `AIError.*`.
    func generateVision(_ request: AIRequest, imageData: Data, mimeType: String) async throws -> AIResponse {
        let (cloudModel, openAIModel, anthropicModel, openModelsModel) = try resolveConfiguration()
        let providerKey = Self.keychainKeyID(for: cloudModel)
        guard let key = keyStore.key(for: providerKey), !key.isEmpty else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        let provider = BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel,
            openModelsModel: openModelsModel
        )
        return try await provider.generateWithImage(request, imageData: imageData, mimeType: mimeType)
    }

    // MARK: - Seasonal produce (SP-D port)

    /// One AI call per (region, year, month) combination — mirrors
    /// `seasonal_ai.py`'s module-level `_CACHE` dict so a user relaunching the app
    /// mid-month doesn't re-spend their own key on an answer that hasn't changed.
    /// `static` (not per-instance) so it survives an `AIService` rebuild (a fresh
    /// instance is created each household-session boot) for the process lifetime;
    /// safe unguarded because every caller is `@MainActor` (this class's isolation).
    ///
    /// simmersmith-blv: because it is process-lifetime and keyed ONLY by
    /// `region|year|month`, it must be CLEARED at household teardown — otherwise a
    /// different iCloud account signing in on this device (or the same user after a
    /// factory reset) is served the PREVIOUS household's AI output for the same
    /// region/month. `AppState.teardownHouseholdSession()` calls `clearSeasonalCache()`
    /// at the same choke point that resets `syncStatusCenter` and the leftover-household
    /// lists, for exactly the same cross-household-bleed reason.
    private static var seasonalCache: [String: [SeasonalAIItem]] = [:]

    /// Drop every cached seasonal answer. Called from the household-teardown choke point.
    static func clearSeasonalCache() {
        seasonalCache.removeAll()
    }

    /// Fetch (or return the cached) in-season produce list for `region` in
    /// `year`/`month`. Builds the prompt via `SeasonalPrompt`, calls `generate()`,
    /// and parses via `SeasonalAIParser`; the caller (AppState+Seasonal) maps the
    /// wire items onto the domain `InSeasonItem`.
    func fetchSeasonalProduce(region: String, year: Int, month: Int) async throws -> [SeasonalAIItem] {
        let cacheKey = "\(region)|\(year)|\(month)"
        if let cached = Self.seasonalCache[cacheKey] {
            return cached
        }
        let prompt = SeasonalPrompt.build(region: region, year: year, month: month)
        let request = AIRequest(feature: .seasonal, prompt: prompt, wantsStructuredJSON: true)
        let response = try await generate(request)
        let items = try SeasonalAIParser.parse(response.text)
        Self.seasonalCache[cacheKey] = items
        return items
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
        let (cloudModel, openAIModel, anthropicModel, openModelsModel) = try resolveConfiguration()
        let provider = BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel,
            openModelsModel: openModelsModel
        )
        let providerKey = Self.keychainKeyID(for: cloudModel)
        guard let key = keyStore.key(for: providerKey), !key.isEmpty else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        _ = try await provider.listModels()
        return providerKey
    }

    /// List the models the user's key can call, for the given provider, so Settings
    /// can offer a dropdown instead of a free-text field. Builds a provider for the
    /// REQUESTED provider (independent of the currently-saved one), so the dropdown
    /// can populate for whichever provider the user has selected in the draft.
    /// Throws `noKeyConfigured` when that provider has no key, `unsupportedProvider`
    /// for anything but openai/anthropic, or an `AIError.*` on provider failure.
    func listModels(for providerID: String) async throws -> [String] {
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cloudModel: CloudModel
        switch provider {
        case "openai":    cloudModel = .openAI
        case "anthropic": cloudModel = .anthropic
        default:
            // Open-models vendors are keyed by their Keychain id (zai/moonshot/minimax).
            if let vendor = ProviderRegistry.vendor(forKeychainID: provider) {
                cloudModel = .openModels(vendor)
            } else {
                throw AIServiceError.unsupportedProvider(providerID)
            }
        }
        guard hasKey(for: provider) else {
            throw AIServiceError.noKeyConfigured(provider)
        }
        let byo = BYOKeyProvider(model: cloudModel, keyStore: keyStore)
        return try await byo.listModels()
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
    func loadAISettings() -> (provider: String, openAIModel: String, anthropicModel: String, openModelsVendor: String, openModelsModel: String) {
        guard let store = session.privateStore else { return ("", "", "", "", "") }
        // Normalize to match resolveConfiguration() — downstream (the Settings model
        // Picker, field routing) compares against lowercase "openai"/"anthropic"/"openmodels".
        let provider = ((try? store.profileSetting(key: Self.keyProvider))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let oaModel = (try? store.profileSetting(key: Self.keyOpenAIModel))?.value ?? ""
        let anModel = (try? store.profileSetting(key: Self.keyAnthropicModel))?.value ?? ""
        let omVendor = ((try? store.profileSetting(key: Self.keyOpenModelsVendor))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let omModel = (try? store.profileSetting(key: Self.keyOpenModelsModel))?.value ?? ""
        return (provider, oaModel, anModel, omVendor, omModel)
    }

    // MARK: - Assistant provider factory (SP-C AI-5)

    /// Build a `BYOKeyProvider` for the assistant tool-calling loop. Throws
    /// `AIServiceError.noProviderConfigured` or `AIServiceError.noKeyConfigured`
    /// when the provider or key isn't set — identical gate as `generate()`.
    func makeAssistantProvider() throws -> BYOKeyProvider {
        let (cloudModel, openAIModel, anthropicModel, openModelsModel) = try resolveConfiguration()
        let providerKey = Self.keychainKeyID(for: cloudModel)
        guard hasKey(for: providerKey) else {
            throw AIServiceError.noKeyConfigured(providerKey)
        }
        return BYOKeyProvider(
            model: cloudModel,
            keyStore: keyStore,
            openAIModel: openAIModel,
            anthropicModel: anthropicModel,
            openModelsModel: openModelsModel
        )
    }

    // MARK: - Provider resolution

    private func resolveConfiguration() throws -> (CloudModel, openAIModel: String, anthropicModel: String, openModelsModel: String) {
        guard let store = session.privateStore else {
            throw AIServiceError.noProviderConfigured
        }
        let providerRaw = ((try? store.profileSetting(key: Self.keyProvider))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !providerRaw.isEmpty else {
            throw AIServiceError.noProviderConfigured
        }
        let cloudModel: CloudModel
        var openModelsModel = ""
        switch providerRaw {
        case "openai":    cloudModel = .openAI
        case "anthropic": cloudModel = .anthropic
        case "openmodels":
            let vendorRaw = ((try? store.profileSetting(key: Self.keyOpenModelsVendor))?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            // Empty means "accept the displayed default". Hidden legacy vendors (direct
            // GLM/Kimi/MiniMax or OpenRouter) are remapped to Ollama Cloud here too, so a
            // session that never opens Settings cannot keep routing through OpenRouter.
            // Matches resolvedOpenVendor.
            let vendor: OpenModelVendor
            let dropStoredOpenModelsModel: Bool
            if vendorRaw.isEmpty {
                vendor = .ollamaCloud
                dropStoredOpenModelsModel = false
            } else if let v = OpenModelVendor(rawValue: vendorRaw), ProviderRegistry.allOpenModelVendors.contains(v) {
                vendor = v
                dropStoredOpenModelsModel = false
            } else if OpenModelVendor(rawValue: vendorRaw) != nil {
                vendor = .ollamaCloud
                dropStoredOpenModelsModel = true
            } else {
                throw AIServiceError.unsupportedProvider("openmodels:\(vendorRaw)")
            }
            cloudModel = .openModels(vendor)
            openModelsModel = dropStoredOpenModelsModel ? "" : ((try? store.profileSetting(key: Self.keyOpenModelsModel))?.value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        default: throw AIServiceError.unsupportedProvider(providerRaw)
        }
        let rawOpenAI = ((try? store.profileSetting(key: Self.keyOpenAIModel))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAnthropic = ((try? store.profileSetting(key: Self.keyAnthropicModel))?.value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            cloudModel,
            rawOpenAI.isEmpty ? "gpt-4o" : rawOpenAI,
            rawAnthropic.isEmpty ? "claude-opus-4-5" : rawAnthropic,
            openModelsModel
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
            return "No AI provider is selected. Open Settings → AI and choose a provider."
        case .noKeyConfigured(let provider):
            // Map a vendor keychain id (zai/moonshot/minimax) to its friendly display name.
            let label = ProviderRegistry.vendor(forKeychainID: provider)?.displayName ?? provider.capitalized
            return "No \(label) API key is saved. Open Settings → AI and enter your key."
        case .unsupportedProvider(let p):
            return "Provider \"\(p)\" is not supported in this version."
        }
    }
}
#endif
