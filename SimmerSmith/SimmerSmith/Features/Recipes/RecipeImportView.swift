import PDFKit
import PhotosUI
import SimmerSmithKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Vision
import VisionKit

enum RecipeImportLaunchMode: String, Identifiable {
    case url
    case camera
    case photo
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .url:
            "Import from URL"
        case .camera:
            "Scan from Camera"
        case .photo:
            "Import from Photo"
        case .pdf:
            "Import from PDF"
        }
    }
}

struct RecipeImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onImported: (RecipeDraft) -> Void
    let preferredLaunchMode: RecipeImportLaunchMode

    @State private var url = ""
    @State private var isImporting = false
    @State private var importStatusMessage = ""
    @State private var errorMessage: String?
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPDFImporterPresented = false
    @State private var isDocumentScannerPresented = false
    @State private var pendingTextReview: PendingTextImportReview?
    @State private var didTriggerPreferredAction = false

    init(
        preferredLaunchMode: RecipeImportLaunchMode = .url,
        onImported: @escaping (RecipeDraft) -> Void
    ) {
        self.preferredLaunchMode = preferredLaunchMode
        self.onImported = onImported
    }

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

                if preferredLaunchMode != .url {
                    Section("Quick Start") {
                        Text(preferredLaunchMode.title)
                            .font(.headline)
                        Text(launchModeHelpText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
            .task {
                guard !didTriggerPreferredAction else { return }
                didTriggerPreferredAction = true
                switch preferredLaunchMode {
                case .camera:
                    isDocumentScannerPresented = true
                case .pdf:
                    isPDFImporterPresented = true
                case .url, .photo:
                    break
                }
            }
        }
        .sheet(isPresented: $isDocumentScannerPresented) {
            RecipeDocumentScanner(
                onScan: { images in
                    Task { await importFromScannedImages(images) }
                },
                onFailure: { message in
                    errorMessage = message
                }
            )
        }
        .sheet(item: $pendingTextReview) { review in
            RecipeTextReviewView(
                review: review,
                onImported: { draft in
                    onImported(draft)
                    dismiss()
                }
            )
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

    private var launchModeHelpText: String {
        switch preferredLaunchMode {
        case .url:
            "Paste a recipe URL to cleanly import it into an editable draft."
        case .camera:
            "Capture a printed recipe or cookbook page and review it before saving."
        case .photo:
            "Choose a recipe photo from your library. OCR text still opens as a draft for review."
        case .pdf:
            "Import a PDF recipe or recipe card and turn it into an editable draft."
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
            let extracted = try await RecipeTextExtractor.extractText(from: [image])
            try await handleCapturedTextImport(
                extracted,
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
            let extracted = try await RecipeTextExtractor.extractText(from: images)
            try await handleCapturedTextImport(
                extracted,
                source: "scan_import",
                sourceLabel: "Camera scan",
                sourceURL: ""
            )
        }
    }

    private func importFromPDF(_ url: URL) async {
        await performImport(statusMessage: "Reading PDF…") {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let extracted = try await RecipeTextExtractor.extractText(fromPDFAt: url)
            try await handleCapturedTextImport(
                extracted,
                source: "scan_import",
                sourceLabel: url.deletingPathExtension().lastPathComponent,
                sourceURL: ""
            )
        }
    }

    private func handleCapturedTextImport(
        _ extracted: ExtractedRecipeText,
        source: String,
        sourceLabel: String,
        sourceURL: String
    ) async throws {
        if extracted.reviewReasons.isEmpty {
            try await finishTextImport(
                text: extracted.text,
                title: extracted.title,
                source: source,
                sourceLabel: sourceLabel,
                sourceURL: sourceURL
            )
            return
        }

        pendingTextReview = PendingTextImportReview(
            title: extracted.title,
            text: extracted.text,
            source: source,
            sourceLabel: sourceLabel,
            sourceURL: sourceURL,
            reviewReasons: extracted.reviewReasons
        )
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
    let reviewReasons: [String]
}

private struct PendingTextImportReview: Identifiable {
    let id = UUID()
    let title: String
    let text: String
    let source: String
    let sourceLabel: String
    let sourceURL: String
    let reviewReasons: [String]
}

private struct OCRPageExtraction {
    let text: String
    let averageConfidence: Double
}

private enum RecipeTextExtractor {
    static func extractText(from images: [UIImage]) async throws -> ExtractedRecipeText {
        let extracted = try await Task.detached(priority: .userInitiated) {
            let pageExtractions = try images.map { image in
                try recognizeText(in: image)
            }
            let pageTexts = pageExtractions
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let combinedText = pageTexts.joined(separator: "\n\n")
            guard !combinedText.isEmpty else {
                throw RecipeImportCaptureError.noReadableText
            }

            let averageConfidence = pageExtractions.isEmpty
                ? nil
                : pageExtractions.map(\.averageConfidence).reduce(0, +) / Double(pageExtractions.count)
            return ExtractedRecipeText(
                text: combinedText,
                title: "",
                reviewReasons: RecipeTextReviewHeuristics.reviewReasons(
                    for: combinedText,
                    averageConfidence: averageConfidence,
                    usedOCRFallback: false
                )
            )
        }.value

        return extracted
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

            let ocrExtractions = try renderedPages.map { image in
                try recognizeText(in: image)
            }
            let ocrText = ocrExtractions
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
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

            let averageConfidence = ocrExtractions.isEmpty
                ? nil
                : ocrExtractions.map(\.averageConfidence).reduce(0, +) / Double(ocrExtractions.count)
            return ExtractedRecipeText(
                text: combinedText,
                title: title,
                reviewReasons: RecipeTextReviewHeuristics.reviewReasons(
                    for: combinedText,
                    averageConfidence: averageConfidence,
                    usedOCRFallback: !ocrExtractions.isEmpty
                )
            )
        }.value

        return extracted
    }

    private static func recognizeText(in image: UIImage) throws -> OCRPageExtraction {
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
        let topCandidates = observations.compactMap { $0.topCandidates(1).first }
        let text = topCandidates
            .map(\.string)
            .joined(separator: "\n")
        let averageConfidence = topCandidates.isEmpty
            ? 0
            : topCandidates.map { Double($0.confidence) }.reduce(0, +) / Double(topCandidates.count)
        return OCRPageExtraction(text: text, averageConfidence: averageConfidence)
    }
}

private enum RecipeTextReviewHeuristics {
    static func reviewReasons(
        for text: String,
        averageConfidence: Double?,
        usedOCRFallback: Bool
    ) -> [String] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var reasons: [String] = []
        if let averageConfidence, averageConfidence < 0.82 {
            reasons.append("The scan confidence was low, so a few words may need cleanup.")
        }
        if usedOCRFallback {
            reasons.append("At least one PDF page needed OCR, so review the extracted text before import.")
        }

        let fragmentedLineCount = lines.filter { $0.split(separator: " ").count <= 2 }.count
        if lines.count >= 6, Double(fragmentedLineCount) / Double(lines.count) >= 0.35 {
            reasons.append("The extracted text looks fragmented across short lines.")
        }

        let lowercasedLines = lines.map { $0.lowercased() }
        let hasIngredientSignal = lowercasedLines.contains(where: {
            $0 == "ingredients" || RecipeTextClassification.looksLikeIngredientLine($0)
        })
        let hasStepSignal = lowercasedLines.contains(where: {
            ["instructions", "directions", "method", "preparation"].contains($0) || RecipeTextClassification.looksLikeStepLine($0)
        })
        if !(hasIngredientSignal && hasStepSignal) {
            reasons.append("Ingredients and steps were not clearly separated.")
        }

        return reasons
    }
}

private enum RecipeTextClassification {
    private static let leadingQuantityExpression = try! NSRegularExpression(
        pattern: #"^(?:\d+\s+\d+/\d+|\d+-\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)\b"#,
        options: []
    )

    private static let stepVerbPrefixes: Set<String> = [
        "add", "arrange", "bake", "beat", "blend", "boil", "bring", "broil", "chill",
        "combine", "cook", "cover", "cut", "drain", "fold", "garnish", "grill", "heat",
        "knead", "let", "marinate", "mix", "place", "pour", "preheat", "reduce",
        "refrigerate", "rest", "roast", "saute", "sauté", "season", "serve", "simmer",
        "sprinkle", "stir", "toast", "top", "transfer", "whisk"
    ]

    private static let notePhrases = [
        "to taste",
        "for serving",
        "for garnish",
        "plus more",
        "plus extra",
        "optional",
        "divided"
    ]

    static func looksLikeIngredientLine(_ line: String) -> Bool {
        let cleaned = cleanedLine(line)
        if cleaned.isEmpty {
            return false
        }
        if hasLeadingQuantity(cleaned) {
            return true
        }
        if notePhrases.contains(where: { cleaned.contains($0) }) {
            return cleaned.split(separator: " ").count <= 6
        }
        if cleaned.hasSuffix(".") || looksLikeStepLine(cleaned) {
            return false
        }
        return cleaned.split(separator: " ").count <= 8
    }

    static func looksLikeStepLine(_ line: String) -> Bool {
        let cleaned = cleanedLine(line)
        guard !cleaned.isEmpty else { return false }
        if cleaned.range(of: #"^(?:step\s*)?\d+[\).\:-]\s*.+$"#, options: .regularExpression) != nil {
            return true
        }
        if cleaned.range(of: #"^[a-z][\).\:-]\s*.+$"#, options: .regularExpression) != nil {
            return true
        }
        let words = cleaned.split(separator: " ")
        if cleaned.hasSuffix(".") && words.count >= 4 {
            return true
        }
        guard let firstWord = words.first?.lowercased() else {
            return false
        }
        return stepVerbPrefixes.contains(firstWord) && words.count >= 4
    }

    private static func hasLeadingQuantity(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: line.utf16.count)
        return leadingQuantityExpression.firstMatch(in: line, options: [], range: range) != nil
    }

    private static func cleanedLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[\-\*\u{2022}\u{25E6}\u{2043}]+\s*"#, with: "", options: .regularExpression)
            .lowercased()
    }
}

