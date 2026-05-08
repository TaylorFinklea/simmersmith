import SwiftUI
import SimmerSmithKit

struct GroceryView: View {
    @Environment(AppState.self) private var appState
    @Environment(AIAssistantCoordinator.self) private var aiCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var selectedItem: GroceryItem?
    @State private var editingItem: GroceryItem?
    @State private var showingReviewQueue = false
    @State private var showingAddSheet = false
    @State private var isFetchingPrices = false
    @State private var showingBarcodeScanner = false
    @State private var isRegenerating = false
    @State private var showingArchive = false

    /// True when this view is presented as a sheet from the Week tab —
    /// shows a Done button to dismiss. False when used as the Grocery
    /// tab root, where the tab bar handles navigation.
    var dismissable: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content

            // Build 70 — configurable FAB. Default = ➕ Add item.
            // Sparkle / Refresh / Regenerate / Review available
            // via Settings → Top bar → Grocery.
            TabPrimaryFAB(page: .grocery, contextHint: "from Grocery", actions: [
                .add: { showingAddSheet = true },
                .refresh: { Task { await appState.refreshWeek() } },
                .regenerate: { Task { await regenerate() } },
                .review: { showingReviewQueue = true }
            ])
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if let week = appState.currentWeek, !week.groceryItems.isEmpty {
                List {
                    Section {
                        FuHero(
                            eyebrow: groceryHeroEyebrow(week: week),
                            title: "the ",
                            emberAccent: "haul"
                        )
                        .padding(.horizontal, -SMSpacing.lg)
                        .padding(.vertical, SMSpacing.sm)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }

                    Section {
                        if weekTotal > 0 {
                            HStack {
                                Label("Estimated Total", systemImage: "dollarsign.circle")
                                    .font(SMFont.subheadline)
                                    .foregroundStyle(SMColor.textPrimary)
                                Spacer()
                                Text(String(format: "$%.2f", weekTotal))
                                    .font(SMFont.headline)
                                    .foregroundStyle(SMColor.ember)
                            }
                        }

                        fetchPricesRow(week: week)
                    }

                    ForEach(groupedItems(for: week), id: \.category) { section in
                        Section(section.category) {
                            ForEach(section.items) { item in
                                HStack(alignment: .top, spacing: 12) {
                                    Button {
                                        Task { await appState.toggleGroceryChecked(item.groceryItemId) }
                                    } label: {
                                        Image(systemName: appState.isGroceryChecked(item.groceryItemId) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(appState.isGroceryChecked(item.groceryItemId) ? SMColor.success : SMColor.textTertiary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        appState.isGroceryChecked(item.groceryItemId)
                                            ? "\(item.ingredientName), checked. Tap to uncheck."
                                            : "\(item.ingredientName), unchecked. Tap to check off."
                                    )

                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            Text(item.ingredientName)
                                                .font(.body.weight(.medium))
                                                .foregroundStyle(SMColor.textPrimary)
                                                .strikethrough(appState.isGroceryChecked(item.groceryItemId))
                                            if item.isUserAdded {
                                                Image(systemName: "person.crop.circle.badge.plus")
                                                    .font(.caption2)
                                                    .foregroundStyle(SMColor.textTertiary)
                                                    .accessibilityLabel("Added by you")
                                            }
                                            if item.quantityOverride != nil || item.unitOverride != nil || item.notesOverride != nil {
                                                Image(systemName: "pencil.circle")
                                                    .font(.caption2)
                                                    .foregroundStyle(SMColor.textTertiary)
                                                    .accessibilityLabel("Edited")
                                            }
                                        }
                                        Text(displayQuantity(for: item))
                                            .font(.footnote)
                                            .foregroundStyle(SMColor.textSecondary)
                                        if !item.sourceMeals.isEmpty {
                                            Text(item.sourceMeals)
                                                .font(.caption)
                                                .foregroundStyle(SMColor.textTertiary)
                                        }
                                        if !item.reviewFlag.isEmpty {
                                            Label(item.reviewFlag, systemImage: "exclamationmark.circle")
                                                .font(.caption)
                                                .foregroundStyle(.orange)
                                        }
                                        if let price = bestPrice(for: item) {
                                            HStack(spacing: 4) {
                                                Text(price.productName.isEmpty ? price.retailer.capitalized : price.productName)
                                                    .lineLimit(1)
                                                if let linePrice = price.linePrice {
                                                    Text(String(format: "$%.2f", linePrice))
                                                        .foregroundStyle(SMColor.primary)
                                                }
                                                if !price.packageSize.isEmpty {
                                                    Text("(\(price.packageSize))")
                                                        .foregroundStyle(SMColor.textTertiary)
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(SMColor.textSecondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { editingItem = item }
                                .swipeActions(edge: .trailing) {
                                    Button("Remove", systemImage: "trash", role: .destructive) {
                                        Task { await appState.removeGroceryItem(id: item.groceryItemId) }
                                    }
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
                .scrollContentBackground(.hidden)
                .paperBackground()
                .refreshable {
                    await appState.refreshWeek()
                }
            } else {
                emptyState
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            aiCoordinator.updateContext(
                AIPageContext(
                    pageType: "grocery",
                    pageLabel: "Grocery list",
                    weekId: appState.currentWeek?.weekId,
                    groceryItemCount: appState.currentWeek?.groceryItems.count,
                    briefSummary: "Grocery list for the current week."
                )
            )
        }
        // Build 68 — overhauled top bar. Trailing visible items
        // collapse to: [optional Done] [overflow ⋯ menu] [primary]
        // [✨ sparkle]. Refresh / regenerate / dedupe / review queue /
        // barcode scan / pantry shortcut all push into the ⋯ menu.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Grocery")
                    .font(SMFont.headline)
                    .foregroundStyle(SMColor.textPrimary)
            }
            if dismissable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                groceryOverflowMenu
            }
            // Build 71 — dedupe: hide whichever item matches the
            // user's selected FAB action.
            if groceryPrimary != .add {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(SMColor.ember)
                    }
                    .accessibilityLabel("Add item")
                }
            }
            if groceryPrimary != .sparkle {
                ToolbarItem(placement: .topBarTrailing) {
                    TopBarSparkleButton(contextHint: "from Grocery")
                }
            }
        }
        .smithToolbar()
        .sheet(item: $selectedItem) { item in
            GroceryFeedbackSheet(item: item)
                .environment(appState)
        }
        .sheet(item: $editingItem) { item in
            GroceryItemEditSheet(item: item)
                .environment(appState)
        }
        .sheet(isPresented: $showingAddSheet) {
            AddGroceryItemSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showingArchive) {
            GroceryArchiveSheet()
                .environment(appState)
        }
        .sheet(isPresented: $showingReviewQueue) {
            IngredientReviewQueueView()
        }
        .sheet(isPresented: $showingBarcodeScanner) {
            BarcodeLookupSheet()
        }
    }

    /// Build 71 — used to hide the matching top-bar button when
    /// the user has selected that action as the FAB.
    private var groceryPrimary: TopBarPrimaryAction {
        _ = appState.topBarConfigRevision
        return appState.topBarPrimary(for: .grocery)
    }

    /// Build 68 — secondary actions collapse into a single ⋯ menu.
    /// Mirrors the previous toolbar layout's full set so nothing is
    /// lost; the visible top bar just isn't 5+ icons wide anymore.
    private var groceryOverflowMenu: some View {
        Menu {
            Button {
                Task { await appState.refreshWeek() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                Task { await regenerate() }
            } label: {
                Label("Regenerate from meals", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                Task { await dedupe() }
            } label: {
                Label("Dedupe duplicates", systemImage: "rectangle.stack.badge.minus")
            }
            Button {
                showingReviewQueue = true
            } label: {
                if groceryReviewCount == 0 {
                    Label("Review queue", systemImage: "list.bullet.clipboard")
                } else {
                    Label("Review queue (\(groceryReviewCount))", systemImage: "exclamationmark.circle")
                }
            }
            if !krogerLocationId.isEmpty {
                Button {
                    showingBarcodeScanner = true
                } label: {
                    Label("Scan barcode", systemImage: "barcode.viewfinder")
                }
            }
            Divider()
            Button {
                showingArchive = true
            } label: {
                Label("Show removed items", systemImage: "tray")
            }
            NavigationLink {
                PantryView()
            } label: {
                Label("Pantry", systemImage: "shippingbox")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(SMColor.ember)
        }
        .accessibilityLabel("More grocery actions")
    }

    private var mealCount: Int { appState.currentWeek?.meals.count ?? 0 }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: SMSpacing.lg) {
            Image(systemName: "cart.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(SMColor.textTertiary)
            Text("No Grocery List")
                .font(SMFont.headline)
                .foregroundStyle(SMColor.textPrimary)
            Text(emptyHelperText)
                .font(SMFont.body)
                .foregroundStyle(SMColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, SMSpacing.lg)

            VStack(spacing: SMSpacing.sm) {
                if appState.currentWeek != nil && mealCount > 0 {
                    Button {
                        Task { await regenerate() }
                    } label: {
                        Label(
                            isRegenerating ? "Regenerating…" : "Regenerate from this week's meals",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SMColor.primary)
                    .disabled(isRegenerating)
                }
                Button {
                    showingAddSheet = true
                } label: {
                    Label("Add an item manually", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, SMSpacing.xl)
            .padding(.top, SMSpacing.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SMColor.surface)
        .refreshable { await appState.refreshWeek() }
    }

    private var emptyHelperText: String {
        if appState.currentWeek == nil {
            return "Pull to refresh once your week loads."
        }
        if mealCount == 0 {
            return "No meals planned yet. Add some on the Week tab — the grocery list builds from your meals automatically."
        }
        return "You have \(mealCount) meal\(mealCount == 1 ? "" : "s") this week, but no ingredients have aggregated yet. Tap Regenerate to build the list."
    }

    private func regenerate() async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        do {
            _ = try await appState.regenerateGrocery(weekID: weekID)
            await appState.refreshWeek()
            await appState.syncGroceryToReminders()
        } catch {
            appState.lastErrorMessage = "Regenerate failed: \(error.localizedDescription)"
        }
    }

    private func dedupe() async {
        guard let weekID = appState.currentWeek?.weekId else { return }
        do {
            _ = try await appState.apiClient.dedupeGrocery(weekID: weekID)
            await appState.refreshWeek()
            await appState.syncGroceryToReminders()
        } catch {
            appState.lastErrorMessage = "Dedupe failed: \(error.localizedDescription)"
        }
    }

    private func groceryHeroEyebrow(week: WeekSnapshot) -> String {
        let items = week.groceryItems.count
        let unchecked = week.groceryItems.filter { !appState.isGroceryChecked($0.groceryItemId) }.count
        if unchecked == 0 {
            return "all picked up · \(items) items"
        }
        return "\(unchecked) of \(items) left"
    }

    private func displayQuantity(for item: GroceryItem) -> String {
        let qty = item.effectiveQuantity
        let unit = item.effectiveUnit
        if let qty {
            let qtyString: String = qty.rounded() == qty
                ? String(Int(qty))
                : String(format: "%g", qty)
            return unit.isEmpty ? qtyString : "\(qtyString) \(unit)"
        }
        if !item.quantityText.isEmpty { return item.quantityText }
        return unit
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

    private func bestPrice(for item: GroceryItem) -> RetailerPrice? {
        item.retailerPrices.first(where: { $0.status == "matched" && $0.linePrice != nil })
    }

    private var weekTotal: Double {
        (appState.currentWeek?.groceryItems ?? []).compactMap { item in
            bestPrice(for: item)?.linePrice
        }.reduce(0, +)
    }

    private var krogerLocationId: String {
        appState.profile?.settings["kroger_location_id"] ?? ""
    }

    private var krogerStoreName: String {
        appState.profile?.settings["kroger_store_name"] ?? ""
    }

    @ViewBuilder
    private func fetchPricesRow(week: WeekSnapshot) -> some View {
        if krogerLocationId.isEmpty {
            HStack(alignment: .top, spacing: SMSpacing.sm) {
                Image(systemName: "storefront")
                    .foregroundStyle(SMColor.textTertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Select a Kroger store")
                        .font(SMFont.subheadline)
                        .foregroundStyle(SMColor.textPrimary)
                    Text("Settings → Grocery to pick a store, then fetch prices here.")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textSecondary)
                }
            }
        } else {
            Button {
                Task { await fetchPrices(weekID: week.weekId) }
            } label: {
                HStack(spacing: SMSpacing.sm) {
                    if isFetchingPrices {
                        ProgressView().controlSize(.small)
                        Text("Fetching Kroger prices…")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(weekTotal > 0 ? "Refresh Kroger prices" : "Fetch Kroger prices")
                                .font(SMFont.subheadline)
                            if !krogerStoreName.isEmpty {
                                Text(krogerStoreName)
                                    .font(SMFont.caption)
                                    .foregroundStyle(SMColor.textTertiary)
                            }
                        }
                    }
                    Spacer()
                }
                .foregroundStyle(SMColor.primary)
            }
            .disabled(isFetchingPrices)
            .accessibilityLabel(weekTotal > 0 ? "Refresh Kroger prices" : "Fetch Kroger prices")
        }
    }

    private func fetchPrices(weekID: String) async {
        guard !isFetchingPrices else { return }
        isFetchingPrices = true
        defer { isFetchingPrices = false }
        do {
            _ = try await appState.apiClient.fetchPricing(weekID: weekID, locationID: krogerLocationId)
            await appState.refreshWeek()
        } catch SimmerSmithAPIError.usageLimitReached(let action, let limit, let used, _) {
            appState.presentPaywall(.limitReached(action: action, used: used, limit: limit))
        } catch {
            appState.lastErrorMessage = "Fetch prices failed: \(error.localizedDescription)"
        }
    }
}
