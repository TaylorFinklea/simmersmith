import SwiftUI
import SimmerSmithKit

struct MealSlotRow: View {
    let slot: String
    let recipeName: String?
    let isApproved: Bool

    var body: some View {
        HStack(spacing: SMSpacing.md) {
            Text(slot.capitalized)
                .font(SMFont.label)
                .foregroundStyle(SMColor.textTertiary)
                .frame(width: 64, alignment: .leading)

            if let name = recipeName, !name.isEmpty {
                Text(name)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(1)
            } else {
                Text("Tap to add")
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textTertiary)
                    .italic()
            }

            Spacer()

            if isApproved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(SMColor.success)
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}
