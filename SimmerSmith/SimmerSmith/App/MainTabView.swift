import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let coordinator = appState.assistantCoordinator

        ZStack {
            TabView(selection: $appState.selectedTab) {
                NavigationStack {
                    WeekView()
                }
                .tag(AppState.MainTab.week)
                .tabItem {
                    Label("Week", systemImage: "calendar")
                }

                NavigationStack {
                    RecipesView()
                }
                .tag(AppState.MainTab.recipes)
                .tabItem {
                    Label("Forge", systemImage: "book")
                }

                NavigationStack {
                    GroceryTabView()
                }
                .tag(AppState.MainTab.grocery)
                .tabItem {
                    Label("Grocery", systemImage: "cart")
                }

                EventsView()
                    .tag(AppState.MainTab.events)
                    .tabItem {
                        Label("Events", systemImage: "party.popper")
                    }

                AssistantView()
                    .tag(AppState.MainTab.assistant)
                    .tabItem {
                        Label("Smith", systemImage: "sparkles")
                    }
            }
            .tint(SMColor.ember)

            // Build 86 — re-mount the assistant overlay so per-day
            // sparkle buttons in Week (and per-page sparkle buttons
            // elsewhere) re-open the popup sheet instead of silently
            // toggling coordinator state.
            AIAssistantOverlay()
                .ignoresSafeArea(.keyboard)
        }
        .environment(coordinator)
    }
}
