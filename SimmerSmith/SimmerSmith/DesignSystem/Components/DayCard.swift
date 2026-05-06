import SwiftUI
import SimmerSmithKit

/// A day on the week roster. Italic-serif day name + ember hand
/// rule, then the three slots as MealSlotRows. Sits on the page
/// (no SMCard wrapper) — the page is paper, the day is just a
/// section.
struct DayCard: View {
    let dayName: String
    let meals: [WeekMeal]

    private let slotOrder = ["breakfast", "lunch", "dinner"]

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack(spacing: SMSpacing.sm) {
                Text(dayName.lowercased())
                    .font(SMFont.serifDisplay(20))
                    .foregroundStyle(SMColor.ink)
                HandUnderline(color: SMColor.ember, width: 40)
            }

            ForEach(slotOrder, id: \.self) { slot in
                let meal = meals.first { $0.slot.lowercased() == slot }
                MealSlotRow(
                    slot: slot,
                    recipeName: meal?.recipeName,
                    isApproved: meal?.approved ?? false
                )
                if slot != slotOrder.last {
                    HandRule(color: SMColor.rule, height: 4, lineWidth: 0.8)
                }
            }
        }
        .padding(.vertical, SMSpacing.md)
    }
}
