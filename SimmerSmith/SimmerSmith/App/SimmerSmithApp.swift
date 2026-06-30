import Observation
import SwiftData
import SwiftUI
import SimmerSmithKit

@main
struct SimmerSmithApp: App {
    @UIApplicationDelegateAdaptor(SimmerSmithAppDelegate.self) private var appDelegate

    let modelContainer: ModelContainer

    @State private var appState: AppState

    init() {
        let container: ModelContainer
        do {
            container = try makeSimmerSmithModelContainer()
        } catch {
            do {
                container = try makeSimmerSmithModelContainer(inMemory: true)
            } catch {
                fatalError("Unable to create a SwiftData model container: \(error)")
            }
        }
        modelContainer = container
        _appState = State(initialValue: AppState(modelContainer: container))
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task {
                    appState.loadCachedData()
                    // Wire delegate so it can route tap-on-notification to the right tab.
                    appDelegate.appState = appState
                    // M22.1: hand AppState to the background sync service
                    // so its BGAppRefreshTask handler can pull Reminders
                    // deltas while the app is backgrounded.
                    BackgroundSyncService.shared.attach(appState: appState)
                    await appState.subscriptionStore.start()
                    // SP-C identity slice (spec §1.3): launch the iCloud-native session
                    // immediately, without requiring a Fly sign-in. This discovers (or
                    // mints) the CloudKit household and sets householdLaunchPhase → .ready,
                    // which unblocks RootView to show MainTabView.
                    #if canImport(CloudKit)
                    await appState.ensureHouseholdSession()
                    // Safety net for the cold-launch accept race: the scene delegate deposits the
                    // share metadata asynchronously, so ensureHouseholdSession's inbox drain can run
                    // first and miss it (booting as owner, which then blocks the foreground retry).
                    // Re-drain after setup — if a share landed late, this swaps owner→participant.
                    await appState.processPendingShare()
                    // Rolling safety-net snapshot (once/day) — captures the household while the
                    // data is intact so a future build can't strand it.
                    appState.maybeAutoSnapshot()
                    #endif
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            // M22.6: foreground sync — when the user comes back to the
            // app after editing the Reminders list (e.g. adding "Green
            // curry paste" because they're out), pull those edits into
            // SimmerSmith without waiting for a BGAppRefreshTask.
            // SP-C review finding E: both calls hit Fly (Grocery/Reminders aren't cut over
            // to CloudKit yet). Skip them in CloudKit-only mode so no Fly request fires
            // (no 401s) on foreground.
            if !appState.isCloudKitOnly && newPhase == .active && appState.reminderListIdentifier != nil {
                Task {
                    await appState.handleReminderStoreChange()
                    await appState.syncGroceryToReminders()
                }
            }
            // SP-C identity slice: if the household wasn't resolved yet (iCloud
            // unavailable or transient error), retry whenever the user foregrounds —
            // they may have signed into iCloud in Settings and come back.
            #if canImport(CloudKit)
            if newPhase == .active && appState.householdLaunchPhase != .ready {
                Task { await appState.ensureHouseholdSession() }
            }
            // Drain a pending accepted share on every foreground — even when already .ready —
            // so a share accepted while the app was backgrounded (or missed by the cold-launch
            // race) gets adopted. No-op when the inbox is empty.
            if newPhase == .active {
                Task { await appState.processPendingShare() }
            }
            #endif
        }
    }
}
