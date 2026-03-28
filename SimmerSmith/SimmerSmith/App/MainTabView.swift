import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        TabView(selection: $appState.selectedTab) {
            NavigationStack {
                WeekView()
            }
            .tag(AppState.MainTab.week)
            .tabItem {
                Label("Week", systemImage: "calendar")
            }

            NavigationStack {
                GroceryView()
            }
            .tag(AppState.MainTab.grocery)
            .tabItem {
                Label("Grocery", systemImage: "cart")
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

            NavigationStack {
                SettingsView()
            }
            .tag(AppState.MainTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
