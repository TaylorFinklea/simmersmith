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
                    Label("Recipes", systemImage: "book")
                }

                AssistantView()
                    .tag(AppState.MainTab.assistant)
                    .tabItem {
                        Label("Assistant", systemImage: "sparkles")
                    }
            }
            .tint(SMColor.primary)

            AIAssistantOverlay()
                .ignoresSafeArea(.keyboard)
        }
        .environment(coordinator)
    }
}
