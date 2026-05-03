import BackgroundTasks
import Foundation

/// M22.1 background sync. Registers a `BGAppRefreshTaskRequest` so iOS
/// will periodically wake the app and let us pull Reminders deltas
/// back to the server while the user is shopping with the app
/// backgrounded. iOS schedules the actual run at its discretion (no
/// guarantees on cadence), so the foreground EKEventStoreChanged
/// observer stays the primary path; this just narrows the gap when
/// the wife is mid-grocery-run with her phone in her pocket.
///
/// Task identifier: `app.simmersmith.ios.grocerySync`. Listed in
/// Info.plist under `BGTaskSchedulerPermittedIdentifiers`.
@MainActor
final class BackgroundSyncService {
    static let shared = BackgroundSyncService()

    static let taskIdentifier = "app.simmersmith.ios.grocerySync"

    private weak var appState: AppState?
    private var registered = false

    private init() {}

    /// Register the launch handler. Must be called before
    /// `application(_:didFinishLaunchingWithOptions:)` returns — Apple
    /// requires task registration on the main thread early in launch.
    func registerLaunchHandler() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handleAppRefresh(task: task)
        }
    }

    /// Wire AppState so the launch handler can invoke
    /// `handleReminderStoreChange()`. Called from
    /// `RootView.task { ... }` once AppState is alive.
    func attach(appState: AppState) {
        self.appState = appState
        scheduleNext()
    }

    /// Ask iOS to consider waking us in ~30 minutes. iOS may delay
    /// arbitrarily based on device usage / battery / Background App
    /// Refresh setting; we only request, we don't insist.
    func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common cases: simulator (no background tasks),
            // BackgroundAppRefresh disabled by user. Logging only.
            print("[BackgroundSyncService] submit failed: \(error)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        // Always re-schedule so we keep getting woken up.
        scheduleNext()

        guard let appState else {
            task.setTaskCompleted(success: false)
            return
        }
        guard appState.reminderListIdentifier != nil else {
            // User hasn't opted into Reminders sync — nothing to do.
            task.setTaskCompleted(success: true)
            return
        }

        let work = Task { @MainActor in
            await appState.handleReminderStoreChange()
            task.setTaskCompleted(success: true)
        }

        // iOS gives BGAppRefresh a budget of ~30s. If we're nearing
        // expiration the system will call this to let us bail
        // gracefully without crashing.
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
