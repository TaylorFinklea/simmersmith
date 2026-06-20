import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let coordinator = appState.assistantCoordinator

        ZStack {
            TabView(selection: $appState.selectedTab) {
                // SP-C: Week, Grocery, Events, and Smith (AI) are not yet migrated
                // to CloudKit. Gate them behind ComingSoonView so no Fly call is made
                // and no 401 error banners appear. Recipes (Forge) is the first fully
                // cut-over feature and renders normally.
                NavigationStack {
                    comingSoon(feature: "Week", tab: .week)
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
                    comingSoon(feature: "Grocery", tab: .grocery)
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

    /// Returns `ComingSoonView` for features not yet cut over to CloudKit, or the
    /// original view once a feature slice completes. Currently all non-Recipes tabs
    /// are gated. Recipes renders normally (no gating needed).
    @ViewBuilder
    private func comingSoon(feature: String, tab: AppState.MainTab) -> some View {
        if appState.isCloudKitOnly {
            ComingSoonView(feature: feature)
        } else {
            // Unreachable while isCloudKitOnly == true; preserved for the future
            // per-feature cutover: delete the feature's ComingSoon arm when its
            // slice is complete and remove it from this switch.
            switch tab {
            case .week:
                WeekView()
            case .grocery:
                GroceryTabView()
            case .events:
                EventsView()
            case .assistant:
                AssistantView()
            default:
                EmptyView()
            }
        }
    }
}
