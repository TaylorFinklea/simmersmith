import SwiftUI
import SimmerSmithKit

struct RecipeImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onImported: (RecipeDraft) -> Void

    @State private var url = ""
    @State private var isImporting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipe URL") {
                    TextField("https://example.com/recipe", text: $url)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }

                Section {
                    Button {
                        Task { await runImport() }
                    } label: {
                        Text(isImporting ? "Importing…" : "Import Recipe")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isImporting)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import URL")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func runImport() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let draft = try await appState.importRecipeDraft(fromURL: url.trimmingCharacters(in: .whitespacesAndNewlines))
            onImported(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
