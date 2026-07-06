import BackgroundTasks
import Foundation
import os

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

        // Build 80 — race the sync against a hard 25s timeout. iOS gives
        // BGAppRefresh ~30s before SIGKILL; we self-cancel at 25 so the
        // grocery loop in handleReminderStoreChange exits cleanly via
        // its Task.isCancelled checks instead of getting killed mid-
        // network-call.
        //
        // Build 110 (simmersmith-pwf): two bugs in the old tree — (1) the
        // expiration handler called only `work.cancel()`, which never
        // reached the unstructured `syncTask` sibling (unstructured tasks
        // don't propagate cancellation); (2) both the work body and the
        // expiration handler could call `setTaskCompleted`, the documented
        // double-complete that trips a crash signal in Task Fleet
        // diagnostics. Fix: a single-fire `CompletionFlag` so the BGTask
        // completes exactly once, the natural path awaits `syncTask`
        // before completing, and the expiration handler cancels the
        // sibling tasks BY HANDLE so cancellation actually reaches the
        // sync work (Task.isCancelled checks in handleReminderStoreChange).
        // (A structured TaskGroup was tried first, but the region-based
        // isolation checker can't model the non-Sendable AppState capture
        // across the group body — direct handle cancellation reaches the
        // same exactly-once + cancellation-reach guarantees.)
        let completion = CompletionFlag()

        let syncTask = Task { @MainActor in
            await appState.handleReminderStoreChange()
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(25))
            syncTask.cancel()
        }

        // Natural completion: await the sync (and tear down the timeout)
        // before completing, then fire the guard exactly once.
        Task { @MainActor in
            await syncTask.value
            timeoutTask.cancel()
            if completion.fire() {
                task.setTaskCompleted(success: true)
            }
        }

        // Backstop: if iOS expires us, cancel the sibling tasks by handle
        // and complete failure — but only if natural completion hasn't
        // already fired the guard.
        task.expirationHandler = {
            syncTask.cancel()
            timeoutTask.cancel()
            if completion.fire() {
                task.setTaskCompleted(success: false)
            }
        }
    }
}

/// Exactly-once flag for BGTask completion. The natural-completion and
/// expiration handlers race; only the first caller of `fire()` wins, the
/// rest no-op. `OSAllocatedUnfairLock` because the expiration handler can
/// run off the main actor.
private final class CompletionFlag: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)

    /// Returns true for the first caller (who should complete the task);
    /// false for every subsequent caller.
    @discardableResult
    func fire() -> Bool {
        done.withLock { fired in
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}
