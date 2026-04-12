import SwiftUI
import SimmerSmithKit

struct DayCard: View {
    let dayName: String
    let meals: [WeekMeal]

    private let slotOrder = ["breakfast", "lunch", "dinner"]

    var body: some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text(dayName)
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.primary)

                Divider()
                    .background(SMColor.divider)

                ForEach(slotOrder, id: \.self) { slot in
                    let meal = meals.first { $0.slot.lowercased() == slot }
                    MealSlotRow(
                        slot: slot,
                        recipeName: meal?.recipeName,
                        isApproved: meal?.approved ?? false
                    )
                }
            }
        }
    }
}
