import SimmerSmithKit
import SwiftUI

/// AI-powered recipe finder. The user types a freeform query (e.g.,
/// "best whole wheat waffle recipe"), the backend searches the web with
/// citations and returns a draft. We preview the draft inline; the user
/// taps "Open in editor" to land in `RecipeEditorView` and decide
/// whether to save — same flow URL imports use.
struct RecipeWebSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onDraftReady: (RecipeDraft) -> Void

    @State private var query: String = ""
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var draft: RecipeDraft?

    var body: some View {
        NavigationStack {
            Form {
                if let draft {
                    previewSection(draft)
                    actionSection(draft)
                } else {
                    inputSection
                    examplesSection
                }

                if isSearching {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching the web…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Find recipe online")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                if draft != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("New search") { reset() }
                            .foregroundStyle(SMColor.ember)
                    }
                }
            }
            .smithToolbar()
        }
    }

    @ViewBuilder
    private var inputSection: some View {
        Section("What are you looking for?") {
            TextField(
                "best whole wheat waffle recipe",
                text: $query,
                axis: .vertical
            )
            .lineLimit(2...4)
            .autocorrectionDisabled()

            Button {
                Task { await search() }
            } label: {
                Label(
                    isSearching ? "Searching…" : "Search the web",
                    systemImage: "globe"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || isSearching)
        }
    }

    @ViewBuilder
    private var examplesSection: some View {
        Section("Try") {
            Text("the best New York pizza dough")
            Text("a one-pan weeknight chicken thigh recipe")
            Text("a beginner-friendly chocolate chip cookie")
        }
        .font(SMFont.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func previewSection(_ draft: RecipeDraft) -> some View {
        Section {
            VStack(alignment: .leading, spacing: SMSpacing.xs) {
                Text(draft.name).font(.title3.bold())
                if !draft.sourceLabel.isEmpty {
                    Text(draft.sourceLabel)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.primary)
                }
                if !draft.notes.isEmpty {
                    Text(draft.notes)
                        .font(SMFont.body)
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        }
        Section("Quick facts") {
            HStack {
                Text("Ingredients")
                Spacer()
                Text("\(draft.ingredients.count)").monospacedDigit()
            }
            HStack {
                Text("Steps")
                Spacer()
                Text("\(draft.steps.count)").monospacedDigit()
            }
            if let servings = draft.servings {
                HStack {
                    Text("Servings")
                    Spacer()
                    Text("\(Int(servings))").monospacedDigit()
                }
            }
            if !draft.cuisine.isEmpty {
                HStack {
                    Text("Cuisine")
                    Spacer()
                    Text(draft.cuisine.capitalized)
                        .foregroundStyle(.secondary)
                }
            }
        }
        if !draft.sourceUrl.isEmpty, let url = URL(string: draft.sourceUrl) {
            Section("Source") {
                Link(destination: url) {
                    Text(draft.sourceUrl)
                        .font(SMFont.caption)
                        .lineLimit(2)
                        .foregroundStyle(SMColor.primary)
                }
            }
        }
    }

    @ViewBuilder
    private func actionSection(_ draft: RecipeDraft) -> some View {
        Section {
            Button {
                onDraftReady(draft)
                dismiss()
            } label: {
                Label("Open in editor", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func reset() {
        draft = nil
        errorMessage = nil
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let result = try await appState.searchRecipeOnWeb(query: trimmed)
            self.draft = result
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
