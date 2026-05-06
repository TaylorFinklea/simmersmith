import SwiftUI

/// Outlined Fusion pill for a cuisine label. Caveat handwritten
/// label, transparent fill, 1.2pt ember border, slight rotation —
/// chips read like little hand-drawn margin tags.
struct CuisinePill: View {
    let text: String
    var color: Color = SMColor.ember
    var rotation: Double = -0.6

    var body: some View {
        Text(text.lowercased())
            .font(SMFont.handwritten(14))
            .foregroundStyle(color)
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, 4)
            .overlay(
                Capsule().stroke(color, lineWidth: 1.2)
            )
            .rotationEffect(.degrees(rotation))
    }
}
