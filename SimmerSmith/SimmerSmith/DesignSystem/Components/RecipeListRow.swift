import SwiftUI
import SimmerSmithKit

/// One row in the Forge list view. Square thumbnail, italic-serif
/// title, Caveat metadata, AI sparkle + heart accents in ember.
/// Dashed rule between rows is drawn by the parent List/VStack.
struct RecipeListRow: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        HStack(spacing: SMSpacing.md) {
            RecipeHeaderImage(recipe: recipe)
                .frame(width: 44, height: 44)
                .overlay(
                    Rectangle().stroke(SMColor.rule, lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(SMFont.serifTitle(15))
                    .foregroundStyle(SMColor.ink)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !recipe.cuisine.isEmpty {
                        Text(recipe.cuisine.lowercased())
                            .font(SMFont.handwritten(13))
                            .foregroundStyle(SMColor.inkSoft)
                    }
                    if let prep = recipe.prepMinutes, prep > 0 {
                        if !recipe.cuisine.isEmpty {
                            Text("·")
                                .font(SMFont.handwritten(13))
                                .foregroundStyle(SMColor.inkSoft)
                        }
                        Text("\(prep) min")
                            .font(SMFont.handwritten(13))
                            .foregroundStyle(SMColor.inkSoft)
                    }
                }
            }

            Spacer()

            // M29 build 54: surface AI-generated recipes so cleanup
            // mode (and casual scanning) can spot them at a glance.
            // Sources include `ai`, `ai_variation`, `ai_suggestion`,
            // `ai_web_search`, `ai_companion`. In the Fusion palette
            // the assistant speaks in ember, so the sparkle takes the
            // ember treatment too.
            if recipe.source.hasPrefix("ai") {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(SMColor.ember)
                    .accessibilityLabel("AI-generated")
            }

            if recipe.favorite {
                Image(systemName: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(SMColor.ember)
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }
}
