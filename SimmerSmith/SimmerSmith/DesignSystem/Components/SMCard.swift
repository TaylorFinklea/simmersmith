import SwiftUI

struct SMCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(SMSpacing.lg)
            .background(SMColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous)
                    .strokeBorder(SMColor.divider, lineWidth: 0.5)
            )
    }
}
