import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - Draft state (backed by profile_settings rows)

    /// Whether "Tonight's meal" push is enabled. Default: on.
    var pushTonightsMealEnabled: Bool {
        get { (profile?.settings["push_tonights_meal"] ?? "1") != "0" }
    }

    /// Whether "Saturday plan reminder" push is enabled. Default: on.
    var pushSaturdayPlanEnabled: Bool {
        get { (profile?.settings["push_saturday_plan"] ?? "1") != "0" }
    }

    /// User-local delivery time for tonight's-meal push. Default: "17:00".
    var pushTonightsMealTime: String {
        get { profile?.settings["push_tonights_meal_time"] ?? "17:00" }
    }

    /// User-local delivery time for Saturday plan push. Default: "18:00".
    var pushSaturdayPlanTime: String {
        get { profile?.settings["push_saturday_plan_time"] ?? "18:00" }
    }

    // MARK: - Persist

    /// Persist a push preference key/value via PUT /api/profile.
    /// When the user enables a toggle from a disabled state, calls
    /// `requestAuthorizationAndRegister()` so a prior denial can be
    /// re-attempted (iOS will surface its Settings redirect at that point).
    func savePushPreference(_ key: String, enabled: Bool) async {
        guard hasSavedConnection else { return }
        let value = enabled ? "1" : "0"
        if enabled {
            await PushService.shared.requestAuthorizationAndRegister()
        }
        do {
            let updated = try await apiClient.updateProfile(settings: [key: value])
            profile = updated
            try? cacheStore.saveProfile(updated)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Persist a push time string (HH:mm) via PUT /api/profile.
    func savePushTime(_ key: String, date: Date) async {
        guard hasSavedConnection else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeString = formatter.string(from: date)
        do {
            let updated = try await apiClient.updateProfile(settings: [key: timeString])
            profile = updated
            try? cacheStore.saveProfile(updated)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Bootstrap

    /// Called once after `bootstrap()` / `refreshAll()` finishes hydrating the profile.
    ///
    /// If either push toggle reads enabled (default for fresh accounts because
    /// `DEFAULT_PROFILE_SETTINGS` seeds both as "1") AND we have not yet prompted
    /// in this install (`UserDefaults("simmersmith.push.didPrompt") != true`),
    /// fires the APNs permission prompt once.
    ///
    /// If the user denies, the server-side toggles stay "1" but no device token
    /// is registered — re-prompting requires the user toggling off then back on
    /// in Settings, which calls `requestAuthorizationAndRegister()` directly.
    func ensurePushBootstrap() async {
        let didPromptKey = "simmersmith.push.didPrompt"
        guard !UserDefaults.standard.bool(forKey: didPromptKey) else { return }
        guard pushTonightsMealEnabled || pushSaturdayPlanEnabled else { return }

        UserDefaults.standard.set(true, forKey: didPromptKey)
        await PushService.shared.requestAuthorizationAndRegister()
    }
}
