import SwiftUI
import SimmerSmithKit

/// Standard 2-up recipe tile in the Forge grid. PaperAlt fill,
/// 0.5pt rule border, slight rotation per index, italic-serif
/// title, Caveat sub-line, optional heart in the top-right.
struct RecipeCard: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    private var rotation: Double {
        // Same alternating tilts the JSX mockup uses on the Forge tiles.
        let tilts: [Double] = [-0.8, 0.6, -0.4, 0.7, -0.6, 0.5]
        return tilts[gradientIndex % tilts.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            ZStack(alignment: .topLeading) {
                RecipeHeaderImage(recipe: recipe)
                    .frame(height: 86)
                    .overlay(
                        Rectangle().stroke(SMColor.rule, lineWidth: 1)
                    )
                FuRecipeNumber(index: gradientIndex + 1)
                    .padding(4)
                if recipe.source.hasPrefix("ai") {
                    // Build 81 — Savanne wants a marker on AI-drafted
                    // recipes so she can tell at a glance which were
                    // generated. Sparkle pinned top-right of the image.
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(SMColor.aiPurple.opacity(0.92), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(4)
                        .accessibilityLabel("AI-drafted recipe")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(recipe.name)
                    .font(SMFont.serifDisplay(16))
                    .foregroundStyle(SMColor.ink)
                    .lineLimit(2)

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
                        Text("\(prep)m")
                            .font(SMFont.handwritten(13))
                            .foregroundStyle(SMColor.inkSoft)
                    }
                }
            }
            .padding(.horizontal, SMSpacing.sm)
            .padding(.bottom, SMSpacing.sm)
        }
        .padding(SMSpacing.sm)
        .background(SMColor.paperAlt)
        .overlay(
            Rectangle().stroke(SMColor.rule, lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            if recipe.favorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(SMColor.ember)
                    .offset(x: 4, y: -8)
            }
        }
        .rotationEffect(.degrees(rotation))
    }
}
