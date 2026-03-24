import SwiftUI

struct FeedbackComposerView: View {
    let title: String
    let onSubmit: (_ sentiment: Int, _ notes: String) async throws -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sentiment = 1
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sentiment") {
                    Picker("Sentiment", selection: $sentiment) {
                        Text("Avoid").tag(-2)
                        Text("Bad").tag(-1)
                        Text("Neutral").tag(0)
                        Text("Good").tag(1)
                        Text("Great").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Notes") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 140)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await submit() }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }

        do {
            try await onSubmit(sentiment, notes.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
