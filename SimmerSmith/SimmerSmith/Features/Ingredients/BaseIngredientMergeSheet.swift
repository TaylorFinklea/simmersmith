import SwiftUI
import SimmerSmithKit

struct BaseIngredientMergeSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let baseIngredientID: String
    let onMerged: () -> Void

    @State private var searchText = ""
    @State private var candidates: [BaseIngredient] = []
    @State private var selectedTargetID: String?
    @State private var isLoading = false
    @State private var isMerging = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                searchSection

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                mergeTargetsSection
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Merge Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMerging ? "Merging…" : "Merge") {
                        Task { await merge() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(isMerging || selectedTargetID == nil)
                }
            }
            .smithToolbar()
            .task {
                if candidates.isEmpty {
                    await loadCandidates()
                }
            }
        }
    }

    private var filteredCandidates: [BaseIngredient] {
        candidates.filter { $0.baseIngredientId != baseIngredientID }
    }

    private var searchSection: some View {
        Section {
            TextField("Search merge target", text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit {
                    Task { await loadCandidates() }
                }

            Button {
                Task { await loadCandidates() }
            } label: {
                HStack {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Search Catalog")
                }
            }
        }
    }

    private var mergeTargetsSection: some View {
        Section("Merge Into") {
            ForEach(filteredCandidates) { ingredient in
                mergeCandidateRow(ingredient)
            }
        }
    }

    private func mergeCandidateRow(_ ingredient: BaseIngredient) -> some View {
        Button {
            selectedTargetID = ingredient.baseIngredientId
        } label: {
            HStack {
                IngredientCatalogRow(ingredient: ingredient)
                Spacer()
                if selectedTargetID == ingredient.baseIngredientId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func loadCandidates() async {
        do {
            isLoading = true
            errorMessage = nil
            candidates = try await appState.searchBaseIngredients(
                query: searchText,
                limit: 100,
                includeArchived: false,
                includeProductLike: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func merge() async {
        guard let selectedTargetID else { return }
        do {
            isMerging = true
            errorMessage = nil
            _ = try await appState.mergeBaseIngredient(sourceID: baseIngredientID, targetID: selectedTargetID)
            onMerged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isMerging = false
    }
}
