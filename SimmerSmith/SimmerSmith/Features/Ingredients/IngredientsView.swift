import SwiftUI
import SimmerSmithKit

struct IngredientsView: View {
    @Environment(AppState.self) private var appState

    @State private var searchText = ""
    @State private var filter = IngredientCatalogFilter.all
    @State private var includeArchived = false
    @State private var includeProductLike = false
    @State private var ingredients: [BaseIngredient] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editorContext: BaseIngredientEditorContext?

    var body: some View {
        List {
            Section {
                Picker("Catalog Filter", selection: $filter) {
                    ForEach(IngredientCatalogFilter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Toggle("Show archived ingredients", isOn: $includeArchived)
                Toggle("Show product-like rows", isOn: $includeProductLike)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Loading ingredient catalog…")
                            .foregroundStyle(.secondary)
                    }
                } else if ingredients.isEmpty {
                    ContentUnavailableView(
                        "No Ingredients",
                        systemImage: "shippingbox",
                        description: Text(emptyStateMessage)
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(ingredients) { ingredient in
                        NavigationLink {
                            IngredientDetailView(baseIngredientID: ingredient.baseIngredientId)
                        } label: {
                            IngredientCatalogRow(ingredient: ingredient)
                        }
                    }
                }
            } header: {
                Text("Ingredients")
            } footer: {
                if !ingredients.isEmpty {
                    Text("\(ingredients.count) ingredient\(ingredients.count == 1 ? "" : "s") loaded")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ingredients")
        .searchable(text: $searchText, prompt: "Search ingredients, brands, UPCs")
        .toolbar {
            ToolbarItem(placement: .principal) {
                BrandToolbarBadge()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorContext = BaseIngredientEditorContext()
                } label: {
                    Label("New Ingredient", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editorContext) { context in
            BaseIngredientEditorSheet(context: context) { _ in
                Task { await loadIngredients() }
            }
        }
        .task(id: loadKey) {
            await loadIngredients()
        }
    }

    private var loadKey: String {
        [
            searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            filter.rawValue,
            includeArchived.description,
            includeProductLike.description,
        ].joined(separator: "|")
    }

    private var emptyStateMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Try a broader search term or switch catalog filters."
        }
        return "Import a recipe, create a new ingredient, or run the ingredient seed scripts to expand the catalog."
    }

    private func loadIngredients() async {
        do {
            isLoading = true
            errorMessage = nil
            ingredients = try await appState.searchBaseIngredients(
                query: searchText,
                limit: 200,
                includeArchived: includeArchived,
                provisionalOnly: filter == .provisional,
                withPreferences: filter == .withPreferences,
                withVariations: filter == .withProducts,
                includeProductLike: includeProductLike
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct IngredientCatalogRow: View {
    let ingredient: BaseIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(ingredient.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                if ingredient.provisional {
                    IngredientBadge(title: "Review", tint: .orange)
                } else if ingredient.productLike {
                    IngredientBadge(title: "Product-like", tint: .blue)
                } else if !ingredient.active {
                    IngredientBadge(title: "Archived", tint: .secondary)
                }
            }

            HStack(spacing: 8) {
                if !ingredient.category.isEmpty {
                    Text(ingredient.category)
                }
                if !ingredient.defaultUnit.isEmpty {
                    Text("Unit \(ingredient.defaultUnit)")
                }
                if ingredient.preferenceCount > 0 {
                    Text("Prefs \(ingredient.preferenceCount)")
                }
                if ingredient.variationCount > 0 {
                    Text("Products \(ingredient.variationCount)")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let sourceText = ingredientCatalogSourceText(ingredient), !sourceText.isEmpty {
                Text(sourceText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct IngredientDetailView: View {
    @Environment(AppState.self) private var appState

    let baseIngredientID: String

    @State private var detail: BaseIngredientDetail?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editorContext: BaseIngredientEditorContext?
    @State private var variationEditorContext: IngredientVariationEditorContext?
    @State private var mergePresented = false
    @State private var preferenceEditor: IngredientPreferenceEditorContext?
    @State private var archiveConfirmationPresented = false
    @State private var reloadToken = UUID()

    var body: some View {
        List { listContent }
        .navigationTitle(detail?.ingredient.name ?? "Ingredient")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let detail {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Manage") {
                        Button("Edit") {
                            editorContext = BaseIngredientEditorContext(ingredient: detail.ingredient)
                        }
                        Button("Merge Into Another Ingredient") {
                            mergePresented = true
                        }
                        Button("Archive", role: .destructive) {
                            archiveConfirmationPresented = true
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Archive Ingredient?",
            isPresented: $archiveConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Archive", role: .destructive) {
                Task {
                    do {
                        _ = try await appState.archiveBaseIngredient(baseIngredientID: baseIngredientID)
                        reloadToken = UUID()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Archived ingredients stay in the database but fall out of normal pickers and review flows.")
        }
        .sheet(item: $editorContext) { context in
            BaseIngredientEditorSheet(context: context) { _ in
                reloadToken = UUID()
            }
        }
        .sheet(item: $variationEditorContext) { context in
            IngredientVariationEditorSheet(context: context) { _ in
                reloadToken = UUID()
            }
        }
        .sheet(item: $preferenceEditor) { context in
            IngredientPreferenceEditorSheet(context: context)
        }
        .sheet(isPresented: $mergePresented) {
            BaseIngredientMergeSheet(baseIngredientID: baseIngredientID) {
                reloadToken = UUID()
            }
        }
        .task(id: reloadToken) {
            await loadDetail()
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if let errorMessage {
            Section {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }

        if isLoading, detail == nil {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Loading ingredient…")
                        .foregroundStyle(.secondary)
                }
            }
        }

        if let detail {
            detailSections(detail)
        }
    }

    @ViewBuilder
    private func detailSections(_ detail: BaseIngredientDetail) -> some View {
        overviewSection(detail)
        nutritionSection(detail)
        preferenceSection(detail)
        productsSection(detail)
        usageSection(detail)
        sourceSection(detail)
    }

    @ViewBuilder
    private func overviewSection(_ detail: BaseIngredientDetail) -> some View {
        Section("Overview") {
            LabeledContent("Name") {
                Text(detail.ingredient.name)
            }
            if !detail.ingredient.category.isEmpty {
                LabeledContent("Category") {
                    Text(detail.ingredient.category)
                }
            }
            if !detail.ingredient.defaultUnit.isEmpty {
                LabeledContent("Default unit") {
                    Text(detail.ingredient.defaultUnit)
                }
            }
            LabeledContent("Status") {
                Text(statusText(for: detail.ingredient))
            }
            if !detail.ingredient.notes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Notes")
                        .font(.subheadline.weight(.medium))
                    Text(detail.ingredient.notes)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func nutritionSection(_ detail: BaseIngredientDetail) -> some View {
        Section("Nutrition") {
            if let calories = detail.ingredient.calories {
                LabeledContent("Calories") {
                    Text(calories.formatted(.number.precision(.fractionLength(0...2))))
                }
            } else {
                Text("No calories stored yet.")
                    .foregroundStyle(.secondary)
            }
            if let amount = detail.ingredient.nutritionReferenceAmount,
               !detail.ingredient.nutritionReferenceUnit.isEmpty {
                LabeledContent("Reference") {
                    Text("\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(detail.ingredient.nutritionReferenceUnit)")
                }
            }
        }
    }

    @ViewBuilder
    private func preferenceSection(_ detail: BaseIngredientDetail) -> some View {
        Section("Preference") {
            if let preference = detail.preference {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preference.choiceMode.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.body.weight(.medium))
                    if let variationName = preference.preferredVariationName, !variationName.isEmpty {
                        Text(variationName)
                            .foregroundStyle(.secondary)
                    } else if !preference.preferredBrand.isEmpty {
                        Text(preference.preferredBrand)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Edit Household Preference") {
                    preferenceEditor = IngredientPreferenceEditorContext(preference: preference)
                }
            } else {
                Text("No household preference is set for this ingredient.")
                    .foregroundStyle(.secondary)
                Button("Set Household Preference") {
                    preferenceEditor = IngredientPreferenceEditorContext(
                        seedBaseIngredientID: detail.ingredient.baseIngredientId,
                        seedBaseIngredientName: detail.ingredient.name
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func productsSection(_ detail: BaseIngredientDetail) -> some View {
        Section("Products") {
            if detail.variations.isEmpty {
                Text("No product variations yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(detail.variations) { variation in
                    productRow(detail.ingredient, variation: variation)
                }
            }

            Button {
                variationEditorContext = IngredientVariationEditorContext(
                    baseIngredient: detail.ingredient,
                    variation: nil
                )
            } label: {
                Label("Add Product Variation", systemImage: "plus.circle")
            }
        }
    }

    private func productRow(_ ingredient: BaseIngredient, variation: IngredientVariation) -> some View {
        Button {
            variationEditorContext = IngredientVariationEditorContext(
                baseIngredient: ingredient,
                variation: variation
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(variation.brand.isEmpty ? variation.name : "\(variation.brand) • \(variation.name)")
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if let amount = variation.packageSizeAmount, !variation.packageSizeUnit.isEmpty {
                        Text("\(amount.formatted(.number.precision(.fractionLength(0...2)))) \(variation.packageSizeUnit)")
                    }
                    if let count = variation.countPerPackage {
                        Text("\(count.formatted(.number.precision(.fractionLength(0...2)))) per pack")
                    }
                    if !variation.upc.isEmpty {
                        Text("UPC \(variation.upc)")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit") {
                variationEditorContext = IngredientVariationEditorContext(
                    baseIngredient: ingredient,
                    variation: variation
                )
            }
            Button("Archive", role: .destructive) {
                Task {
                    do {
                        _ = try await appState.archiveIngredientVariation(
                            ingredientVariationID: variation.ingredientVariationId
                        )
                        reloadToken = UUID()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func usageSection(_ detail: BaseIngredientDetail) -> some View {
        Section("Usage") {
            usageRow(title: "Recipes", value: detail.ingredient.recipeUsageCount, sample: detail.usage.linkedRecipeNames)
            usageRow(title: "Grocery items", value: detail.ingredient.groceryUsageCount, sample: detail.usage.linkedGroceryNames)
        }
    }

    @ViewBuilder
    private func sourceSection(_ detail: BaseIngredientDetail) -> some View {
        Section("Source") {
            if let sourceText = ingredientCatalogSourceText(detail.ingredient), !sourceText.isEmpty {
                Text(sourceText)
            } else {
                Text("Custom SimmerSmith ingredient")
                    .foregroundStyle(.secondary)
            }
            let sourceURL = detail.ingredient.sourceURL
            if !sourceURL.isEmpty {
                Text(sourceURL)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func usageRow(title: String, value: Int, sample: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                Text("\(value)")
            }
            if !sample.isEmpty {
                Text(sample.prefix(3).joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusText(for ingredient: BaseIngredient) -> String {
        if !ingredient.active {
            return "Archived"
        }
        if ingredient.provisional {
            return "Needs review"
        }
        return "Active"
    }

    private func loadDetail() async {
        do {
            isLoading = true
            errorMessage = nil
            detail = try await appState.fetchBaseIngredientDetail(baseIngredientID: baseIngredientID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct IngredientBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

private enum IngredientCatalogFilter: String, CaseIterable, Identifiable {
    case all
    case provisional
    case withPreferences
    case withProducts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .provisional: return "Needs Review"
        case .withPreferences: return "With Preferences"
        case .withProducts: return "With Products"
        }
    }
}

struct BaseIngredientEditorContext: Identifiable {
    let id = UUID()
    let ingredient: BaseIngredient?

    init(ingredient: BaseIngredient? = nil) {
        self.ingredient = ingredient
    }
}

struct BaseIngredientEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: BaseIngredientEditorContext
    let onSaved: (BaseIngredient) -> Void

    @State private var name: String
    @State private var category: String
    @State private var defaultUnit: String
    @State private var notes: String
    @State private var calories: String
    @State private var nutritionAmount: String
    @State private var nutritionUnit: String
    @State private var provisional: Bool
    @State private var active: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(context: BaseIngredientEditorContext, onSaved: @escaping (BaseIngredient) -> Void) {
        self.context = context
        self.onSaved = onSaved
        _name = State(initialValue: context.ingredient?.name ?? "")
        _category = State(initialValue: context.ingredient?.category ?? "")
        _defaultUnit = State(initialValue: context.ingredient?.defaultUnit ?? "")
        _notes = State(initialValue: context.ingredient?.notes ?? "")
        _calories = State(initialValue: decimalString(context.ingredient?.calories))
        _nutritionAmount = State(initialValue: decimalString(context.ingredient?.nutritionReferenceAmount))
        _nutritionUnit = State(initialValue: context.ingredient?.nutritionReferenceUnit ?? "")
        _provisional = State(initialValue: context.ingredient?.provisional ?? false)
        _active = State(initialValue: context.ingredient?.active ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Category", text: $category)
                    TextField("Default unit", text: $defaultUnit)
                }

                Section("Nutrition") {
                    TextField("Calories", text: $calories)
                        .keyboardType(.decimalPad)
                    TextField("Reference amount", text: $nutritionAmount)
                        .keyboardType(.decimalPad)
                    TextField("Reference unit", text: $nutritionUnit)
                }

                Section("State") {
                    Toggle("Needs review", isOn: $provisional)
                    Toggle("Active", isOn: $active)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(context.ingredient == nil ? "New Ingredient" : "Edit Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        do {
            isSaving = true
            errorMessage = nil
            let saved: BaseIngredient
            if let existing = context.ingredient {
                saved = try await appState.updateBaseIngredient(
                    baseIngredientID: existing.baseIngredientId,
                    name: name,
                    category: category,
                    defaultUnit: defaultUnit,
                    notes: notes,
                    provisional: provisional,
                    active: active,
                    nutritionReferenceAmount: Double(nutritionAmount),
                    nutritionReferenceUnit: nutritionUnit,
                    calories: Double(calories)
                )
            } else {
                saved = try await appState.createBaseIngredient(
                    name: name,
                    category: category,
                    defaultUnit: defaultUnit,
                    notes: notes,
                    provisional: provisional,
                    active: active,
                    nutritionReferenceAmount: Double(nutritionAmount),
                    nutritionReferenceUnit: nutritionUnit,
                    calories: Double(calories)
                )
            }
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

struct IngredientVariationEditorContext: Identifiable {
    let id = UUID()
    let baseIngredient: BaseIngredient
    let variation: IngredientVariation?
}

struct IngredientVariationEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: IngredientVariationEditorContext
    let onSaved: (IngredientVariation) -> Void

    @State private var name: String
    @State private var brand: String
    @State private var upc: String
    @State private var packageAmount: String
    @State private var packageUnit: String
    @State private var countPerPackage: String
    @State private var productURL: String
    @State private var retailerHint: String
    @State private var notes: String
    @State private var calories: String
    @State private var nutritionAmount: String
    @State private var nutritionUnit: String
    @State private var active: Bool
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(context: IngredientVariationEditorContext, onSaved: @escaping (IngredientVariation) -> Void) {
        self.context = context
        self.onSaved = onSaved
        _name = State(initialValue: context.variation?.name ?? "")
        _brand = State(initialValue: context.variation?.brand ?? "")
        _upc = State(initialValue: context.variation?.upc ?? "")
        _packageAmount = State(initialValue: decimalString(context.variation?.packageSizeAmount))
        _packageUnit = State(initialValue: context.variation?.packageSizeUnit ?? "")
        _countPerPackage = State(initialValue: decimalString(context.variation?.countPerPackage))
        _productURL = State(initialValue: context.variation?.productUrl ?? "")
        _retailerHint = State(initialValue: context.variation?.retailerHint ?? "")
        _notes = State(initialValue: context.variation?.notes ?? "")
        _calories = State(initialValue: decimalString(context.variation?.calories))
        _nutritionAmount = State(initialValue: decimalString(context.variation?.nutritionReferenceAmount))
        _nutritionUnit = State(initialValue: context.variation?.nutritionReferenceUnit ?? "")
        _active = State(initialValue: context.variation?.active ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Name", text: $name)
                    TextField("Brand", text: $brand)
                    TextField("UPC", text: $upc)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Package") {
                    TextField("Package amount", text: $packageAmount)
                        .keyboardType(.decimalPad)
                    TextField("Package unit", text: $packageUnit)
                    TextField("Count per package", text: $countPerPackage)
                        .keyboardType(.decimalPad)
                }

                Section("Nutrition") {
                    TextField("Calories", text: $calories)
                        .keyboardType(.decimalPad)
                    TextField("Reference amount", text: $nutritionAmount)
                        .keyboardType(.decimalPad)
                    TextField("Reference unit", text: $nutritionUnit)
                }

                Section("Retail") {
                    TextField("Retailer hint", text: $retailerHint)
                    TextField("Product URL", text: $productURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }

                Section("State") {
                    Toggle("Active", isOn: $active)
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(context.variation == nil ? "New Product" : "Edit Product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        do {
            isSaving = true
            errorMessage = nil
            let saved: IngredientVariation
            if let existing = context.variation {
                saved = try await appState.updateIngredientVariation(
                    ingredientVariationID: existing.ingredientVariationId,
                    baseIngredientID: context.baseIngredient.baseIngredientId,
                    name: name,
                    brand: brand,
                    upc: upc,
                    packageSizeAmount: Double(packageAmount),
                    packageSizeUnit: packageUnit,
                    countPerPackage: Double(countPerPackage),
                    productUrl: productURL,
                    retailerHint: retailerHint,
                    notes: notes,
                    active: active,
                    nutritionReferenceAmount: Double(nutritionAmount),
                    nutritionReferenceUnit: nutritionUnit,
                    calories: Double(calories)
                )
            } else {
                saved = try await appState.createIngredientVariation(
                    baseIngredientID: context.baseIngredient.baseIngredientId,
                    name: name,
                    brand: brand,
                    upc: upc,
                    packageSizeAmount: Double(packageAmount),
                    packageSizeUnit: packageUnit,
                    countPerPackage: Double(countPerPackage),
                    productUrl: productURL,
                    retailerHint: retailerHint,
                    notes: notes,
                    active: active,
                    nutritionReferenceAmount: Double(nutritionAmount),
                    nutritionReferenceUnit: nutritionUnit,
                    calories: Double(calories)
                )
            }
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

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
            .navigationTitle("Merge Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isMerging ? "Merging…" : "Merge") {
                        Task { await merge() }
                    }
                    .disabled(isMerging || selectedTargetID == nil)
                }
            }
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

private func ingredientCatalogSourceText(_ ingredient: BaseIngredient) -> String? {
    let sourceName = ingredient.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceRecordID = ingredient.sourceRecordId.trimmingCharacters(in: .whitespacesAndNewlines)
    if sourceName.isEmpty {
        return ingredient.provisional ? "Provisional SimmerSmith ingredient" : nil
    }
    if sourceRecordID.isEmpty {
        return sourceName
    }
    return "\(sourceName) • \(sourceRecordID)"
}

private func decimalString(_ value: Double?) -> String {
    guard let value else { return "" }
    return value.formatted(.number.precision(.fractionLength(0...2)))
}
