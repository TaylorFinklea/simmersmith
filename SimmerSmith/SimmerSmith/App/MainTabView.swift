import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let coordinator = appState.assistantCoordinator

        ZStack {
            TabView(selection: $appState.selectedTab) {
                // SP-C slice 3: Week + Grocery are now CloudKit-backed — render their
                // real views. Events and Smith (AI) remain coming-soon.
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

                comingSoon(feature: "Events", tab: .events)
                    .tag(AppState.MainTab.events)
                    .tabItem {
                        Label("Events", systemImage: "party.popper")
                    }

                comingSoon(feature: "Smith", tab: .assistant)
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

    /// Returns `ComingSoonView` for features not yet cut over to CloudKit.
    /// Slice 3 (Weeks + Grocery) cut over — Events and Smith remain here.
    @ViewBuilder
    private func comingSoon(feature: String, tab: AppState.MainTab) -> some View {
        ComingSoonView(feature: feature)
    }
}
