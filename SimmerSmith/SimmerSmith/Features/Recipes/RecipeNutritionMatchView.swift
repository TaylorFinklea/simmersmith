import SwiftUI
import SimmerSmithKit

struct RecipeNutritionMatchContext: Identifiable, Equatable {
    let id = UUID()
    let ingredientName: String
    let normalizedName: String?
}

struct RecipeNutritionMatchView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: RecipeNutritionMatchContext
    let onMatched: () -> Void

    @State private var searchText = ""
    @State private var items: [NutritionItem] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.ingredientName)
                            .font(.headline)
                        Text("Choose the best nutrition match for this ingredient.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                if items.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "No Nutrition Matches",
                        systemImage: "fork.knife.circle",
                        description: Text("Try a different search term.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(items) { item in
                        Button {
                            Task { await saveMatch(item) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .foregroundStyle(.primary)
                                Text(summary(for: item))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Match Nutrition")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search foods")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadItems()
            }
            .task(id: searchText) {
                try? await Task.sleep(for: .milliseconds(250))
                await loadItems()
            }
        }
    }

    private func loadItems() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await appState.searchNutritionItems(query: searchText, limit: 30)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveMatch(_ item: NutritionItem) async {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await appState.saveIngredientNutritionMatch(
                ingredientName: context.ingredientName,
                normalizedName: context.normalizedName,
                nutritionItemID: item.itemId
            )
            onMatched()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func summary(for item: NutritionItem) -> String {
        let calories = Int(item.calories.rounded())
        let amount = item.referenceAmount == floor(item.referenceAmount)
            ? String(Int(item.referenceAmount))
            : item.referenceAmount.formatted()
        return "\(calories) cal per \(amount) \(item.referenceUnit)"
    }
}
