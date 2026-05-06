import SwiftUI
import SimmerSmithKit

/// M28 — pantry item editor. Add a new item or edit an existing one.
///
/// Cadence picker drives the recurring auto-add. `none` makes the row
/// a pure staple (filtered from grocery, never auto-added). The other
/// options auto-add to weekly grocery on the chosen rhythm.
///
/// M29 build 56:
/// - Name field surfaces ingredient suggestions from the household
///   `BaseIngredient` catalog as the user types. Tapping a suggestion
///   prefills the name + (when present) auto-selects the catalog
///   row's category.
/// - Category is now a multi-select chip row with a default grocery-
///   section list, plus any custom values the household already used.
struct PantryItemEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let item: PantryItem?

    @State private var name: String = ""
    @State private var selectedCategories: Set<String> = []
    @State private var customCategoryDraft: String = ""
    @State private var notes: String = ""
    @State private var isActive: Bool = true
    @State private var typicalQuantityText: String = ""
    @State private var typicalUnit: String = ""
    @State private var recurringCadence: String = "none"
    @State private var recurringQuantityText: String = ""
    @State private var recurringUnit: String = ""
    /// Build 57 — freezer kind. When `isFreezerItem` is true, the
    /// item is a freezer entry and we send `frozenAt` to the server.
    @State private var isFreezerItem: Bool = false
    @State private var frozenAt: Date = Date()
    @State private var isSaving = false
    @State private var errorMessage: String? = nil

    // Ingredient autocomplete state.
    @State private var nameSuggestions: [BaseIngredient] = []
    @State private var isSearchingIngredients = false
    @State private var lastSearchedQuery: String = ""
    @State private var searchTask: Task<Void, Never>? = nil

    private let cadenceOptions: [(value: String, label: String)] = [
        ("none", "Don't auto-add"),
        ("weekly", "Weekly"),
        ("biweekly", "Every 2 weeks"),
        ("monthly", "Monthly"),
    ]

    /// Default grocery sections — shown as chips even when the
    /// household hasn't used them yet so the user has a fast lane.
    private static let defaultCategories: [String] = [
        "Produce", "Dairy", "Meat", "Seafood",
        "Pantry", "Freezer", "Beverages",
        "Condiments", "Baking", "Snacks", "Spices",
    ]

    /// Defaults + any categories already in use across the household
    /// (existing pantry rows). Lowercased dedupe so "dairy" and
    /// "Dairy" don't both show.
    private var availableCategories: [String] {
        var seen: [String: String] = [:]
        for raw in Self.defaultCategories + appState.pantryItems.flatMap(\.displayCategories) + Array(selectedCategories) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen[key] == nil {
                seen[key] = trimmed
            }
        }
        return seen.values.sorted { $0.lowercased() < $1.lowercased() }
    }

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                categorySection
                freezerSection

                Section {
                    Toggle("Active", isOn: $isActive)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                } header: {
                    Text("Details")
                }

                Section {
                    HStack {
                        TextField("Quantity", text: $typicalQuantityText)
                            .keyboardType(.decimalPad)
                        TextField("Unit", text: $typicalUnit)
                            .frame(maxWidth: 80)
                    }
                } header: {
                    Text("Typical purchase")
                } footer: {
                    Text("How you usually buy it (e.g. 50 lb bag of flour). Informational only — doesn't change grocery quantities.")
                }

                Section {
                    Picker("Auto-restock", selection: $recurringCadence) {
                        ForEach(cadenceOptions, id: \.value) { opt in
                            Text(opt.label).tag(opt.value)
                        }
                    }
                    if recurringCadence != "none" {
                        HStack {
                            TextField("Quantity", text: $recurringQuantityText)
                                .keyboardType(.decimalPad)
                            TextField("Unit", text: $recurringUnit)
                                .frame(maxWidth: 80)
                        }
                    }
                } header: {
                    Text("Recurring")
                } footer: {
                    Text("When set, this item lands on each week's grocery list automatically (filtered from meal aggregation either way). Use weekly for things like \"5 dozen eggs every week\".")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(SMColor.destructive)
                    }
                }
            }
            .navigationTitle(item == nil ? "Add pantry item" : "Edit pantry item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: seed)
            .onChange(of: name) { _, newValue in
                scheduleSearch(for: newValue)
            }
        }
    }

    // MARK: - Name section with autocomplete

    @ViewBuilder
    private var nameSection: some View {
        Section {
            TextField("Name (e.g. Eggs)", text: $name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
            if !nameSuggestions.isEmpty && shouldShowSuggestions {
                ForEach(nameSuggestions) { base in
                    Button {
                        applySuggestion(base)
                    } label: {
                        HStack(spacing: SMSpacing.sm) {
                            Image(systemName: "leaf.circle")
                                .foregroundStyle(SMColor.primary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(base.name)
                                    .font(SMFont.body)
                                    .foregroundStyle(SMColor.textPrimary)
                                if !base.category.isEmpty {
                                    Text(base.category)
                                        .font(SMFont.caption)
                                        .foregroundStyle(SMColor.textSecondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.caption)
                                .foregroundStyle(SMColor.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if isSearchingIngredients {
                HStack(spacing: SMSpacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Searching…")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
            }
        } header: {
            Text("Name")
        } footer: {
            Text("Type to search your ingredient catalog. Tap a match to autofill the name + category.")
        }
    }

    private var shouldShowSuggestions: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.lowercased() != lastAcceptedSuggestionName.lowercased()
    }
    @State private var lastAcceptedSuggestionName: String = ""

    private func applySuggestion(_ base: BaseIngredient) {
        name = base.name
        lastAcceptedSuggestionName = base.name
        nameSuggestions = []
        let trimmedCategory = base.category.trimmingCharacters(in: .whitespaces)
        if !trimmedCategory.isEmpty {
            selectedCategories.insert(trimmedCategory)
        }
    }

    private func scheduleSearch(for raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.count < 2 {
            nameSuggestions = []
            return
        }
        // Don't re-fire when the user just accepted a suggestion.
        if trimmed.lowercased() == lastAcceptedSuggestionName.lowercased() {
            nameSuggestions = []
            return
        }
        // Cancel the in-flight search so we only hit the network for
        // the latest keystroke (debounced 300 ms).
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runSearch(query: trimmed)
        }
    }

    private func runSearch(query: String) async {
        guard !query.isEmpty, query != lastSearchedQuery else { return }
        lastSearchedQuery = query
        isSearchingIngredients = true
        defer { isSearchingIngredients = false }
        do {
            let results = try await appState.apiClient.fetchBaseIngredients(
                query: query,
                limit: 8,
                includeProductLike: false
            )
            // Don't replace results with stale data if the user has
            // typed past this query already.
            if !Task.isCancelled, query == lastSearchedQuery {
                nameSuggestions = results
            }
        } catch {
            // Silent failure — autocomplete is a nice-to-have.
            // Free-text input still works.
        }
    }

    // MARK: - Category multi-select

    @ViewBuilder
    private var categorySection: some View {
        Section {
            FlowChips(
                items: availableCategories,
                isSelected: { selectedCategories.contains($0) },
                onToggle: { value in
                    if selectedCategories.contains(value) {
                        selectedCategories.remove(value)
                    } else {
                        selectedCategories.insert(value)
                    }
                }
            )
            HStack {
                TextField("Add custom (e.g. Bulk bin)", text: $customCategoryDraft)
                    .submitLabel(.done)
                Button {
                    addCustomCategory()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(SMColor.primary)
                }
                .disabled(customCategoryDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Categories")
        } footer: {
            Text("Tap any number of chips. Custom values you add are remembered and offered to other pantry items.")
        }
    }

    private func addCustomCategory() {
        let trimmed = customCategoryDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        selectedCategories.insert(trimmed)
        customCategoryDraft = ""
    }

    // MARK: - Freezer kind

    @ViewBuilder
    private var freezerSection: some View {
        Section {
            Toggle("Freezer item", isOn: $isFreezerItem)
                .onChange(of: isFreezerItem) { _, nowOn in
                    if nowOn {
                        // Pre-select the Freezer chip and seed today
                        // as the default placement date.
                        selectedCategories.insert("Freezer")
                    }
                }
            if isFreezerItem {
                DatePicker("Frozen on", selection: $frozenAt, displayedComponents: .date)
            }
        } header: {
            Text("Freezer")
        } footer: {
            Text(isFreezerItem
                 ? "Frozen items show up under the Freezer filter and trigger a \"Use soon\" badge after 30 days."
                 : "Toggle this on if the item lives in the freezer (leftovers, frozen meatballs, etc.).")
        }
    }

    // MARK: - Lifecycle

    private func seed() {
        guard let item else { return }
        name = item.stapleName
        lastAcceptedSuggestionName = item.stapleName
        selectedCategories = Set(item.displayCategories)
        notes = item.notes
        isActive = item.isActive
        typicalQuantityText = item.typicalQuantity.map { String($0.cleanFormat) } ?? ""
        typicalUnit = item.typicalUnit
        recurringCadence = item.recurringCadence
        recurringQuantityText = item.recurringQuantity.map { String($0.cleanFormat) } ?? ""
        recurringUnit = item.recurringUnit
        isFreezerItem = item.frozenAt != nil
        frozenAt = item.frozenAt ?? Date()
    }

    private func save() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil

        let typicalQty = Double(typicalQuantityText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let recurringQty = recurringCadence == "none"
            ? nil
            : Double(recurringQuantityText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        let categoriesPayload = Array(selectedCategories).sorted()

        if let existing = item {
            // PATCH path — only send what changed so partial saves
            // don't blank out fields on the server.
            var body = SimmerSmithAPIClient.PantryItemPatchBody()
            if trimmedName != existing.stapleName { body.stapleName = trimmedName }
            if Set(existing.displayCategories) != selectedCategories {
                body.categories = categoriesPayload
            }
            if notes != existing.notes { body.notes = notes }
            if isActive != existing.isActive { body.isActive = isActive }
            if typicalQty == nil && existing.typicalQuantity != nil {
                body.clearTypicalQuantity = true
            } else if let qty = typicalQty, qty != existing.typicalQuantity {
                body.typicalQuantity = qty
            }
            if typicalUnit != existing.typicalUnit { body.typicalUnit = typicalUnit }
            if recurringCadence != existing.recurringCadence { body.recurringCadence = recurringCadence }
            if recurringQty == nil && existing.recurringQuantity != nil {
                body.clearRecurringQuantity = true
            } else if let qty = recurringQty, qty != existing.recurringQuantity {
                body.recurringQuantity = qty
            }
            if recurringUnit != existing.recurringUnit { body.recurringUnit = recurringUnit }
            // Freezer kind: only emit the field that changed.
            // - On→off (was frozen, now not): clearFrozenAt = true
            // - Off→on or date changed: frozenAt = new value
            // - No change: send neither
            switch (existing.frozenAt, isFreezerItem) {
            case (.some, false):
                body.clearFrozenAt = true
            case (let prior, true) where prior != frozenAt:
                body.frozenAt = frozenAt
            default:
                break
            }
            await appState.patchPantryItem(itemID: existing.pantryItemId, body: body)
        } else {
            await appState.addPantryItem(
                SimmerSmithAPIClient.PantryItemAddBody(
                    stapleName: trimmedName,
                    notes: notes,
                    isActive: isActive,
                    typicalQuantity: typicalQty,
                    typicalUnit: typicalUnit,
                    recurringQuantity: recurringQty,
                    recurringUnit: recurringUnit,
                    recurringCadence: recurringCadence,
                    categories: categoriesPayload,
                    frozenAt: isFreezerItem ? frozenAt : nil
                )
            )
        }
        dismiss()
    }
}

/// Lightweight chip layout for the category multi-picker. Reuses
/// `SwiftUI.Layout` (iOS 16+); each chip is a Button so accessibility
/// + tap targets work without extra plumbing.
private struct FlowChips: View {
    let items: [String]
    let isSelected: (String) -> Bool
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button {
                    onToggle(item)
                } label: {
                    Text(item)
                        .font(SMFont.caption)
                        .foregroundStyle(isSelected(item) ? .white : SMColor.textPrimary)
                        .padding(.horizontal, SMSpacing.sm)
                        .padding(.vertical, 6)
                        .background(isSelected(item) ? SMColor.primary : SMColor.surfaceElevated)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                totalHeight += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + (lineWidth > 0 ? spacing : 0)
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private extension Double {
    /// Trim trailing zeros from a decimal: 5.0 → "5", 5.25 → "5.25".
    var cleanFormat: String {
        if self.rounded() == self {
            return String(Int(self))
        }
        return String(format: "%.2f", self).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
}
