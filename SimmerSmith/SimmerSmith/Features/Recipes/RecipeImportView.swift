import PDFKit
import PhotosUI
import SimmerSmithKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import VisionKit

struct RecipeImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onImported: (RecipeDraft) -> Void

    @State private var url = ""
    @State private var isImporting = false
    @State private var importStatusMessage = ""
    @State private var errorMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPDFImporterPresented = false
    @State private var isDocumentScannerPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipe URL") {
                    TextField("https://example.com/recipe", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()

                    Button {
                        Task { await runURLImport() }
                    } label: {
                        Text(isImporting && importStatusMessage == "Importing from URL…" ? "Importing…" : "Import Recipe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }

                Section("Scan Import") {
                    Button {
                        isDocumentScannerPresented = true
                    } label: {
                        Label("Scan from Camera", systemImage: "camera.viewfinder")
                    }
                    .disabled(isImporting)

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared()) {
                        Label("Choose Photo", systemImage: "photo.on.rectangle")
                    }
                    .disabled(isImporting)

                    Button {
                        isPDFImporterPresented = true
                    } label: {
                        Label("Import PDF", systemImage: "doc.richtext")
                    }
                    .disabled(isImporting)

                    Text("Scans open as editable drafts before save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isImporting {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(importStatusMessage)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Recipe")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isDocumentScannerPresented) {
            RecipeDocumentScanner { images in
                Task { await importFromScannedImages(images) }
            }
        }
        .fileImporter(
            isPresented: $isPDFImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await importFromPDF(url) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .task(id: selectedPhotoItem) {
            guard let selectedPhotoItem else { return }
            await importFromPhotoPickerItem(selectedPhotoItem)
            self.selectedPhotoItem = nil
        }
    }

    private func runURLImport() async {
        await performImport(statusMessage: "Importing from URL…") {
            let draft = try await appState.importRecipeDraft(fromURL: url.trimmingCharacters(in: .whitespacesAndNewlines))
            onImported(draft)
            dismiss()
        }
    }

    private func importFromPhotoPickerItem(_ item: PhotosPickerItem) async {
        await performImport(statusMessage: "Reading photo…") {
            guard let imageData = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: imageData) else {
                throw RecipeImportCaptureError.unreadablePhoto
            }
            let extractedText = try await RecipeTextExtractor.extractText(from: [image])
            try await finishTextImport(
                text: extractedText,
                title: "",
                source: "scan_import",
                sourceLabel: "Photo import",
                sourceURL: ""
            )
        }
    }

    private func importFromScannedImages(_ images: [UIImage]) async {
        await performImport(statusMessage: "Scanning recipe…") {
            guard !images.isEmpty else {
                throw RecipeImportCaptureError.noPagesScanned
            }
            let extractedText = try await RecipeTextExtractor.extractText(from: images)
            try await finishTextImport(
                text: extractedText,
                title: "",
                source: "scan_import",
                sourceLabel: "Camera scan",
                sourceURL: ""
            )
        }
    }

    private func importFromPDF(_ url: URL) async {
        await performImport(statusMessage: "Reading PDF…") {
            let extracted = try await RecipeTextExtractor.extractText(fromPDFAt: url)
            try await finishTextImport(
                text: extracted.text,
                title: extracted.title,
                source: "scan_import",
                sourceLabel: url.deletingPathExtension().lastPathComponent,
                sourceURL: ""
            )
        }
    }

    private func finishTextImport(
        text: String,
        title: String,
        source: String,
        sourceLabel: String,
        sourceURL: String
    ) async throws {
        let draft = try await appState.importRecipeDraft(
            fromText: text,
            title: title,
            source: source,
            sourceLabel: sourceLabel,
            sourceURL: sourceURL
        )
        onImported(draft)
        dismiss()
    }

    private func performImport(
        statusMessage: String,
        operation: @escaping () async throws -> Void
    ) async {
        isImporting = true
        importStatusMessage = statusMessage
        errorMessage = nil
        defer {
            isImporting = false
            importStatusMessage = ""
        }

        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum RecipeImportCaptureError: LocalizedError {
    case unreadablePhoto
    case noPagesScanned
    case noReadableText
    case unreadablePDF

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto:
            return "The selected photo could not be read."
        case .noPagesScanned:
            return "No pages were captured."
        case .noReadableText:
            return "No readable recipe text was found."
        case .unreadablePDF:
            return "The selected PDF could not be read."
        }
    }
}

private struct ExtractedRecipeText {
    let text: String
    let title: String
}

private enum RecipeTextExtractor {
    static func extractText(from images: [UIImage]) async throws -> String {
        let combinedText = try await Task.detached(priority: .userInitiated) {
            let pageTexts = try images.map { image in
                try recognizeText(in: image)
            }
            return pageTexts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }.value

        guard !combinedText.isEmpty else {
            throw RecipeImportCaptureError.noReadableText
        }
        return combinedText
    }

    static func extractText(fromPDFAt url: URL) async throws -> ExtractedRecipeText {
        let extracted = try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else {
                throw RecipeImportCaptureError.unreadablePDF
            }

            var pageTexts: [String] = []
            var renderedPages: [UIImage] = []

            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !pageText.isEmpty {
                    pageTexts.append(pageText)
                    continue
                }

                let pageBounds = page.bounds(for: .mediaBox)
                let renderSize = CGSize(
                    width: max(pageBounds.width, 1600),
                    height: max(pageBounds.height, 1600)
                )
                renderedPages.append(page.thumbnail(of: renderSize, for: .mediaBox))
            }

            let ocrText = try renderedPages.map { image in
                try recognizeText(in: image)
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

            let combinedText = (pageTexts + [ocrText])
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")

            guard !combinedText.isEmpty else {
                throw RecipeImportCaptureError.noReadableText
            }

            let title = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")

            return ExtractedRecipeText(text: combinedText, title: title)
        }.value

        return extracted
    }

    private static func recognizeText(in image: UIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler: VNImageRequestHandler
        if let cgImage = image.cgImage {
            handler = VNImageRequestHandler(cgImage: cgImage)
        } else if let ciImage = CIImage(image: image) {
            handler = VNImageRequestHandler(ciImage: ciImage)
        } else {
            throw RecipeImportCaptureError.noReadableText
        }

        try handler.perform([request])
        let observations = request.results ?? []
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

private struct RecipeDocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onScan: ([UIImage]) -> Void

        init(onScan: @escaping ([UIImage]) -> Void) {
            self.onScan = onScan
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            controller.dismiss(animated: true)
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            let images = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true)
            onScan(images)
        }
    }
}
