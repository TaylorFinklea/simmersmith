import Foundation
import UIKit
import UserNotifications
import SimmerSmithKit

/// Manages notification authorization + APNs device registration, and routes
/// incoming remote notifications.
///
/// simmersmith-990.6: the Fly APScheduler that used to send "tonight's meal" /
/// "Saturday plan" pushes to a registered device is retired — those are now
/// scheduled ON-DEVICE via `LocalNotificationService` (see `AppState+Push.swift`).
/// This service no longer registers the device token with Fly (`registerPushDevice`
/// / `unregisterPushDevice` are unused now). It still requests notification
/// authorization and calls `registerForRemoteNotifications()`: CRITICAL — CloudKit's
/// `CKSyncEngine` relies on the app being registered for remote (silent) push to
/// receive its own change notifications. Removing that registration would break
/// CloudKit sync delivery, not just our own content pushes. Do NOT remove the
/// `aps-environment` entitlement or `CKSharingSupported` — those are CloudKit's
/// transport, unrelated to the retired Fly push feature.
///
/// Call `requestAuthorizationAndRegister()` once after sign-in
/// (handled automatically by `AppState.ensurePushBootstrap()`).
/// `SimmerSmithAppDelegate` forwards the system callbacks here.
@MainActor
final class PushService {
    static let shared = PushService()

    private init() {}

    // MARK: - Registration

    /// Read the current iOS authorization status.
    /// `.notDetermined` means we have never prompted (or the prompt was
    /// dismissed without a choice); calling `requestAuthorization` will
    /// surface the system alert. Any other state means iOS already made
    /// a decision and `requestAuthorization` will silently no-op.
    func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Request UNUserNotificationCenter permission and register for remote notifications.
    ///
    /// Behavior by current authorization status:
    ///   - `.notDetermined` → show the system prompt; if granted, register.
    ///   - `.authorized` / `.provisional` / `.ephemeral` → re-register
    ///     (idempotent; recovers CloudKit's silent-push registration after restore).
    ///   - `.denied` → no-op. Caller is responsible for surfacing an
    ///     "open iOS Settings" affordance.
    func requestAuthorizationAndRegister() async {
        let center = UNUserNotificationCenter.current()
        let status = await currentAuthorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                print("[PushService] Authorization request failed: \(error)")
            }
        case .denied:
            // iOS has the user's denial on record; can't re-prompt.
            break
        @unknown default:
            break
        }
    }

    /// Called by `SimmerSmithAppDelegate` when iOS hands us a fresh device token.
    /// simmersmith-990.6: there is no longer a Fly `/api/push/devices` endpoint to
    /// register this token against (the "tonight's meal" / "Saturday plan" pushes
    /// this used to arm are now scheduled locally), and CloudKit's own silent-push
    /// delivery doesn't need the raw token relayed anywhere by this app — CKSyncEngine
    /// manages its own subscription server-side once `registerForRemoteNotifications()`
    /// has been called. This is now a no-op kept only so the app delegate's callback
    /// (outside this lane) has somewhere to forward to without a signature change.
    func handleDeviceToken(_ data: Data, environment: String, bundleID: String, apiClient: SimmerSmithAPIClient) {
        // Intentionally does nothing — see doc comment above.
    }

    /// Call on sign-out (from `AppState.resetConnection()`). Cancels any pending
    /// local "tonight's meal" / "Saturday plan" reminders scheduled for the
    /// signing-out user's household, so a different user signing in on this shared
    /// device doesn't briefly see a stale reminder before the next reschedule pass
    /// (triggered once the new user's week data loads) replaces it.
    func reset(apiClient: SimmerSmithAPIClient) {
        LocalNotificationService.cancelTonightsMeal()
        LocalNotificationService.cancelSaturdayPlan()
    }

    // MARK: - Incoming notification dispatch

    /// Handle a remote notification payload — reads `deep_link` and routes accordingly.
    /// simmersmith-990.6: no server sends `deep_link` remote pushes anymore (the Fly
    /// scheduler is retired), so this is effectively dormant, but kept as a harmless
    /// passthrough in case CloudKit's own silent pushes ever land here with unrelated
    /// keys — the `deep_link` guard below simply won't match and no-ops.
    func handleRemoteNotification(userInfo: [AnyHashable: Any], appState: AppState) {
        guard let deepLink = userInfo["deep_link"] as? String else { return }
        if deepLink.hasPrefix("simmersmith://week") {
            appState.selectedTab = .week
        } else if deepLink.hasPrefix("simmersmith://assistant") {
            appState.selectedTab = .assistant
        }
    }
}
