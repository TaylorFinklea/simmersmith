import Foundation
import SimmerSmithKit

extension AppState {
    /// Persist the user's image-gen provider choice. Mirrors
    /// `saveUserRegion` — writes via the existing `PUT /api/profile`
    /// route, hydrates the local snapshot + cache, and re-syncs the
    /// draft so the Settings Picker reflects the saved value.
    func saveImageProvider(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hasSavedConnection else { return }
        do {
            let updated = try await apiClient.updateProfile(settings: ["image_provider": trimmed])
            profile = updated
            try? cacheStore.saveProfile(updated)
            imageProviderDraft = trimmed
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Hydrate `imageProviderDraft` from a freshly-loaded profile so
    /// the Settings Picker shows the saved value on first render.
    /// Defaults to `"openai"` when the row is missing or unrecognized.
    func syncImageProviderDraft(from profile: ProfileSnapshot) {
        let raw = (profile.settings["image_provider"] ?? "").lowercased()
        imageProviderDraft = (raw == "gemini") ? "gemini" : "openai"
    }

    /// M27 — persist the unit-system localization toggle. The same
    /// value name (`unit_system`) the backend's
    /// `app/services/ai.unit_system_directive` reads. Defaults to
    /// `"us"` everywhere; legacy users without the row inherit US
    /// customary and can flip to metric in Settings → AI.
    func saveUnitSystem(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = trimmed == "metric" ? "metric" : "us"
        guard hasSavedConnection else { return }
        do {
            let updated = try await apiClient.updateProfile(settings: ["unit_system": normalized])
            profile = updated
            try? cacheStore.saveProfile(updated)
            unitSystemDraft = normalized
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func syncUnitSystemDraft(from profile: ProfileSnapshot) {
        let raw = (profile.settings["unit_system"] ?? "").lowercased()
        unitSystemDraft = (raw == "metric") ? "metric" : "us"
    }
}
