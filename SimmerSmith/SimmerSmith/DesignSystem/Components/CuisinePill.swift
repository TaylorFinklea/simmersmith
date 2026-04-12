import SwiftUI

struct CuisinePill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SMFont.label)
            .foregroundStyle(SMColor.primary)
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, SMSpacing.xs)
            .background(SMColor.primary.opacity(0.15))
            .clipShape(Capsule())
    }
}
