import Foundation
import UIKit
import UserNotifications
import SimmerSmithKit

/// Manages APNs registration and incoming push notification dispatch.
///
/// Call `requestAuthorizationAndRegister()` once after sign-in
/// (handled automatically by `AppState.ensurePushBootstrap()`).
/// `SimmerSmithAppDelegate` forwards the system callbacks here.
@MainActor
final class PushService {
    static let shared = PushService()

    private let lastTokenKey = "simmersmith.push.lastToken"

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
    ///     (idempotent; recovers a lost device token after restore).
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
    /// Hex-encodes the token, skips re-registration if identical to last saved token,
    /// and stores the result in `UserDefaults` for next launch de-dup.
    func handleDeviceToken(_ data: Data, environment: String, bundleID: String, apiClient: SimmerSmithAPIClient) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        let previousToken = UserDefaults.standard.string(forKey: lastTokenKey)
        guard token != previousToken else { return }

        UserDefaults.standard.set(token, forKey: lastTokenKey)
        Task {
            do {
                try await apiClient.registerPushDevice(token: token, environment: environment, bundleID: bundleID)
            } catch {
                print("[PushService] registerPushDevice failed: \(error)")
            }
        }
    }

    // MARK: - Incoming notification dispatch

    /// Handle a remote notification payload — reads `deep_link` and routes accordingly.
    func handleRemoteNotification(userInfo: [AnyHashable: Any], appState: AppState) {
        guard let deepLink = userInfo["deep_link"] as? String else { return }
        if deepLink.hasPrefix("simmersmith://week") {
            appState.selectedTab = .week
        } else if deepLink.hasPrefix("simmersmith://assistant") {
            appState.selectedTab = .assistant
        }
    }
}
