import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let coordinator = appState.assistantCoordinator

        ZStack {
            TabView(selection: $appState.selectedTab) {
                // SP-C slices 3 + 4: Week, Grocery, and Events are now CloudKit-backed.
                // Smith (AI) remains coming-soon.
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

                // SP-C slice 4: Events tab un-gated — CloudKit-backed.
                NavigationStack {
                    EventsView()
                }
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
    /// Slices 3 + 4 (Weeks + Grocery + Events) cut over — Smith remains here.
    @ViewBuilder
    private func comingSoon(feature: String, tab: AppState.MainTab) -> some View {
        ComingSoonView(feature: feature)
    }
}
