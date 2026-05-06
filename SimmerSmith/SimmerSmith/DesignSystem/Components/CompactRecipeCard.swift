import SwiftUI
import SimmerSmithKit

/// Smaller fixed-width recipe tile used in horizontal carousels
/// (Today / Recents / Favourites in WeekView). Same paperAlt
/// + rule treatment as RecipeCard, smaller image and Caveat
/// sub-line, no rotation (it sits in a scrolling row).
struct CompactRecipeCard: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            ZStack(alignment: .topLeading) {
                RecipeHeaderImage(recipe: recipe)
                    .frame(height: 56)
                    .overlay(
                        Rectangle().stroke(SMColor.rule, lineWidth: 1)
                    )
                FuRecipeNumber(index: gradientIndex + 1)
                    .padding(4)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(SMFont.serifTitle(13))
                    .foregroundStyle(SMColor.ink)
                    .lineLimit(2)

                if !recipe.cuisine.isEmpty {
                    Text(recipe.cuisine.lowercased())
                        .font(SMFont.handwritten(12))
                        .foregroundStyle(SMColor.inkSoft)
                }
            }
            .padding(.horizontal, SMSpacing.sm)
            .padding(.bottom, SMSpacing.sm)
        }
        .frame(width: 140)
        .padding(SMSpacing.xs)
        .background(SMColor.paperAlt)
        .overlay(
            Rectangle().stroke(SMColor.rule, lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if recipe.favorite {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(SMColor.ember)
                    .padding(4)
            }
        }
    }
}
