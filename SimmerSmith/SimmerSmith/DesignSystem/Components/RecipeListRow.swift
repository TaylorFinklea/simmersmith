import SwiftUI
import SimmerSmithKit

struct RecipeListRow: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        HStack(spacing: SMSpacing.md) {
            RecipeHeaderImage(recipe: recipe)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))

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

            // M29 build 54: surface AI-generated recipes so cleanup
            // mode (and casual scanning) can spot them at a glance.
            // Sources include `ai`, `ai_variation`, `ai_suggestion`,
            // `ai_web_search`, `ai_companion`.
            if recipe.source.hasPrefix("ai") {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(SMColor.aiPurple)
                    .accessibilityLabel("AI-generated")
            }

            if recipe.favorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(SMColor.favoritePink)
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}
