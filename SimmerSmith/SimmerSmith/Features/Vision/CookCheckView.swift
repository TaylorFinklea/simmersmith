import PhotosUI
import SimmerSmithKit
import SwiftUI
import UIKit

/// Identifies the recipe + step the user is currently cooking. Used as a
/// sheet payload from `RecipeDetailView`.
struct CookCheckSheetContext: Identifiable, Hashable {
    let id = UUID()
    let recipeID: String
    let stepNumber: Int
    let stepText: String
}

/// "Snap a check" sheet — pick a photo of the dish in progress, send it to
/// the vision-AI cook-check endpoint, and show a verdict + tip inline.
/// The dedicated cook-mode UX (voice-friendly, hands-free, full-screen) is
/// a future milestone — this is the minimum viable surface so the feature
/// is exercisable from day one.
struct CookCheckSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: CookCheckSheetContext

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isChecking = false
    @State private var result: CookCheckResult?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Step \(context.stepNumber + 1)") {
                    Text(context.stepText)
                        .font(.body)
                        .foregroundStyle(.primary)
                }

                if let result {
                    resultSection(result)
                } else if isChecking {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Checking…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    captureSection
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Cook check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                if result != nil || errorMessage != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Try another") { reset() }
                            .foregroundStyle(SMColor.ember)
                    }
                }
            }
            .smithToolbar()
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            await loadAndCheck(from: selectedPhoto)
            self.selectedPhoto = nil
        }
    }

    @ViewBuilder
    private var captureSection: some View {
        Section {
            PhotosPicker(
                selection: $selectedPhoto,
                matching: .images,
                photoLibrary: .shared()
            ) {
                Label("Choose photo", systemImage: "photo.on.rectangle.angled")
            }
            Text("Snap a photo of your dish in progress, then choose it here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultSection(_ result: CookCheckResult) -> some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: verdictIcon(result.verdict))
                    .foregroundStyle(verdictColor(result.verdict))
                Text(verdictLabel(result.verdict))
                    .font(.headline)
                    .foregroundStyle(verdictColor(result.verdict))
            }
            Text(result.tip)
                .font(.body)
            if result.suggestedMinutesRemaining > 0 {
                Text("About \(result.suggestedMinutesRemaining) min more")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func verdictIcon(_ verdict: String) -> String {
        switch verdict.lowercased() {
        case "on_track": return "checkmark.circle"
        case "needs_more_time": return "clock"
        case "concerning": return "exclamationmark.triangle"
        default: return "questionmark.circle"
        }
    }

    private func verdictColor(_ verdict: String) -> Color {
        switch verdict.lowercased() {
        case "on_track": return .green
        case "needs_more_time": return .orange
        case "concerning": return .red
        default: return .secondary
        }
    }

    private func verdictLabel(_ verdict: String) -> String {
        switch verdict.lowercased() {
        case "on_track": return "On track"
        case "needs_more_time": return "Needs more time"
        case "concerning": return "Looks off"
        default: return "Hard to tell"
        }
    }

    private func reset() {
        result = nil
        errorMessage = nil
        selectedPhoto = nil
    }

    private func loadAndCheck(from item: PhotosPickerItem) async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw CookCheckError.unreadablePhoto
            }
            let jpeg = try compressPhotoForUpload(image)
            let result = try await appState.cookCheck(
                recipeID: context.recipeID,
                stepNumber: context.stepNumber,
                imageData: jpeg
            )
            self.result = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

private enum CookCheckError: LocalizedError {
    case unreadablePhoto

    var errorDescription: String? {
        switch self {
        case .unreadablePhoto: return "The selected photo could not be read."
        }
    }
}
