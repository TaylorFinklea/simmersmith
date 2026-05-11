import SwiftUI
import SimmerSmithKit

/// Build 86 — popup-sheet host for the AI assistant.
///
/// Mounted once at the root (MainTabView). Owns nothing visible itself;
/// just observes `AIAssistantCoordinator.isSheetPresented` and presents
/// `AIAssistantSheetView` as a sheet when contextual sparkle buttons
/// (per-day in Week, per-page in Forge/Grocery/Recipe Detail) call
/// `coordinator.present()`.
///
/// The old floating sparkle FAB this view used to render is gone — the
/// dedicated Smith tab replaces it, and per-page TopBarSparkleButton +
/// inline day sparkles cover contextual access.
struct AIAssistantOverlay: View {
    @Environment(AIAssistantCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator

        Color.clear
            .allowsHitTesting(false)
            .sheet(isPresented: $coord.isSheetPresented) {
                AIAssistantSheetView()
                    .environment(coordinator)
            }
    }
}
