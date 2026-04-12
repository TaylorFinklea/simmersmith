import SwiftUI
import SimmerSmithKit

struct TodayMealCard: View {
    let meal: WeekMeal
    let recipe: RecipeSummary?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                HStack {
                    Text(meal.slot.capitalized)
                        .font(SMFont.label)
                        .foregroundStyle(SMColor.textTertiary)

                    Spacer()

                    if meal.approved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(SMColor.success)
                            .font(.caption)
                    }

                    if meal.aiGenerated {
                        Image(systemName: "sparkles")
                            .foregroundStyle(SMColor.aiPurple)
                            .font(.caption)
                    }
                }

                Text(meal.recipeName)
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: SMSpacing.md) {
                    if let cuisine = recipe?.cuisine, !cuisine.isEmpty {
                        CuisinePill(text: cuisine)
                    }
                    if let prep = recipe?.prepMinutes, prep > 0 {
                        TimeBadge(minutes: prep)
                    }
                    if let cook = recipe?.cookMinutes, cook > 0 {
                        TimeBadge(minutes: cook)
                    }
                    if let count = recipe?.ingredients.count, count > 0 {
                        Label("\(count) items", systemImage: "leaf")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                }

                if !meal.notes.isEmpty {
                    Text(meal.notes)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(SMSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SMColor.primary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous)
                    .strokeBorder(SMColor.primary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
