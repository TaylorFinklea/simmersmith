import SwiftUI
import SimmerSmithKit

/// Floating sparkle button + sheet. Attach as an overlay on the root
/// container so every tab gets access.
struct AIAssistantOverlay: View {
    @Environment(AIAssistantCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coord = coordinator

        ZStack(alignment: .bottomTrailing) {
            Color.clear

            if !coordinator.hideFloatingButton {
                Button {
                    coordinator.toggle()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(
                            LinearGradient(
                                colors: [SMColor.primary, SMColor.aiPurple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Circle()
                        )
                        .shadow(color: SMColor.aiPurple.opacity(0.4), radius: 12, y: 4)
                }
                .accessibilityLabel("Open AI assistant")
                .padding(.trailing, SMSpacing.xl)
                .padding(.bottom, 96)
            }
        }
        .sheet(isPresented: $coord.isSheetPresented) {
            AIAssistantSheetView()
                .environment(coordinator)
        }
    }
}
