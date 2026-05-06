import SwiftUI
import SimmerSmithKit

/// Marquee recipe card used at the top of detail-style screens.
/// Italic Instrument Serif title with hand-drawn ember underline,
/// paper plate with the recipe image, Caveat metadata row.
struct HeroRecipeCard: View {
    let recipe: RecipeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            RecipeHeaderImage(recipe: recipe)
                .frame(height: 120)
                .overlay(
                    Rectangle().stroke(SMColor.rule, lineWidth: 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    if recipe.favorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(SMColor.ember)
                            .padding(SMSpacing.md)
                    }
                }

            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(recipe.name)
                    .font(SMFont.serifDisplay(28))
                    .foregroundStyle(SMColor.ink)
                    .lineLimit(2)

                HandUnderline(color: SMColor.ember, width: 80)
                    .padding(.top, 2)
                    .padding(.bottom, SMSpacing.sm)

                HStack(spacing: SMSpacing.md) {
                    if !recipe.cuisine.isEmpty {
                        CuisinePill(text: recipe.cuisine, color: SMColor.bronze, rotation: 0)
                    }
                    if let prep = recipe.prepMinutes, prep > 0 {
                        TimeBadge(minutes: prep)
                    }
                    if let cook = recipe.cookMinutes, cook > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "flame")
                                .font(.system(size: 11))
                                .foregroundStyle(SMColor.ember)
                            Text("\(cook)m cook")
                                .font(SMFont.handwritten(13))
                                .foregroundStyle(SMColor.ember)
                        }
                    }
                    HStack(spacing: 2) {
                        Image(systemName: "leaf")
                            .font(.system(size: 11))
                            .foregroundStyle(SMColor.inkFaint)
                        Text("\(recipe.ingredients.count)")
                            .font(SMFont.handwritten(13))
                            .foregroundStyle(SMColor.inkFaint)
                    }
                }
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.bottom, SMSpacing.lg)
        }
        .background(SMColor.paperAlt)
        .overlay(
            Rectangle().stroke(SMColor.rule, lineWidth: 0.5)
        )
    }
}
