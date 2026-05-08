import SwiftUI

/// Build 73 — shared "Smith's Notebook" treatment for navigation
/// toolbars: paperAlt-tinted bar + a thin ember-tinted hand-drawn
/// rule below it. Originally piloted on Forge in build 72; promoted
/// to a reusable modifier so every tab reads consistently.
private struct SmithToolbarBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .toolbarBackground(SMColor.paperAlt, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HandRule(color: SMColor.ember.opacity(0.35), height: 6, lineWidth: 0.8)
                    .padding(.horizontal, SMSpacing.lg)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                    .background(SMColor.paperAlt)
            }
    }
}

extension View {
    /// Apply the Forge-style paper-toned navigation toolbar with a
    /// hand-drawn ember rule below. Use on the root of each
    /// `NavigationStack`'s content.
    func smithToolbar() -> some View {
        modifier(SmithToolbarBackground())
    }
}
