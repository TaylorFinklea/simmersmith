import SwiftUI
import SimmerSmithKit

struct HeroRecipeCard: View {
    let recipe: RecipeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: SMSpacing.md) {
            // TODO: When RecipeSummary gains an imageURL field, replace this gradient
            // placeholder with AsyncImage:
            //   if let imageURL = recipe.imageURL, let url = URL(string: imageURL) {
            //       AsyncImage(url: url) { image in
            //           image.resizable().aspectRatio(contentMode: .fill)
            //       } placeholder: { gradient }
            //   }
            RoundedRectangle(cornerRadius: SMRadius.lg, style: .continuous)
                .fill(SMColor.headerGradient)
                .frame(height: 120)
                .overlay(alignment: .bottomTrailing) {
                    if recipe.favorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(SMColor.favoritePink)
                            .padding(SMSpacing.md)
                    }
                }

            VStack(alignment: .leading, spacing: SMSpacing.sm) {
                Text(recipe.name)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(SMColor.textPrimary)
                    .lineLimit(2)

                HStack(spacing: SMSpacing.md) {
                    if !recipe.cuisine.isEmpty {
                        CuisinePill(text: recipe.cuisine)
                    }
                    if let prep = recipe.prepMinutes, prep > 0 {
                        TimeBadge(minutes: prep)
                    }
                    if let cook = recipe.cookMinutes, cook > 0 {
                        Label("\(cook) min cook", systemImage: "flame")
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.accent)
                    }
                    Label("\(recipe.ingredients.count)", systemImage: "leaf")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
            .padding(.horizontal, SMSpacing.lg)
            .padding(.bottom, SMSpacing.lg)
        }
        .background(SMColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: SMRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SMRadius.xl, style: .continuous)
                .strokeBorder(SMColor.divider, lineWidth: 0.5)
        )
    }
}
