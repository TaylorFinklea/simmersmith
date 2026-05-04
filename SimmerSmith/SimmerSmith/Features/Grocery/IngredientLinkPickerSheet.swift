import SwiftUI
import SimmerSmithKit

/// Search-and-link sheet — surfaces base ingredients from the catalog
/// so the user can attach a free-typed grocery row (e.g. "almond
/// flour") to a canonical entry. Saving PATCHes the grocery item with
/// the chosen `base_ingredient_id`; the server flips
/// `resolution_status` to "locked" and clears the review_flag so
/// smart-merge regen can match it consistently.
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
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try a shorter or simpler search. If the canonical ingredient doesn't exist yet, add it under Settings → Ingredients first.")
                    )
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
            .navigationTitle("Link Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
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
            results = try await appState.apiClient.fetchBaseIngredients(
                query: trimmed,
                limit: 25,
                includeProductLike: true
            )
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            results = []
        }
    }

    private func link(to base: BaseIngredient) async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        savingID = base.baseIngredientId
        defer { savingID = nil }
        errorMessage = nil
        var body = SimmerSmithAPIClient.GroceryItemPatchBody()
        body.baseIngredientId = .set(base.baseIngredientId)
        do {
            let updated = try await appState.apiClient.patchGroceryItem(
                weekID: weekID,
                itemID: item.groceryItemId,
                body: body
            )
            appState.replaceGroceryItemInCurrentWeek(updated)
            await appState.syncGroceryToReminders()
            onLinked?(updated)
            dismiss()
        } catch {
            errorMessage = "Couldn't link: \(error.localizedDescription)"
        }
    }
}
