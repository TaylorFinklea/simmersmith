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
        // Build 82 — Savanne reported the broccoli carrot icon
        // overflowed its row. The fixed 40pt SF Symbol blew past the
        // 44pt list-row frame because some symbols (carrot, cake)
        // have taller bounding boxes than fork.knife. Switch to
        // resizable + scaledToFit so the icon scales with whatever
        // size the call site asks for, and clip the container so
        // nothing ever escapes.
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

                Image(systemName: iconName)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: palette.end.opacity(0.6), radius: side * 0.05)
                    .padding(side * 0.28)

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

    // MARK: - Category derivation

    private struct Palette {
        let start: Color
        let end: Color
    }

    private var iconName: String {
        let name = recipe.name.lowercased()
        let mealType = recipe.mealType.lowercased()
        let cuisine = recipe.cuisine.lowercased()
        let tags = recipe.tags.map { $0.lowercased() }

        if mealType == "breakfast" { return "sun.max.fill" }
        if mealType == "dessert" || name.contains("cake") || name.contains("cookie") || name.contains("brownie") || name.contains("pie") {
            return "birthday.cake.fill"
        }
        if mealType == "snack" { return "popcorn.fill" }

        if name.contains("soup") || name.contains("stew") || name.contains("chili") || name.contains("broth") {
            return "cup.and.saucer.fill"
        }
        if name.contains("salad") || name.contains("slaw") {
            return "leaf.fill"
        }
        if name.contains("fish") || name.contains("salmon") || name.contains("tuna") || name.contains("shrimp") || name.contains("seafood") || name.contains("cod") {
            return "fish.fill"
        }
        if name.contains("pizza") {
            return "circle.grid.2x2.fill"
        }
        if name.contains("sandwich") || name.contains("burger") || name.contains("wrap") || name.contains("taco") || name.contains("burrito") {
            return "fork.knife"
        }
        if name.contains("pasta") || name.contains("noodle") || name.contains("spaghetti") || name.contains("lasagna") {
            return "fork.knife"
        }

        if tags.contains("vegetarian") || tags.contains("vegan") || cuisine.contains("vegetarian") {
            return "carrot.fill"
        }

        if cuisine.contains("mexican") || cuisine.contains("indian") || tags.contains("spicy") {
            return "flame.fill"
        }

        return "fork.knife"
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
