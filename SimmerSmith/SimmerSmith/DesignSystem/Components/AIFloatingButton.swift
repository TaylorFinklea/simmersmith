import SwiftUI

/// "Ask the smith" floating action button. Solid ember disk with an
/// ember glow shadow. iOS sets `Image(systemName: "sparkles")` in
/// Charcoal so a darker overlay reads as ink.
struct AIFloatingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color(hex: 0x1A0E0A))
                .frame(width: 56, height: 56)
                .background(SMColor.ember)
                .clipShape(Circle())
                .shadow(color: SMColor.ember.opacity(0.55), radius: 14, x: 0, y: 0)
        }
        .accessibilityLabel("Ask the smith")
    }
}
