import SwiftUI
import SimmerSmithKit

struct RecipeListRow: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        HStack(spacing: SMSpacing.md) {
            RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous)
                .fill(SMColor.recipeGradients[gradientIndex % SMColor.recipeGradients.count])
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(SMFont.body)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(1)

                HStack(spacing: SMSpacing.sm) {
                    if !recipe.cuisine.isEmpty {
                        Text(recipe.cuisine)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                    if let prep = recipe.prepMinutes, prep > 0 {
                        Text("\(prep) min")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                }
            }

            Spacer()

            if recipe.favorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(SMColor.favoritePink)
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}
