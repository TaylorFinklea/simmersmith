import SwiftUI
import SimmerSmithKit

/// Build 87 — Savanne/Taylor dogfood: surfaces "what's needed but
/// not yet on the grocery list" so the user can quickly add only the
/// items they actually want to buy.
///
/// Replaces the old auto-populate behavior that filled the list with
/// every ingredient from every meal — leading to a list full of items
/// already in the fridge that the user had to manually clean up.
///
/// Flow:
///   1. Sheet opens, fetches `GET /api/weeks/{id}/grocery/plan-shopping`.
///   2. Each row is one needed ingredient. Tap the row → quick-adds it
///      to the grocery list (no store yet), the row disappears from
///      the "Needed" section and appears in "Just added" below.
///   3. In "Just added" each row has a store chip — tap to assign a
///      store from the household's known options (Kroger/Aldi/Walmart
///      + previously-used labels) or leave it blank.
///   4. Dismiss when done. Items are persisted server-side, and the
///      Reminders sync (if enabled) carries the store label into the
///      EKReminder notes.
struct PlanShoppingSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isLoading = false
    @State private var loadError: String?
    @State private var planItems: [PlanShoppingItem] = []
    @State private var justAddedIDs: [String] = []

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Plan Shopping")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && planItems.isEmpty && justAddedIDs.isEmpty {
            ProgressView("Looking at this week’s meals…")
                .progressViewStyle(.circular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paperBackground()
        } else if let err = loadError {
            VStack(spacing: SMSpacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(SMColor.destructive)
                Text(err)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SMSpacing.lg)
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                    .tint(SMColor.ember)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperBackground()
        } else {
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        List {
            Section {
                FuHero(
                    eyebrow: heroEyebrow,
                    title: "plan ",
                    emberAccent: "shopping"
                )
                .padding(.horizontal, -SMSpacing.lg)
                .padding(.vertical, SMSpacing.sm)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if planItems.isEmpty {
                Section {
                    HStack(spacing: SMSpacing.md) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(SMColor.success)
                        Text("Nothing else needed this week — your meals are covered by the grocery list and pantry.")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                }
            } else {
                ForEach(groupedPlan, id: \.category) { section in
                    Section(section.category.isEmpty ? "Other" : section.category) {
                        ForEach(section.items) { planItem in
                            planRow(planItem)
                        }
                    }
                }
            }

            if !justAddedIDs.isEmpty {
                Section("Just Added") {
                    ForEach(justAddedItems) { item in
                        justAddedRow(item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .paperBackground()
        .refreshable { await load() }
    }

    // MARK: - Row builders

    @ViewBuilder
    private func planRow(_ planItem: PlanShoppingItem) -> some View {
        Button {
            Task { await add(planItem) }
        } label: {
            HStack(alignment: .top, spacing: SMSpacing.md) {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(SMColor.ember)
                VStack(alignment: .leading, spacing: 4) {
                    Text(planItem.ingredientName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(SMColor.textPrimary)
                    if !planItem.displayQuantity.isEmpty {
                        Text(planItem.displayQuantity)
                            .font(.footnote)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                    if !planItem.sourceMeals.isEmpty {
                        Text(planItem.sourceMeals)
                            .font(.caption)
                            .foregroundStyle(SMColor.textTertiary)
                            .lineLimit(2)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Build 88 — Taylor: same swipe affordance as the grocery row
        // so adding "I already have this" to pantry is one gesture.
        // The pantry row stays in the plan list (the user can still
        // tap to add to grocery if they want both); a second affordance
        // shows below.
        .swipeActions(edge: .leading) {
            Button("To Pantry", systemImage: "archivebox") {
                Task {
                    await appState.quickAddIngredientToPantry(
                        name: planItem.ingredientName,
                        category: planItem.category,
                        unit: planItem.unit,
                        normalizedNameHint: planItem.normalizedName
                    )
                    withAnimation(.easeInOut(duration: 0.2)) {
                        planItems.removeAll { $0.id == planItem.id }
                    }
                }
            }
            .tint(SMColor.ember)
        }
    }

    @ViewBuilder
    private func justAddedRow(_ item: GroceryItem) -> some View {
        HStack(alignment: .top, spacing: SMSpacing.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(SMColor.success)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.ingredientName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(SMColor.textPrimary)
                StoreChip(item: item)
            }
            Spacer()
        }
    }

    // MARK: - Data

    private var heroEyebrow: String {
        if planItems.isEmpty && justAddedIDs.isEmpty {
            return "this week"
        }
        let remaining = planItems.count
        return remaining == 1 ? "1 still needed" : "\(remaining) still needed"
    }

    /// Items grouped by `category`, sorted alphabetically (with empty
    /// categories bucketed to "Other" at the end).
    private var groupedPlan: [(category: String, items: [PlanShoppingItem])] {
        let groups = Dictionary(grouping: planItems, by: { $0.category })
        return groups
            .map { (category: $0.key, items: $0.value.sorted { $0.ingredientName < $1.ingredientName }) }
            .sorted { lhs, rhs in
                if lhs.category.isEmpty && !rhs.category.isEmpty { return false }
                if !lhs.category.isEmpty && rhs.category.isEmpty { return true }
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            }
    }

    private var justAddedItems: [GroceryItem] {
        let map = Dictionary(uniqueKeysWithValues: (appState.currentWeek?.groceryItems ?? []).map { ($0.groceryItemId, $0) })
        return justAddedIDs.compactMap { map[$0] }
    }

    private func load() async {
        guard let weekID = appState.currentWeek?.weekId else {
            loadError = "No current week to plan against."
            return
        }
        isLoading = true
        loadError = nil
        do {
            let response = try await appState.loadPlanShopping(weekID: weekID)
            planItems = response.items
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func add(_ planItem: PlanShoppingItem) async {
        guard let added = await appState.quickAddPlanItem(planItem) else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            planItems.removeAll { $0.id == planItem.id }
            justAddedIDs.append(added.groceryItemId)
        }
    }
}

// MARK: - PlanShoppingItem display helper

private extension PlanShoppingItem {
    /// "2 lb", "1 head", "to taste" — same logic as
    /// `GroceryView.displayQuantity` but operating on the projection
    /// row's pre-aggregated fields.
    var displayQuantity: String {
        if let qty = totalQuantity, qty > 0 {
            let formatted: String
            if qty == qty.rounded() {
                formatted = String(Int(qty))
            } else {
                formatted = String(format: "%g", qty)
            }
            return unit.isEmpty ? formatted : "\(formatted) \(unit)"
        }
        if !quantityText.isEmpty { return quantityText }
        return unit
    }
}
