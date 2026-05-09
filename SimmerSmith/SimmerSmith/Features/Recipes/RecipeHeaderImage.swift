import SimmerSmithKit
import SwiftUI

/// Build 81 — Savanne reported that AI-generated recipe photos all
/// looked too "AI" and undifferentiated. Replaced the photo path with
/// a gradient backdrop + centered SF Symbol food icon derived from the
/// recipe's mealType / cuisine / name. Keeps the visual rhythm of
/// every card without leaning on synthetic photography.
///
/// `imageUrl` is preserved on the model — we just stop fetching and
/// rendering it here. If the user wants AI photos back later, flip
/// `useIllustration` to false (or wire it to a Settings toggle) and
/// the previous `RecipeHeaderImage` behavior is below.
struct RecipeHeaderImage: View {
    let recipe: RecipeSummary
    var contentMode: ContentMode = .fill
    var isLoading: Bool = false

    var body: some View {
        // Build 83 — replaced SF Symbol path with hand-drawn MealIcon
        // glyphs. Resolves the icon via RecipeIconOverrides.shared so
        // a per-recipe pick wins, falling back to auto-detect.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(
                    colors: [palette.start, palette.end],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                PaperGrain()
                    .opacity(0.18)
                    .blendMode(.overlay)

                MealIconView(icon: resolvedIcon, color: .white.opacity(0.94))
                    .padding(side * 0.18)
                    .shadow(color: palette.end.opacity(0.5), radius: side * 0.04)

                if isLoading {
                    Rectangle().fill(Color.black.opacity(0.25))
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private var resolvedIcon: MealIcon {
        RecipeIconOverrides.shared.icon(for: recipe)
    }

    // MARK: - Category derivation

    private struct Palette {
        let start: Color
        let end: Color
    }

    private var palette: Palette {
        let mealType = recipe.mealType.lowercased()
        let cuisine = recipe.cuisine.lowercased()
        let name = recipe.name.lowercased()
        let tags = recipe.tags.map { $0.lowercased() }

        // Sweet (dessert)
        if mealType == "dessert" || name.contains("cake") || name.contains("cookie") || name.contains("brownie") || name.contains("pie") {
            return Palette(
                start: Color(red: 0.94, green: 0.66, blue: 0.72),
                end: Color(red: 0.96, green: 0.84, blue: 0.74)
            )
        }

        // Sunrise (breakfast)
        if mealType == "breakfast" {
            return Palette(
                start: Color(red: 0.99, green: 0.78, blue: 0.42),
                end: Color(red: 0.95, green: 0.55, blue: 0.32)
            )
        }

        // Sea (seafood / mediterranean)
        if name.contains("fish") || name.contains("salmon") || name.contains("tuna")
            || name.contains("shrimp") || name.contains("seafood")
            || cuisine.contains("mediterranean") || cuisine.contains("greek") {
            return Palette(
                start: Color(red: 0.34, green: 0.55, blue: 0.66),
                end: Color(red: 0.18, green: 0.34, blue: 0.50)
            )
        }

        // Garden (salad / vegetarian)
        if name.contains("salad") || name.contains("slaw")
            || tags.contains("vegetarian") || tags.contains("vegan") {
            return Palette(
                start: Color(red: 0.55, green: 0.66, blue: 0.42),
                end: Color(red: 0.32, green: 0.45, blue: 0.28)
            )
        }

        // Warm Forge (default — italian, mexican, asian, indian, generic)
        return Palette(
            start: Color(red: 0.91, green: 0.51, blue: 0.18),
            end: Color(red: 0.62, green: 0.28, blue: 0.12)
        )
    }
}
