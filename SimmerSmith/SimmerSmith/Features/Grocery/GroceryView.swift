import SwiftUI
import SimmerSmithKit

struct GroceryView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedItem: GroceryItem?
    @State private var showingReviewQueue = false

    var body: some View {
        Group {
            if let week = appState.currentWeek, !week.groceryItems.isEmpty {
                List {
                    ForEach(groupedItems(for: week), id: \.category) { section in
                        Section(section.category) {
                            ForEach(section.items) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    Button {
                                        appState.toggleGroceryChecked(item.groceryItemId)
                                    } label: {
                                        Image(systemName: appState.isGroceryChecked(item.groceryItemId) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(appState.isGroceryChecked(item.groceryItemId) ? .green : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        appState.isGroceryChecked(item.groceryItemId)
                                            ? "\(item.ingredientName), checked. Tap to uncheck."
                                            : "\(item.ingredientName), unchecked. Tap to check off."
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.ingredientName)
                                            .font(.body.weight(.medium))
                                            .strikethrough(appState.isGroceryChecked(item.groceryItemId))
                                        Text(item.quantityText.isEmpty ? item.unit : item.quantityText)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                        if !item.sourceMeals.isEmpty {
                                            Text(item.sourceMeals)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if !item.reviewFlag.isEmpty {
                                            Label(item.reviewFlag, systemImage: "exclamationmark.circle")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .swipeActions {
                                    Button("Feedback", systemImage: "bubble.left") {
                                        selectedItem = item
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await appState.refreshWeek()
                }
            } else {
                ContentUnavailableView(
                    "No Grocery List",
                    systemImage: "cart.badge.questionmark",
                    description: Text("Sync a current week that includes grocery items.")
                )
            }
        }
        .navigationTitle("Grocery")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BrandToolbarBadge()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await appState.refreshWeek() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh grocery list")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingReviewQueue = true
                } label: {
                    Image(systemName: groceryReviewCount == 0 ? "list.bullet.clipboard" : "exclamationmark.circle")
                }
                .accessibilityLabel(
                    groceryReviewCount == 0
                        ? "Ingredient review queue"
                        : "Ingredient review queue, \(groceryReviewCount) items need review"
                )
            }
        }
        .sheet(item: $selectedItem) { item in
            FeedbackComposerView(title: item.ingredientName) { sentiment, notes in
                try await appState.submitGroceryFeedback(for: item, sentiment: sentiment, notes: notes)
            }
        }
        .sheet(isPresented: $showingReviewQueue) {
            IngredientReviewQueueView()
        }
    }

    private func groupedItems(for week: WeekSnapshot) -> [(category: String, items: [GroceryItem])] {
        let grouped = Dictionary(grouping: week.groceryItems) { item in
            item.category.isEmpty ? "Unsorted" : item.category
        }
        return grouped
            .map { key, value in (key, value.sorted { $0.ingredientName.localizedCaseInsensitiveCompare($1.ingredientName) == .orderedAscending }) }
            .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }

    private var groceryReviewCount: Int {
        (appState.currentWeek?.groceryItems ?? []).filter { item in
            !item.reviewFlag.isEmpty || item.resolutionStatus == "unresolved" || item.resolutionStatus == "suggested"
        }.count
    }
}
