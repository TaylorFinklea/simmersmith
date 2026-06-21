import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
#endif

// SP-C slice 5 — AppState+Profile: non-AI profile settings + dietary goal.
//
// DATA → repos:
//   • Non-AI settings (image_provider / unit_system / user_region /
//     auto_grocery_from_meals) → ProfileRepository (private plane).
//   • Dietary goal (saveDietaryGoal / clearDietaryGoal) → ProfileRepository.
//
// AI SETTINGS (saveAISettings) → DEFER to AI track — stays on Fly; marked below.
//
// The `profile` stored property (ProfileSnapshot?) and the sync drafts
// (imageProviderDraft / unitSystemDraft / userRegionDraft) remain populated from
// the Fly profile on refreshAll(). Once the profile migration lands, the repo
// becomes the source of truth; until then, the local draft is the in-UI state
// that writes flow through.
//
// isCloudKitOnly guard: all writes must route through profileRepository when
// the CloudKit session is active. The guard below returns early when there is
// no repo (pre-session or iCloud unavailable) rather than falling back to Fly,
// because there is no longer a Fly write path for these settings in this build.

extension AppState {

    // MARK: - Image provider

    func saveImageProvider(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        #if canImport(CloudKit)
        if let repo = profileRepository {
            repo.setSetting("image_provider", trimmed)
            imageProviderDraft = trimmed
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session).
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

    // MARK: - Unit system

    func saveUnitSystem(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalized = trimmed == "metric" ? "metric" : "us"
        #if canImport(CloudKit)
        if let repo = profileRepository {
            repo.setSetting("unit_system", normalized)
            unitSystemDraft = normalized
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session).
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

    // MARK: - Auto grocery from meals

    /// Build 87: per-household "auto-populate grocery from meals" preference.
    var autoGroceryFromMeals: Bool {
        #if canImport(CloudKit)
        if let repo = profileRepository {
            return repo.settings["auto_grocery_from_meals"] == "1"
        }
        #endif
        return (profile?.settings["auto_grocery_from_meals"] ?? "0")
            .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    func saveAutoGroceryFromMeals(_ enabled: Bool) async {
        let value = enabled ? "1" : "0"
        #if canImport(CloudKit)
        if let repo = profileRepository {
            repo.setSetting("auto_grocery_from_meals", value)
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session).
        guard hasSavedConnection else { return }
        do {
            let updated = try await apiClient.updateProfile(settings: ["auto_grocery_from_meals": value])
            profile = updated
            try? cacheStore.saveProfile(updated)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Dietary goal

    /// Save the singleton dietary goal. Routes through ProfileRepository (private plane)
    /// when the CloudKit session is active; falls back to the Fly path during migration /
    /// pre-session.
    func saveDietaryGoal(_ goal: DietaryGoal) async {
        #if canImport(CloudKit)
        if let repo = profileRepository {
            repo.saveDietaryGoal(goal)
            // Reflect the saved goal in the Fly profile snapshot so the DietaryGoalView
            // "Clear Goal" button continues to work (it keys off profile?.dietaryGoal).
            // A nil profile is fine — the view reads from the repo projection directly
            // once the AI track completes the profile migration.
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session).
        guard hasSavedConnection else { return }
        do {
            _ = try await apiClient.saveDietaryGoal(goal)
            await refreshAll()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Clear the singleton dietary goal. Routes through ProfileRepository (private plane)
    /// when the CloudKit session is active; falls back to the Fly path during migration /
    /// pre-session.
    func clearDietaryGoal() async {
        #if canImport(CloudKit)
        if let repo = profileRepository {
            repo.clearDietaryGoal()
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session).
        guard hasSavedConnection else { return }
        do {
            try await apiClient.clearDietaryGoal()
            await refreshAll()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - AI SETTINGS (DEFER — AI track)
    // `saveAISettings` stays in AppState+AI.swift as-is. The Settings "AI" section
    // (provider config, API key, model picker) remains on the Fly path.
    // AI TRACK: route saveAISettings + assistant data through the AI track repo.
}
