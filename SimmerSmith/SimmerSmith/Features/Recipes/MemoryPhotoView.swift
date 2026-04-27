import SimmerSmithKit
import SwiftUI
import UIKit

/// Lazily loads + decodes the bytes for a memory photo via the
/// authenticated session. Mirrors the M14 `RecipeHeaderImage`
/// pattern: bytes are fetched on-task; while loading or on miss
/// we render a soft surfaceCard placeholder so the row never jumps.
struct MemoryPhotoView: View {
    let recipeID: String
    let memoryID: String
    let cacheBuster: String?
    var contentMode: ContentMode = .fill

    @Environment(AppState.self) private var appState
    @State private var imageData: Data?

    var body: some View {
        ZStack {
            Rectangle().fill(SMColor.surfaceCard)
            if let imageData, let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: cacheBuster ?? memoryID) {
            await load()
        }
    }

    private func load() async {
        do {
            imageData = try await appState.fetchRecipeMemoryPhotoBytes(
                recipeID: recipeID,
                memoryID: memoryID
            )
        } catch {
            imageData = nil
        }
    }
}

/// Full-screen photo viewer used when the user taps a memory row's
/// thumbnail. Tap-to-dismiss; black backdrop so the photo gets the
/// whole canvas.
struct MemoryPhotoViewer: View {
    let recipeID: String
    let memoryID: String
    let cacheBuster: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MemoryPhotoView(
                recipeID: recipeID,
                memoryID: memoryID,
                cacheBuster: cacheBuster,
                contentMode: .fit
            )
            .ignoresSafeArea()

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(SMSpacing.lg)
                    }
                }
                Spacer()
            }
        }
        .onTapGesture { dismiss() }
    }
}
