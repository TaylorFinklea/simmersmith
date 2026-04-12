import SwiftUI
import SimmerSmithKit

struct CompactRecipeCard: View {
    let recipe: RecipeSummary
    let gradientIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            // TODO: When RecipeSummary gains an imageURL field, replace this gradient
            // placeholder with AsyncImage:
            //   if let imageURL = recipe.imageURL, let url = URL(string: imageURL) {
            //       AsyncImage(url: url) { image in
            //           image.resizable().aspectRatio(contentMode: .fill)
            //       } placeholder: { gradient }
            //   }
            RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous)
                .fill(SMColor.recipeGradients[gradientIndex % SMColor.recipeGradients.count])
                .frame(height: 56)
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
