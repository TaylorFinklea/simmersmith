import SimmerSmithKit
import SwiftUI

/// Loads the AI-generated recipe header image via the authenticated
/// API client and falls back to the gradient placeholder while
/// loading or when no image exists yet. Reuses the same gradient
/// the Recipes view uses so an image-less recipe never looks
/// half-styled. Used by `RecipeDetailView`'s header and by the
/// recipe list cards in Phase 3.
struct RecipeHeaderImage: View {
    let recipe: RecipeSummary
    var contentMode: ContentMode = .fill
    var isLoading: Bool = false

    @Environment(AppState.self) private var appState
    @State private var imageData: Data?

    var body: some View {
        ZStack {
            gradient
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
            if isLoading {
                Rectangle()
                    .fill(Color.black.opacity(0.35))
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
            }
        }
        .task(id: recipe.imageUrl ?? "") {
            await load()
        }
    }

    private var gradient: some View {
        let hash = abs(recipe.recipeId.hashValue)
        let palette = SMColor.recipeGradients
        return Rectangle().fill(palette[hash % palette.count])
    }

    private func load() async {
        // No image yet — keep showing the gradient.
        guard recipe.imageUrl != nil else {
            imageData = nil
            return
        }
        do {
            imageData = try await appState.fetchRecipeImageBytes(recipeID: recipe.recipeId)
        } catch {
            // Silent fail — gradient stays visible. Logging would
            // get noisy on every detail open before backfill runs.
            imageData = nil
        }
    }
}
