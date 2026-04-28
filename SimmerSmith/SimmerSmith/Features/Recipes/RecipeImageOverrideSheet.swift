import PhotosUI
import SimmerSmithKit
import SwiftUI
import UIKit

/// Sheet for replacing the AI-generated recipe image with a
/// user-uploaded photo. Reuses `compressPhotoForUpload(_:)` from
/// the Utilities module so all photo uploads share the same
/// 2048px / JPEG 0.8 ceiling.
struct RecipeImageOverrideSheet: View {
    let recipeID: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var preview: UIImage?
    @State private var compressedJPEG: Data?
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    PhotosPicker(
                        selection: $selectedPhoto,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(
                            preview == nil ? "Choose photo" : "Replace photo",
                            systemImage: "photo.on.rectangle.angled"
                        )
                    }

                    if isLoadingPhoto {
                        HStack(spacing: SMSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Preparing photo…").foregroundStyle(.secondary)
                        }
                    } else if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    } else {
                        Text("Replaces the AI-generated image. Pick a photo of the dish you actually cooked.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Use my own photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(isSaveDisabled)
                }
            }
            .task(id: selectedPhoto) {
                await loadSelectedPhoto()
            }
        }
    }

    private var isSaveDisabled: Bool {
        isSaving || isLoadingPhoto || compressedJPEG == nil
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }
        isLoadingPhoto = true
        errorMessage = nil
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw OverrideError.unreadable
            }
            compressedJPEG = try compressPhotoForUpload(image)
            preview = image
        } catch {
            errorMessage = error.localizedDescription
            preview = nil
            compressedJPEG = nil
        }
    }

    private func save() async {
        guard let compressedJPEG else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await appState.uploadRecipeImage(
                recipeID: recipeID,
                imageData: compressedJPEG,
                mimeType: "image/jpeg"
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum OverrideError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The selected photo could not be read."
        }
    }
}
