import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import AIProviderKit
#endif

// SP-C AI-1 — AppState+AI: AI settings wiring.
//
// Provider/model → private-plane PrivateProfileSetting (ProfileRepository).
//   Keys: "ai_direct_provider" / "ai_openai_model" / "ai_anthropic_model"
// API key → KeychainKeyStore (NEVER Fly / CloudKit — SP-A §7.1).
// "Save AI Settings" no longer touches Fly.
//
// The Fly-backed `saveAISettings` is replaced by `saveAISettingsCK` below.
// The legacy `providerAPIKeyConfigured` reads from Keychain (not Fly secretFlags).

extension AppState {

    // MARK: - Save AI settings (CloudKit + Keychain path)

    func saveAISettings(clearStoredAPIKey: Bool = false) async {
        #if canImport(CloudKit)
        if let repo = profileRepository, let aiSvc = aiService {
            let provider = aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let openAIModel = aiOpenAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let anthropicModel = aiAnthropicModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let openModelsVendor = aiOpenModelsVendorDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let openModelsModel = aiOpenModelsModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)

            // Provider + model → private plane (not CloudKit household, not Fly).
            // ProfileRepository accepts any key via upsertProfileSetting; we use
            // the AI-track keys defined in AIService.
            if let store = householdSession?.privateStore {
                do {
                    try store.upsertProfileSetting(key: AIService.keyProvider, value: provider)
                    // Always upsert — including an empty value — so clearing a model
                    // back to the default actually clears storage instead of leaving
                    // the old value behind to be re-hydrated. resolveConfiguration()
                    // maps an empty stored value to the provider default at call time.
                    try store.upsertProfileSetting(key: AIService.keyOpenAIModel, value: openAIModel)
                    try store.upsertProfileSetting(key: AIService.keyAnthropicModel, value: anthropicModel)
                    try store.upsertProfileSetting(key: AIService.keyOpenModelsVendor, value: openModelsVendor)
                    try store.upsertProfileSetting(key: AIService.keyOpenModelsModel, value: openModelsModel)
                    try store.save()
                    repo.reload()
                } catch {
                    lastErrorMessage = "Failed to save AI provider settings: \(error.localizedDescription)"
                }
            }

            // API key → Keychain (never Fly, never CloudKit). For "openmodels" the key
            // belongs to the SELECTED vendor (Ollama Cloud / NeuralWatt), not the literal
            // "openmodels" provider string.
            let keychainID = openModelsKeychainID(provider: provider, vendor: openModelsVendor)
            if clearStoredAPIKey {
                if let keychainID { aiSvc.clearKey(for: keychainID) }
                aiDirectAPIKeyDraft = ""
            } else {
                let trimmedKey = aiDirectAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedKey.isEmpty {
                    if let keychainID {
                        aiSvc.saveKey(trimmedKey, for: keychainID)
                        aiDirectAPIKeyDraft = ""
                    } else {
                        // Never silently swallow a typed key — tell the user why it didn't save.
                        lastErrorMessage = "Couldn't save the API key — select a provider and model first."
                        return
                    }
                }
            }
            lastErrorMessage = nil
            return
        }
        #endif
        // Fly fallback (pre-CloudKit session or non-CloudKit build).
        guard hasSavedConnection else { return }
        do {
            var settings: [String: String] = [
                "ai_provider_mode": aiProviderModeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                "ai_direct_provider": aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                "ai_openai_model": aiOpenAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                "ai_anthropic_model": aiAnthropicModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let normalizedProvider = aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let selectedProviderKey = selectedProviderAPIKeySetting(for: normalizedProvider)
            let trimmedKey = aiDirectAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if clearStoredAPIKey {
                if let selectedProviderKey {
                    settings[selectedProviderKey] = ""
                }
                settings["ai_direct_api_key"] = ""
            } else if !trimmedKey.isEmpty, let selectedProviderKey {
                settings[selectedProviderKey] = trimmedKey
            }
            let fetchedProfile = try await apiClient.updateProfile(settings: settings)
            profile = fetchedProfile
            syncAIDrafts(from: fetchedProfile)
            try? cacheStore.saveProfile(fetchedProfile)
            await refreshAIModels(for: aiDirectProviderDraft)
            if let health = try? await apiClient.fetchHealth() {
                aiCapabilities = health.aiCapabilities
            }
            syncPhase = .synced(.now)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Test key (CloudKit path)

    /// Validate the saved key with a cheap models-list call. Returns a user-facing
    /// result string. Only available when the CloudKit session + AIService are live.
    func testAIKey() async -> String {
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            return "AI service not available yet — try again after iCloud loads."
        }
        do {
            let provider = try await aiSvc.testKey()
            return "\(friendlyProviderLabel(provider)) key is valid."
        } catch let err as AIServiceError {
            return err.localizedDescription
        } catch let err as AIError {
            return aiErrorMessage(err)
        } catch {
            return "Key test failed: \(error.localizedDescription)"
        }
        #else
        return "Key testing requires iCloud."
        #endif
    }

    // MARK: - Refresh AI models (CloudKit path — key-aware dropdown)

    /// Populate `ckAIModelOptions[provider]` for the Settings → AI model Picker.
    /// Seeds the curated fallback immediately so the Picker is never empty, then —
    /// when a key is configured for `providerID` — fetches the provider's live
    /// `/v1/models` and curates it (chat models, best-first). On any failure (no
    /// key, offline, provider error) the fallback stays and a short reason is
    /// recorded. Safe to call repeatedly (on appear, provider change, after save).
    func refreshCKAIModels(for providerID: String) async {
        #if canImport(CloudKit)
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept the two named providers plus the open-model vendor keychain ids
        // (zai/moonshot/minimax). AIModelCatalog + AIService.listModels both key by these.
        let isOpenVendor = ProviderRegistry.vendor(forKeychainID: provider) != nil
        guard provider == "openai" || provider == "anthropic" || isOpenVendor else { return }

        if ckAIModelOptions[provider]?.isEmpty ?? true {
            ckAIModelOptions[provider] = AIModelCatalog.fallback(for: provider)
        }

        guard let svc = aiService, svc.hasKey(for: provider) else {
            // No key yet → fallback only (the key-status row already nudges the user).
            ckAIModelFetchError[provider] = nil
            return
        }

        isFetchingAIModels[provider] = true
        defer { isFetchingAIModels[provider] = false }
        do {
            let raw = try await svc.listModels(for: provider)
            let curated = AIModelCatalog.curatedModels(provider: provider, rawIDs: raw)
            ckAIModelOptions[provider] = curated.isEmpty
                ? AIModelCatalog.fallback(for: provider)
                : curated
            ckAIModelFetchError[provider] = nil
        } catch {
            // Keep the already-seeded fallback; surface a short reason.
            ckAIModelFetchError[provider] = modelFetchErrorMessage(error)
        }
        #endif
    }

    #if canImport(CloudKit)
    private func modelFetchErrorMessage(_ error: Error) -> String {
        if let svcErr = error as? AIServiceError { return svcErr.localizedDescription }
        if let aiErr = error as? AIError { return aiErrorMessage(aiErr) }
        return "Couldn't load models: \(error.localizedDescription)"
    }
    #endif

    // MARK: - Refresh AI models (Fly path — for the model picker)

    func refreshAIModels(for providerID: String) async {
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSavedConnection else { return }
        guard !normalizedProvider.isEmpty else {
            availableAIModelsByProvider = [:]
            aiModelErrorByProvider = [:]
            return
        }
        do {
            let payload = try await apiClient.fetchProviderModels(providerID: normalizedProvider)
            availableAIModelsByProvider[normalizedProvider] = payload.models
            aiModelErrorByProvider[normalizedProvider] = nil
            switch normalizedProvider {
            case "openai":
                aiOpenAIModelDraft = payload.selectedModelId ?? payload.models.first?.modelId ?? aiOpenAIModelDraft
            case "anthropic":
                aiAnthropicModelDraft = payload.selectedModelId ?? payload.models.first?.modelId ?? aiAnthropicModelDraft
            default:
                break
            }
        } catch {
            aiModelErrorByProvider[normalizedProvider] = error.localizedDescription
            availableAIModelsByProvider[normalizedProvider] = []
        }
    }

    // MARK: - Draft sync

    func syncAIDrafts(from profile: ProfileSnapshot) {
        let savedMode = profile.settings["ai_provider_mode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiProviderModeDraft = savedMode.isEmpty ? "auto" : savedMode
        aiDirectProviderDraft = profile.settings["ai_direct_provider"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiOpenAIModelDraft = profile.settings["ai_openai_model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiAnthropicModelDraft = profile.settings["ai_anthropic_model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiDirectAPIKeyDraft = ""
    }

    /// Hydrate AI drafts from the private plane after the CloudKit session is ready.
    /// Called by ensureHouseholdSession after repos + aiService are wired.
    func syncAIDraftsFromRepo() {
        #if canImport(CloudKit)
        guard let aiSvc = aiService else { return }
        let s = aiSvc.loadAISettings()
        if !s.provider.isEmpty { aiDirectProviderDraft = s.provider }
        if !s.openAIModel.isEmpty { aiOpenAIModelDraft = s.openAIModel }
        if !s.anthropicModel.isEmpty { aiAnthropicModelDraft = s.anthropicModel }
        if !s.openModelsVendor.isEmpty { aiOpenModelsVendorDraft = s.openModelsVendor }
        if !s.openModelsModel.isEmpty { aiOpenModelsModelDraft = s.openModelsModel }
        #endif
    }

    #if canImport(CloudKit)
    /// Map the selected provider (+ vendor for "openmodels") to its Keychain id.
    /// openai/anthropic key by their own name; openmodels keys by the selected
    /// visible vendor (ollama/neuralwatt). Nil when nothing resolvable is selected.
    private func openModelsKeychainID(provider: String, vendor: String) -> String? {
        switch provider {
        case "openai", "anthropic": return provider
        case "openmodels":
            guard let v = resolvedOpenVendor(vendor) else { return nil }
            return ProviderRegistry.descriptor(for: v).keychainKeyID
        default: return provider.isEmpty ? nil : provider
        }
    }

    /// Resolve an open-models vendor draft, defaulting EMPTY or hidden legacy vendors to
    /// Ollama Cloud so "accept the default" keys/persists a resolvable config and no new
    /// runtime path routes through OpenRouter. A non-empty unrecognized value stays nil.
    func resolvedOpenVendor(_ raw: String) -> OpenModelVendor? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !r.isEmpty else { return .ollamaCloud }
        guard let vendor = OpenModelVendor(rawValue: r) else { return nil }
        return ProviderRegistry.allOpenModelVendors.contains(vendor) ? vendor : .ollamaCloud
    }

    /// Friendly label for a Keychain provider id — vendor displayName for the visible
    /// open vendors (ollama → "Ollama Cloud"), capitalized id otherwise.
    func friendlyProviderLabel(_ keychainID: String) -> String {
        if let v = ProviderRegistry.vendor(forKeychainID: keychainID) { return v.displayName }
        return keychainID.capitalized
    }
    #endif

    /// The Keychain id for the currently-selected provider draft (+ the chosen vendor
    /// for "openmodels"). Drives the Settings key-status row, key field, and Test/Clear.
    var selectedAIKeychainID: String? {
        let p = aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !p.isEmpty else { return nil }
        switch p {
        case "openai", "anthropic": return p
        case "openmodels":
            #if canImport(CloudKit)
            guard let v = resolvedOpenVendor(aiOpenModelsVendorDraft) else { return nil }
            return ProviderRegistry.descriptor(for: v).keychainKeyID
            #else
            return nil
            #endif
        default: return p
        }
    }

    /// A friendly label for the selected provider (+ vendor for "openmodels"), used in
    /// the key-status copy and the API-key field instead of the raw "openmodels".
    var selectedAIDisplayLabel: String {
        let p = aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch p {
        case "openai": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "openmodels":
            #if canImport(CloudKit)
            if let v = resolvedOpenVendor(aiOpenModelsVendorDraft) {
                return v.displayName
            }
            #endif
            return "Open model"
        default: return aiDirectProviderDraft.capitalized
        }
    }

    /// Commit the displayed Ollama Cloud default when the provider switches to "openmodels"
    /// without the user having tapped the model dropdown — otherwise the drafts stay
    /// empty, the key save no-ops, and resolveConfiguration can't resolve the vendor.
    /// Legacy direct-vendor/OpenRouter drafts are migrated to Ollama Cloud (resetting the
    /// model to its default). Idempotent for the visible Ollama/NeuralWatt drafts.
    func seedOpenModelsDefaultsIfNeeded() {
        #if canImport(CloudKit)
        guard aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "openmodels" else { return }
        let current = OpenModelVendor(rawValue: aiOpenModelsVendorDraft.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if current.map({ !ProviderRegistry.allOpenModelVendors.contains($0) }) ?? true {
            aiOpenModelsVendorDraft = OpenModelVendor.ollamaCloud.rawValue
            aiOpenModelsModelDraft = ""
        }
        if aiOpenModelsModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let vendor = resolvedOpenVendor(aiOpenModelsVendorDraft) ?? .ollamaCloud
            aiOpenModelsModelDraft = ProviderRegistry.descriptor(for: vendor).defaultModel
        }
        #endif
    }

    // MARK: - Image-provider key (Gemini image key, separate from text key)

    /// True when a Gemini image key is saved in the Keychain.
    /// OpenAI image generation reuses the text key (`aiDirectAPIKeyConfigured` when
    /// provider == openai), so only Gemini needs its own presence check here.
    var geminiImageKeyConfigured: Bool {
        #if canImport(CloudKit)
        if let svc = aiService { return svc.hasGeminiImageKey }
        #endif
        return false
    }

    /// Save or clear the Gemini image key in the Keychain.
    func saveGeminiImageKey(_ key: String) {
        #if canImport(CloudKit)
        guard let svc = aiService else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        svc.saveKey(trimmed.isEmpty ? "" : trimmed, for: "gemini")
        #endif
    }

    func clearGeminiImageKey() {
        #if canImport(CloudKit)
        aiService?.clearKey(for: "gemini")
        #endif
    }

    // MARK: - Key presence (Keychain)

    /// Returns true if the user has a saved Keychain key for the given provider.
    func providerAPIKeyConfigured(providerID: String) -> Bool {
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProvider.isEmpty else { return false }
        #if canImport(CloudKit)
        if let svc = aiService {
            return svc.hasKey(for: normalizedProvider)
        }
        #endif
        // Fly fallback: secretFlags on the profile.
        let perProviderFlag = "ai_\(normalizedProvider)_api_key_present"
        if profile?.secretFlags[perProviderFlag] == true { return true }
        return profile?.settings["ai_direct_provider"]?.lowercased() == normalizedProvider &&
            (profile?.secretFlags["ai_direct_api_key_present"] ?? false)
    }

    // MARK: - Helpers

    private func selectedProviderAPIKeySetting(for providerID: String) -> String? {
        switch providerID.lowercased() {
        case "openai":    return "ai_openai_api_key"
        case "anthropic": return "ai_anthropic_api_key"
        default: return nil
        }
    }

    #if canImport(CloudKit)
    private func aiErrorMessage(_ error: AIError) -> String {
        switch error {
        case .noKeyConfigured(let model):
            return "No key configured for \(model.label)."
        case .httpError(let provider, let code, _):
            if code == 401 { return "\(provider.capitalized) key is invalid (401 Unauthorized)." }
            if code == 429 { return "\(provider.capitalized) rate limit hit — try again later." }
            return "\(provider.capitalized) returned HTTP \(code)."
        case .malformedResponse(let provider):
            return "\(provider.capitalized) returned an unexpected response."
        case .noProviderAvailable(let feature):
            return "No provider available for \(feature.rawValue)."
        case .notWiredYet(let tier):
            return "Provider tier not yet available: \(tier)."
        case .webSearchUnsupported(let model):
            return "Web search isn't available for \(model.label). Switch to a web-search-capable provider (OpenAI or Anthropic) in Settings → AI."
        case .imageGenFailed(let provider, _, let detail):
            return "\(provider.capitalized) image generation failed: \(detail)"
        }
    }
    #endif
}
