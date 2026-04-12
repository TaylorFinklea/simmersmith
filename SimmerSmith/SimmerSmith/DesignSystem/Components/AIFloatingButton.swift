import SwiftUI

struct AIFloatingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(
                    LinearGradient(
                        colors: [SMColor.primary, SMColor.primaryMuted],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .shadow(color: SMColor.primary.opacity(0.4), radius: 12, y: 4)
        }
        .accessibilityLabel("Ask AI")
    }
}
