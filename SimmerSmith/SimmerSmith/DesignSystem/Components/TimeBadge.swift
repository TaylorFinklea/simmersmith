import SwiftUI

struct TimeBadge: View {
    let minutes: Int

    var body: some View {
        Label("\(minutes) min", systemImage: "clock")
            .font(SMFont.caption)
            .foregroundStyle(SMColor.textTertiary)
    }
}
