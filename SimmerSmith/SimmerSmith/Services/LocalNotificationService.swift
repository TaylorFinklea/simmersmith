import Foundation
import UserNotifications

/// Local (on-device, no APNs) notification scheduling. Used for cook-mode
/// timers so a backgrounded timer still fires a banner. iOS suppresses
/// banners when the app is foregrounded by default, so foreground users
/// continue to see the in-app haptic + TTS chime instead.
///
/// Scheduling silently no-ops when the user has denied notification
/// permission. The Settings UI surfaces an "Open iOS Settings" hint in
/// that case (see `AppState+Push.swift:pushAuthorizationDenied`).
@MainActor
enum LocalNotificationService {
    /// Schedule a local notification at `deadline` with body `label`.
    /// Returns the request identifier so the caller can cancel it later
    /// (when the timer is dismissed or fires foreground first).
    static func scheduleTimerDone(deadline: Date, label: String) -> String {
        let id = "cook-timer-\(UUID().uuidString)"
        let interval = max(1, deadline.timeIntervalSinceNow)

        let content = UNMutableNotificationContent()
        content.title = "Timer done"
        content.body = label
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[LocalNotificationService] schedule failed: \(error)")
            }
        }
        return id
    }

    /// Remove a previously-scheduled local notification by id. Safe to
    /// call with a stale or unknown id — iOS no-ops in that case.
    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}
