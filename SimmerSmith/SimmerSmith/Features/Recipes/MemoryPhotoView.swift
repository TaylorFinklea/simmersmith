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
    /// Last-started-wins guard: overlapping retries (a sync burst bumps the
    /// generation several times) must not let an OLDER in-flight load resume
    /// last and stomp a just-loaded image back to nil.
    @State private var loadEpoch = 0

    /// Bumps on every household-store change; nil on the Fly path (no repository).
    /// simmersmith-zgt: the `ckmem:<id>` cacheBuster is deterministic, so on a
    /// participant device whose CKAsset lands after first render nothing else
    /// re-triggers `load()` — the placeholder stuck until view teardown.
    private var storeGeneration: Int? {
        #if canImport(CloudKit)
        appState.recipeRepository?.storeGeneration
        #else
        nil
        #endif
    }

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
        .onChange(of: storeGeneration) {
            // Retry only while empty: a store change can mean the missing
            // asset just arrived. Once bytes are shown, later changes are
            // irrelevant (a memory photo is set once at compose time).
            guard imageData == nil else { return }
            Task { await load() }
        }
    }

    private func load() async {
        loadEpoch += 1
        let epoch = loadEpoch
        do {
            let bytes = try await appState.fetchRecipeMemoryPhotoBytes(
                recipeID: recipeID,
                memoryID: memoryID
            )
            guard epoch == loadEpoch else { return }
            imageData = bytes
        } catch {
            guard epoch == loadEpoch else { return }
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