private struct RecipeDocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        private let onScan: ([UIImage]) -> Void
        private let onFailure: (String) -> Void

        init(onScan: @escaping ([UIImage]) -> Void, onFailure: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onFailure = onFailure
        }

        @MainActor
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }

        @MainActor
        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            let message = error.localizedDescription
            controller.dismiss(animated: true)
            onFailure(message)
        }

        @MainActor
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

private struct RecipeTextReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let review: PendingTextImportReview
    let onImported: (RecipeDraft) -> Void

    @State private var title: String
    @State private var extractedText: String
    @State private var isImporting = false
    @State private var errorMessage: String?

    init(
        review: PendingTextImportReview,
        onImported: @escaping (RecipeDraft) -> Void
    ) {
        self.review = review
        self.onImported = onImported
        _title = State(initialValue: review.title)
        _extractedText = State(initialValue: review.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Review the extracted text before turning it into a draft recipe.")
                        .foregroundStyle(.secondary)
                }

                if !review.reviewReasons.isEmpty {
                    Section("Why this needs review") {
                        ForEach(review.reviewReasons, id: \.self) { reason in
                            Text(reason)
                        }
                    }
                }

                Section("Recipe Title") {
                    TextField("Imported recipe", text: $title)
                }

                Section("Extracted Text") {
                    TextEditor(text: $extractedText)
                        .frame(minHeight: 260)
                        .font(.body.monospaced())
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Review Scan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isImporting ? "Importing…" : "Import Draft") {
                        Task { await importDraft() }
                    }
                    .disabled(extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }
            }
        }
    }

    private func importDraft() async {
        isImporting = true
        errorMessage = nil
        defer { isImporting = false }

        do {
            let draft = try await appState.importRecipeDraft(
                fromText: extractedText,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                source: review.source,
                sourceLabel: review.sourceLabel,
                sourceURL: review.sourceURL
            )
            onImported(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
