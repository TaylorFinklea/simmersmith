import SwiftUI
import SimmerSmithKit

struct CompactRecipeCard: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            RecipeHeaderImage(recipe: recipe)
                .frame(height: 56)
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if recipe.favorite {
                        Image(systemName: "heart.fill")
                            .font(.caption2)
                            .foregroundStyle(SMColor.favoritePink)
                            .padding(SMSpacing.xs)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(2)

                if !recipe.cuisine.isEmpty {
                    Text(recipe.cuisine)
                        .font(.system(size: 11))
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
            .padding(.horizontal, SMSpacing.sm)
            .padding(.bottom, SMSpacing.sm)
        }
        .frame(width: 140)
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 0.5)
        )
    }
}
