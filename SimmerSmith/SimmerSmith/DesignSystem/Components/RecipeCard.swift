import SwiftUI
import SimmerSmithKit

struct RecipeCard: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            // Gradient header area
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .fill(SMColor.recipeGradients[gradientIndex % SMColor.recipeGradients.count])
                .frame(height: 80)
                .overlay(alignment: .bottomLeading) {
                    if recipe.favorite {
                        Image(systemName: "heart.fill")
                            .font(.caption)
                            .foregroundStyle(SMColor.favoritePink)
                            .padding(SMSpacing.sm)
                    }
                }

            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(recipe.name)
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(2)

                HStack(spacing: SMSpacing.sm) {
                    if !recipe.cuisine.isEmpty {
                        Text(recipe.cuisine)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    if let prep = recipe.prepMinutes, prep > 0 {
                        Label("\(prep)m", systemImage: "clock")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                    }
                }
            }
            .padding(.horizontal, SMSpacing.sm)
            .padding(.bottom, SMSpacing.sm)
        }
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 0.5)
        )
    }
}
