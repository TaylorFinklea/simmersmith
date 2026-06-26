import Foundation
import SimmerSmithKit

// SP-C — customizable AI-assistant suggestion chips.
//
// Per-screen prompt overrides live in the per-user private plane as ONE JSON value under
// `AssistantPrompts.settingKey` ("assistant_prompts"): { pageType: [template, …] }. An
// override falls back to the built-in defaults when empty. The pure model + token
// rendering live in `AssistantPrompts` (SimmerSmithKit); this file is the AppState bridge:
// hydrate at session boot, resolve for the sheet, and persist edits.

extension AppState {

    /// The chips to show for a screen — the user's override (if any) else the defaults,
    /// with `{day}`/`{recipe}` tokens substituted. Read by AIAssistantSheetView.
    func resolvedAssistantPrompts(pageType: String, day: String?, recipe: String?) -> [String] {
        AssistantPrompts.resolve(
            pageType: pageType,
            overrides: assistantPromptOverrides[pageType] ?? [],
            day: day,
            recipe: recipe
        )
    }

    /// Hydrate `assistantPromptOverrides` from the private plane. Called during
    /// household-session setup (alongside the other private-plane drafts).
    func loadAssistantPromptOverrides() {
        #if canImport(CloudKit)
        guard let store = householdSession?.privateStore else { return }
        let raw = (try? store.profileSetting(key: AssistantPrompts.settingKey))?.value ?? ""
        assistantPromptOverrides = AssistantPrompts.decode(raw)
        #endif
    }

    /// Persist the override for one screen. Removing the override (reset, empty, or text
    /// equal to the defaults) lets the screen fall back to the built-in defaults, so we
    /// don't store a redundant copy. Writes the whole map back as one private-plane value.
    func saveAssistantPrompts(pageType: String, prompts: [String], resetToDefaults: Bool = false) {
        #if canImport(CloudKit)
        let cleaned = prompts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let defaults = AssistantPrompts.context(for: pageType)?.defaults ?? []

        var map = assistantPromptOverrides
        if resetToDefaults || cleaned.isEmpty || cleaned == defaults {
            map[pageType] = nil
        } else {
            map[pageType] = cleaned
        }
        assistantPromptOverrides = map

        // Stored OUTSIDE ProfileRepository (which only owns the nonAIKeys allowlist) —
        // written directly to the private-plane store, the same path AIService settings use.
        guard let store = householdSession?.privateStore else {
            // No store yet (pre-boot / iCloud unavailable). The in-memory override applies
            // this session, but warn so the user knows it didn't persist across launches.
            lastErrorMessage = "Couldn't save assistant prompts yet — iCloud is still loading. Try again in a moment."
            return
        }
        do {
            try store.upsertProfileSetting(key: AssistantPrompts.settingKey, value: AssistantPrompts.encode(map))
            try store.save()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "Failed to save assistant prompts: \(error.localizedDescription)"
        }
        #endif
    }
}
