import PhotosUI
import SimmerSmithKit
import SwiftUI
import UIKit

/// Compose sheet for adding a memory to the recipe log. Body text
/// is required; the photo is optional. Photos are resized to a
/// 2048px max side and JPEG-compressed at 0.8 quality (same ceiling
/// as `CookCheckView.swift:171–188`) before being base64-encoded
/// and posted alongside the body.
struct MemoryComposeSheet: View {
    let recipeID: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var bodyText: String = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var attachedJPEG: Data?
    @State private var isLoadingPhoto = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("What happened") {
                    TextField(
                        "Tonight we paired this with a salad…",
                        text: $bodyText,
                        axis: .vertical
                    )
                    .lineLimit(4, reservesSpace: true)
                }

                Section("Photo (optional)") {
                    PhotosPicker(
                        selection: $selectedPhoto,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        Label(attachedImage == nil ? "Attach photo" : "Replace photo",
                              systemImage: "photo.on.rectangle.angled")
                    }

                    if isLoadingPhoto {
                        HStack(spacing: SMSpacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Preparing photo…")
                                .foregroundStyle(.secondary)
                        }
                    } else if let attachedImage {
                        HStack(spacing: SMSpacing.md) {
                            Image(uiImage: attachedImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: SMRadius.sm, style: .continuous))
                            Spacer()
                            Button("Remove", role: .destructive) {
                                self.attachedImage = nil
                                self.attachedJPEG = nil
                                self.selectedPhoto = nil
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New memory")
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
        isSaving || isLoadingPhoto
            || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await appState.createRecipeMemory(
                recipeID: recipeID,
                body: trimmed,
                imageData: attachedJPEG,
                mimeType: attachedJPEG == nil ? nil : "image/jpeg"
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadSelectedPhoto() async {
        guard let selectedPhoto else { return }
        isLoadingPhoto = true
        errorMessage = nil
        defer { isLoadingPhoto = false }
        do {
            guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw MemoryPhotoError.unreadable
            }
            attachedJPEG = try compressForUpload(image)
            attachedImage = image
        } catch {
            errorMessage = error.localizedDescription
            attachedImage = nil
            attachedJPEG = nil
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
            throw MemoryPhotoError.compressionFailed
        }
        return data
    }
}

private enum MemoryPhotoError: LocalizedError {
    case unreadable
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The selected photo could not be read."
        case .compressionFailed: return "Could not compress the photo for upload."
        }
    }
}
