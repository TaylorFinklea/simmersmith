import SwiftUI

struct MainTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let coordinator = appState.assistantCoordinator

        ZStack {
            TabView(selection: $appState.selectedTab) {
                // SP-C slices 3 + 4: Week, Grocery, and Events are now CloudKit-backed.
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

                SmithLandingView()
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

/// Bead simmersmith-7pr: Smith tab landing content. The real assistant is a
/// `.sheet` mounted globally by `AIAssistantOverlay`, so this view's only job
/// is to trigger `coordinator.present()`: on `.onAppear` — which fires each
/// time the user switches TO the Smith tab, so selecting Smith always opens
/// the assistant — and via an explicit "Open Assistant" button for re-entry
/// after the user taps Done while staying on the tab (a `.sheet` dismissal
/// does not re-fire the presenter's `.onAppear`).
private struct SmithLandingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(SMColor.ember)
                .padding(.bottom, SMSpacing.sm)

            Text("Smith")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)

            Text("Your kitchen assistant is ready when you are.")
                .font(SMFont.subheadline)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SMSpacing.xl)

            Button {
                appState.assistantCoordinator.present()
            } label: {
                Label("Open Assistant", systemImage: "sparkles")
                    .font(SMFont.body)
            }
            .buttonStyle(.borderedProminent)
            .tint(SMColor.ember)
            .padding(.top, SMSpacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SMColor.paper)
        .paperBackground()
        .onAppear {
            appState.assistantCoordinator.present()
        }
    }
}
