import SimmerSmithKit
import SwiftUI
import UIKit

/// Shared recipe visual: the editorial meal illustration renders immediately,
/// then a stored recipe photo fades over it when locally available.
struct RecipeHeaderImage: View {
    let recipe: RecipeSummary
    var contentMode: ContentMode = .fill
    var isLoading: Bool = false
    var isDecorative: Bool = true

    @Environment(AppState.self) private var appState
    @State private var presentation = RecipeImagePresentationState()

    private var requestID: RecipeImageRequestID? {
        guard let imageToken = recipe.imageUrl else { return nil }
        return RecipeImageRequestID(
            recipeID: recipe.recipeId,
            imageToken: imageToken,
            loaderRevision: appState.recipeImageLoader.revision(for: recipe.recipeId)
        )
    }

    private var storeGeneration: Int? {
        #if canImport(CloudKit)
        appState.recipeRepository?.storeGeneration
        #else
        nil
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                fallback(side: side)

                if let image = presentation.image(for: requestID) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
                }

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
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(isDecorative)
            .accessibilityLabel("\(recipe.name) recipe image")
        }
        .task(id: requestID) {
            await load(requestID)
        }
        .onChange(of: storeGeneration) {
            guard presentation.shouldRetry(requestID) else { return }
            Task { await load(requestID) }
        }
    }

    private func fallback(side: CGFloat) -> some View {
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
        }
    }

    private func load(_ requestID: RecipeImageRequestID?) async {
        let epoch = presentation.begin(requestID)
        guard let requestID else { return }
        let image = await appState.recipeImageLoader.image(
            recipeID: requestID.recipeID,
            imageToken: requestID.imageToken
        )
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            presentation.complete(image, requestID: requestID, epoch: epoch)
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
