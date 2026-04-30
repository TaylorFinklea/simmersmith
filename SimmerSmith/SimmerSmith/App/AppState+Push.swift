import Foundation
import UserNotifications
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

    /// Whether the AI-finished-thinking push fires after a planning turn
    /// that ran tools (e.g. `generate_week_plan`). Default: on. iOS
    /// suppresses banners while foregrounded automatically, so this is
    /// only visible when the user has the app backgrounded mid-turn.
    var pushAssistantDoneEnabled: Bool {
        get { (profile?.settings["push_assistant_done"] ?? "1") != "0" }
    }

    /// True iff iOS has the user's notifications-denied state on record. The
    /// Settings UI surfaces an "Open iOS Settings" affordance when this is
    /// true so the user can recover from a prior denial (toggling the in-app
    /// switches won't re-trigger the system prompt once iOS has decided).
    var pushAuthorizationDenied: Bool {
        get { pushAuthorizationStatus == .denied }
    }

    // MARK: - Persist

    /// Persist a push preference key/value via PUT /api/profile.
    /// On enable, also (re-)request iOS authorization. If iOS reports
    /// `.notDetermined` this fires the system prompt; if `.authorized`
    /// it re-registers the device token; if `.denied` it's a no-op and
    /// the UI shows the "Open iOS Settings" hint.
    func savePushPreference(_ key: String, enabled: Bool) async {
        guard hasSavedConnection else { return }
        let value = enabled ? "1" : "0"
        if enabled {
            await PushService.shared.requestAuthorizationAndRegister()
            await refreshPushAuthorizationStatus()
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

    /// Re-read the system authorization status into `pushAuthorizationStatus`.
    /// Call this on bootstrap and after the user toggles a push preference.
    func refreshPushAuthorizationStatus() async {
        pushAuthorizationStatus = await PushService.shared.currentAuthorizationStatus()
    }

    /// Called after `refreshAll()` hydrates the profile. Reads the real iOS
    /// authorization status (not a UserDefaults flag) and reacts:
    ///
    ///   - `.notDetermined` + at least one toggle enabled → show the
    ///     system prompt. This is the fresh-install / first-launch path.
    ///   - `.authorized` / `.provisional` / `.ephemeral` → re-register
    ///     the device so a token rotation or restore from backup
    ///     re-establishes delivery.
    ///   - `.denied` → no-op. The Settings UI surfaces an "Open iOS
    ///     Settings" affordance via `pushAuthorizationDenied`.
    ///
    /// Best-effort: a failure here must never crash bootstrap.
    func ensurePushBootstrap() async {
        await refreshPushAuthorizationStatus()
        let status = pushAuthorizationStatus
        let toggleEnabled = pushTonightsMealEnabled || pushSaturdayPlanEnabled
        switch status {
        case .notDetermined:
            if toggleEnabled {
                await PushService.shared.requestAuthorizationAndRegister()
                await refreshPushAuthorizationStatus()
            }
        case .authorized, .provisional, .ephemeral:
            await PushService.shared.requestAuthorizationAndRegister()
        case .denied:
            break
        @unknown default:
            break
        }
    }
}
