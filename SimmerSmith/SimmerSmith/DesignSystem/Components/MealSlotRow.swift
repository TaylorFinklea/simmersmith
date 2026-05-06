import SwiftUI
import SimmerSmithKit

/// A row inside DayCard for one slot (breakfast / lunch / dinner).
/// Caveat slot label, italic-serif recipe name, italic placeholder
/// when empty.
struct MealSlotRow: View {
    let slot: String
    let recipeName: String?
    let isApproved: Bool

    var body: some View {
        HStack(spacing: SMSpacing.md) {
            Text(slot.lowercased())
                .font(SMFont.handwritten(14))
                .foregroundStyle(SMColor.inkSoft)
                .frame(width: 64, alignment: .leading)

            if let name = recipeName, !name.isEmpty {
                Text(name)
                    .font(SMFont.serifTitle(15))
                    .foregroundStyle(SMColor.ink)
                    .lineLimit(1)
            } else {
                Text("Tap to add")
                    .font(SMFont.bodySerifItalic(14))
                    .foregroundStyle(SMColor.inkFaint)
            }

            Spacer()

            if isApproved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(SMColor.ember)
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}
