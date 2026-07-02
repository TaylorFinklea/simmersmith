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

    // MARK: - M18 → simmersmith-990.6: local replacements for the Fly push scheduler
    //
    // "Tonight's meal" and "Saturday plan reminder" used to be server-side APNs
    // pushes (app/services/push_scheduler.py, decisions.md 2026-04-30), fired by an
    // in-process APScheduler tick. That path is dead for CloudKit-era users (it sat
    // behind AppState.hasSavedConnection, which is false for everyone post-pivot).
    // These are scheduled on-device instead, from `LocalPushSchedule`'s decision —
    // AppState+Push.swift resolves the week + clock inputs, calls `decide(_:)`, and
    // applies the `Reminder?` result here. Fixed (non-UUID) identifiers so a later
    // reschedule pass naturally REPLACES the prior pending request for the same kind
    // (`UNUserNotificationCenter.add` replaces a pending request sharing its
    // identifier) instead of accumulating duplicates.

    static let tonightsMealIdentifier = "push-tonights-meal"
    static let saturdayPlanIdentifier = "push-saturday-plan"

    /// Schedule (or replace) the "tonight's meal" reminder at `deadline`.
    /// `title`/`body` are expected to come straight from `LocalPushSchedule`'s
    /// `Reminder` (single source of truth for the copy — see its tests) rather
    /// than being re-hardcoded here. No-ops if `deadline` isn't in the future —
    /// callers are expected to have already checked this (`LocalPushSchedule`
    /// only returns future fire dates), but this guards against ever silently
    /// firing a stale reminder immediately.
    static func scheduleTonightsMeal(deadline: Date, title: String, body: String) {
        schedule(id: tonightsMealIdentifier, deadline: deadline, title: title, body: body)
    }

    /// Schedule (or replace) the "Saturday plan reminder" at `deadline`. See
    /// `scheduleTonightsMeal` re: `title`/`body` provenance.
    static func scheduleSaturdayPlan(deadline: Date, title: String, body: String) {
        schedule(id: saturdayPlanIdentifier, deadline: deadline, title: title, body: body)
    }

    /// Cancel a previously-scheduled "tonight's meal" reminder (toggle off, no
    /// dinner meal, quiet hours, etc. — whenever `LocalPushSchedule` returns nil).
    static func cancelTonightsMeal() {
        cancel(tonightsMealIdentifier)
    }

    /// Cancel a previously-scheduled "Saturday plan reminder".
    static func cancelSaturdayPlan() {
        cancel(saturdayPlanIdentifier)
    }

    private static func schedule(id: String, deadline: Date, title: String, body: String) {
        let interval = deadline.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[LocalNotificationService] schedule(\(id)) failed: \(error)")
            }
        }
    }
}
