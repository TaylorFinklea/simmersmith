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
                    if appState.hasSavedConnection {
                        await appState.refreshAll()
                    }
                }
        }
        .modelContainer(modelContainer)
    }
}
