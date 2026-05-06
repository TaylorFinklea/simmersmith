import SwiftUI

/// Generic Fusion card. Linen-paper (paperAlt) fill, 0.5pt rule
/// border, small radius, subtle drop-shadow in light mode. Used as
/// the default container wrapper across feature views.
struct SMCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(SMSpacing.lg)
            .background(SMColor.paperAlt)
            .overlay(
                RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                    .stroke(SMColor.rule, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
            .shadow(
                color: scheme == .dark ? .clear : .black.opacity(0.05),
                radius: 6, x: 0, y: 2
            )
    }
}
