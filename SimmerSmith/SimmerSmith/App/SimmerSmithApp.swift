import GoogleSignIn
import Observation
import SwiftData
import SwiftUI
import SimmerSmithKit

@main
struct SimmerSmithApp: App {
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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .task {
                    appState.loadCachedData()
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
    }
}
