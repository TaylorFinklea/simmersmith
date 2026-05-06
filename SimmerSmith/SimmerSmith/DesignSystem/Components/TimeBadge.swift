import SwiftUI

/// Minutes badge — italic-serif numeral with a Caveat unit. No chip
/// background; sits inline as part of a metadata row.
struct TimeBadge: View {
    let minutes: Int

    var body: some View {
        HStack(spacing: 2) {
            Text("\(minutes)")
                .font(SMFont.serifDisplay(15))
                .foregroundStyle(SMColor.ink)
            Text("min")
                .font(SMFont.handwritten(13))
                .foregroundStyle(SMColor.inkSoft)
        }
    }
}
