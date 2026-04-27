import SimmerSmithKit
import SwiftUI

/// Compose sheet for adding a memory to the recipe log. Phase 1
/// ships text-only; Phase 2 will add a `PhotosPicker` row and
/// upload the bytes alongside the body.
struct MemoryComposeSheet: View {
    let recipeID: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var bodyText: String = ""
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
                    .submitLabel(.return)
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
        }
    }

    private var isSaveDisabled: Bool {
        isSaving || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await appState.createRecipeMemory(recipeID: recipeID, body: trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
