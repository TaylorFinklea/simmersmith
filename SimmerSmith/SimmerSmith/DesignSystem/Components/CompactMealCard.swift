import SwiftUI
import SimmerSmithKit

struct CompactMealCard: View {
    let meal: WeekMeal
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: SMSpacing.md) {
                Text(meal.slot.capitalized)
                    .font(SMFont.label)
                    .foregroundStyle(SMColor.textTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 80, alignment: .leading)

                Text(meal.recipeName)
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(1)

                Spacer()

                if meal.approved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(SMColor.success)
                }
            }
            .padding(.horizontal, SMSpacing.md)
            .padding(.vertical, SMSpacing.sm)
            .background(SMColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
