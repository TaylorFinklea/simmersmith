import PhotosUI
import SimmerSmithKit
import SwiftUI
import UIKit

/// Take a photo (or choose one from the library) and ask the AI to identify
/// the ingredient. The result card surfaces alternate names, cuisine uses,
/// and a "Find matching recipes" action that drops the user back into the
/// Recipes tab with the right search term pre-applied.
///
/// Camera capture is intentionally PhotosPicker-only for the M11 first cut —
/// users take a photo with the iOS Camera app, then pick it. Native in-app
/// camera capture is straightforward to add as a polish follow-up.
struct IngredientScannerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Called when the user taps "Find matching recipes" with the chosen
    /// search term. The host view is responsible for dismissing this sheet
    /// and routing to RecipesView with the term applied.
    let onFindRecipes: (String) -> Void

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var isIdentifying = false
    @State private var errorMessage: String?
    @State private var result: IngredientIdentification?

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    resultSection(for: result)
                    actionSection(for: result)
                } else if isIdentifying {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Identifying ingredient…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    captureSection
                    helpSection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Identify ingredient")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if result != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Scan again") { reset() }
                    }
                }
            }
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            await loadAndIdentify(from: selectedPhoto)
            self.selectedPhoto = nil
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        Section("Photo") {
            PhotosPicker(
                selection: $selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose photo", systemImage: "photo.on.rectangle.angled")
            }

            Text("Take the photo with your iOS Camera, then choose it from your library.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var helpSection: some View {
        Section("What this does") {
            Label("Identifies the ingredient", systemImage: "questionmark.circle")
            Label("Shows how different cuisines use it", systemImage: "globe")
            Label("Finds recipes in your library", systemImage: "magnifyingglass")
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func resultSection(for result: IngredientIdentification) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.name.capitalized).font(.title3.bold())
                Text(confidenceLabel(result.confidence))
                    .font(.caption)
                    .foregroundStyle(confidenceColor(result.confidence))
            }
            if !result.commonNames.isEmpty {
                Text("Also known as: \(result.commonNames.joined(separator: ", "))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !result.notes.isEmpty {
                Text(result.notes).font(.footnote)
            }
        }

        if !result.cuisineUses.isEmpty {
            Section("Around the world") {
                ForEach(result.cuisineUses, id: \.country) { use in
                    HStack {
                        Text(use.country).foregroundStyle(.secondary)
                        Spacer()
                        Text(use.dish).multilineTextAlignment(.trailing)
                    }
                    .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private func actionSection(for result: IngredientIdentification) -> some View {
        let term = preferredSearchTerm(for: result)
        Section {
            Button {
                dismiss()
                onFindRecipes(term)
            } label: {
                Label("Find recipes with \(term)", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(term.isEmpty)
        }
    }

    private func preferredSearchTerm(for result: IngredientIdentification) -> String {
        if !result.recipeMatchTerms.isEmpty {
            return result.recipeMatchTerms.first ?? result.name
        }
        return result.name
    }

    private func confidenceLabel(_ confidence: String) -> String {
        switch confidence.lowercased() {
        case "high": return "Confident match"
        case "medium": return "Pretty sure"
        case "low": return "Could be wrong — double-check"
        default: return "Match"
        }
    }

    private func confidenceColor(_ confidence: String) -> Color {
        switch confidence.lowercased() {
        case "high": return .green
        case "medium": return .orange
        case "low": return .red
        default: return .secondary
        }
    }

    private func reset() {
        result = nil
        pickedImage = nil
        errorMessage = nil
        selectedPhoto = nil
    }

    private func loadAndIdentify(from item: PhotosPickerItem) async {
        isIdentifying = true
        errorMessage = nil
        defer { isIdentifying = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw VisionScanError.unreadablePhoto
            }
            pickedImage = image
            // Resize to fit ~2048px on the long edge and JPEG-compress so we
            // stay under the backend's 5 MB cap and avoid leaking HEIC issues.
            let jpegData = try compressForUpload(image)
            let identified = try await appState.identifyIngredient(imageData: jpegData)
            self.result = identified
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func compressForUpload(_ image: UIImage) throws -> Data {
        let maxSide: CGFloat = 2048
        let resized: UIImage = {
            let longest = max(image.size.width, image.size.height)
            guard longest > maxSide else { return image }
            let scale = maxSide / longest
            let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        }()
        guard let data = resized.jpegData(compressionQuality: 0.8) else {
            throw VisionScanError.compressionFailed
        }
        return data
    }
}

private enum VisionScanError: LocalizedError {
    case unreadablePhoto
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto: return "The selected photo could not be read."
        case .compressionFailed: return "Could not compress the photo for upload."
        }
    }
}
