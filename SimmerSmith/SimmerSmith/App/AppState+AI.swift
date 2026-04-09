import Foundation
import SimmerSmithKit

extension AppState {
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

    func saveAISettings(clearStoredAPIKey: Bool = false) async {
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

    func syncAIDrafts(from profile: ProfileSnapshot) {
        let savedMode = profile.settings["ai_provider_mode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiProviderModeDraft = savedMode.isEmpty ? "auto" : savedMode
        aiDirectProviderDraft = profile.settings["ai_direct_provider"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiOpenAIModelDraft = profile.settings["ai_openai_model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiAnthropicModelDraft = profile.settings["ai_anthropic_model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiDirectAPIKeyDraft = ""
    }

    func providerAPIKeyConfigured(providerID: String) -> Bool {
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedProvider.isEmpty else { return false }
        let perProviderFlag = "ai_\(normalizedProvider)_api_key_present"
        if profile?.secretFlags[perProviderFlag] == true {
            return true
        }
        return profile?.settings["ai_direct_provider"]?.lowercased() == normalizedProvider &&
            (profile?.secretFlags["ai_direct_api_key_present"] ?? false)
    }

    private func selectedProviderAPIKeySetting(for providerID: String) -> String? {
        switch providerID.lowercased() {
        case "openai":
            return "ai_openai_api_key"
        case "anthropic":
            return "ai_anthropic_api_key"
        default:
            return nil
        }
    }
}
