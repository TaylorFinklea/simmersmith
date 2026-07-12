import SwiftUI
import SimmerSmithKit

/// Search-and-link sheet — surfaces base ingredients from the catalog
/// so the user can attach a free-typed grocery row (e.g. "almond
/// flour") to a canonical entry. Saving PATCHes the grocery item with
/// the chosen canonical identity; CloudKit stores the link as locked
/// so smart-merge regeneration can match it consistently.
///
/// Triggered from:
/// - Review queue's "Link to Ingredient" button
/// - GroceryFeedbackSheet "Link to Ingredient" row when no base set
struct IngredientLinkPickerSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: GroceryItem
    /// Optional callback fired with the updated item after a successful
    /// link so the caller can refresh its own state (e.g. the review
    /// queue list).
    var onLinked: ((GroceryItem) -> Void)?

    @State private var query: String = ""
    @State private var results: [BaseIngredient] = []
    @State private var isSearching = false
    @State private var savingID: String?
    @State private var errorMessage: String?
    @State private var isCreatingNew = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Always seed the search with the item's name so the
                // first hit is usually exactly what the user wants.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search canonical ingredients", text: $query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 10)

                Divider()

                if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    VStack(spacing: SMSpacing.lg) {
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "magnifyingglass",
                            description: Text("Add it as a new ingredient for your household.")
                        )
                        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Button {
                                Task { await createNew(named: trimmed) }
                            } label: {
                                Label(
                                    isCreatingNew ? "Adding…" : "Add \"\(trimmed)\" as new ingredient",
                                    systemImage: "plus.circle.fill"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(SMColor.primary)
                            .disabled(isCreatingNew)
                            .padding(.horizontal, SMSpacing.lg)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(results) { base in
                            Button {
                                Task { await link(to: base) }
                            } label: {
                                row(for: base)
                            }
                            .buttonStyle(.plain)
                            .disabled(savingID != nil)
                        }
                        // Always offer to add new even when partial
                        // matches exist — the user might want a more
                        // specific entry.
                        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            Section {
                                Button {
                                    Task { await createNew(named: trimmed) }
                                } label: {
                                    Label(
                                        "Add \"\(trimmed)\" as new ingredient",
                                        systemImage: "plus.circle"
                                    )
                                }
                                .disabled(isCreatingNew)
                            } footer: {
                                Text("Saved privately to your household.")
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Link Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
            .task {
                if query.isEmpty {
                    query = item.ingredientName
                    await search()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for base: BaseIngredient) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(base.name)
                    .font(.body)
                if !base.category.isEmpty {
                    Text(base.category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if savingID == base.baseIngredientId {
                ProgressView()
            } else {
                Image(systemName: "link")
                    .foregroundStyle(SMColor.primary)
            }
        }
        .padding(.vertical, 4)
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = true
        defer { isSearching = false }
        errorMessage = nil
        do {
            // SP-C: routed through AppState façade (closes the direct apiClient leak).
            results = try await appState.fetchBaseIngredients(query: trimmed, limit: 25)
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            results = []
        }
    }

    private func createNew(named trimmed: String) async {
        isCreatingNew = true
        defer { isCreatingNew = false }
        errorMessage = nil
        do {
            let created = try await appState.createBaseIngredient(name: trimmed)
            await link(to: created)
        } catch {
            errorMessage = "Couldn't add ingredient: \(error.localizedDescription)"
        }
    }

    private func link(to base: BaseIngredient) async {
        savingID = base.baseIngredientId
        defer { savingID = nil }
        errorMessage = nil
        do {
            let updated = try await appState.linkGroceryItemToIngredient(
                itemID: item.groceryItemId,
                baseIngredientID: base.baseIngredientId,
                canonicalName: base.name
            )
            onLinked?(updated)
            dismiss()
        } catch {
            errorMessage = "Couldn't link: \(error.localizedDescription)"
        }
    }
}
