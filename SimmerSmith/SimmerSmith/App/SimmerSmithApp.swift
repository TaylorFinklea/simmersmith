import GoogleSignIn
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
                    // Silently restore any previous Google Sign-In session so
                    // subsequent API calls made through GIDSignIn (profile
                    // info, token refresh) pick up without requiring the user
                    // to tap the button again. Our SimmerSmith session JWT is
                    // already persisted in ConnectionSettingsStore, so this is
                    // purely for the native Google UI state.
                    GIDSignIn.sharedInstance.restorePreviousSignIn { _, _ in }
                    await appState.subscriptionStore.start()
                    if appState.hasSavedConnection {
                        await appState.refreshAll()
                    }
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            // M22.6: foreground sync — when the user comes back to the
            // app after editing the Reminders list (e.g. adding "Green
            // curry paste" because they're out), pull those edits into
            // SimmerSmith without waiting for a BGAppRefreshTask.
            if newPhase == .active && appState.reminderListIdentifier != nil {
                Task {
                    await appState.handleReminderStoreChange()
                    await appState.syncGroceryToReminders()
                }
            }
        }
    }
}
