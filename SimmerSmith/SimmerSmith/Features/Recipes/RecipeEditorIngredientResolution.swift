import SwiftUI
import SimmerSmithKit

struct IngredientResolutionSheetContext: Identifiable {
    let ingredientID: String
    let ingredient: RecipeIngredient

    var id: String { ingredientID }
}

struct IngredientResolutionSummary: View {
    let ingredient: RecipeIngredient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IngredientResolutionStatusBadge(status: ingredient.resolutionStatus)
                if let baseName = ingredient.baseIngredientName, !baseName.isEmpty {
                    Text(baseName)
                        .font(.footnote.weight(.semibold))
                } else {
                    Text("No canonical ingredient selected")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if let variationName = ingredient.ingredientVariationName, !variationName.isEmpty {
                Text(variationName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if ingredient.resolutionStatus == "suggested" {
                Text("Imported suggestions should be reviewed before shopping and nutrition rely on them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct IngredientResolutionStatusBadge: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case "locked":
            "Locked"
        case "resolved":
            "Resolved"
        case "suggested":
            "Suggested"
        default:
            "Unresolved"
        }
    }

    private var color: Color {
        switch status {
        case "locked":
            .purple
        case "resolved":
            .green
        case "suggested":
            .orange
        default:
            .secondary
        }
    }
}

struct IngredientResolutionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let ingredient: RecipeIngredient
    let onApply: (RecipeIngredient) -> Void

    @State private var searchText: String
    @State private var searchResults: [BaseIngredient] = []
    @State private var selectedBaseIngredient: BaseIngredient?
    @State private var suggestedResolution: IngredientResolution?
    @State private var variations: [IngredientVariation] = []
    @State private var selectedVariationID: String
    @State private var lockToVariation: Bool
    @State private var isLoadingSuggestion = false
    @State private var isSearching = false
    @State private var isLoadingVariations = false
    @State private var errorMessage: String?
    @State private var didLoad = false
    @State private var preferenceEditor: IngredientPreferenceEditorContext?
    @State private var newBaseIngredientContext: NewBaseIngredientContext?
    @State private var newVariationContext: NewVariationContext?

    init(
        ingredient: RecipeIngredient,
        onApply: @escaping (RecipeIngredient) -> Void
    ) {
        self.ingredient = ingredient
        self.onApply = onApply
        _searchText = State(initialValue: ingredient.baseIngredientName ?? ingredient.ingredientName)
        _selectedVariationID = State(initialValue: ingredient.ingredientVariationId ?? "")
        _lockToVariation = State(initialValue: ingredient.resolutionStatus == "locked")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recipe Ingredient") {
                    Text(ingredient.ingredientName)
                    IngredientResolutionSummary(ingredient: currentPreviewIngredient)
                }

                if let suggestedResolution,
                   let suggestedBaseName = suggestedResolution.baseIngredientName,
                   !suggestedBaseName.isEmpty {
                    Section("Suggested Match") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(suggestedBaseName)
                                .font(.headline)
                            if let variationName = suggestedResolution.ingredientVariationName,
                               !variationName.isEmpty {
                                Text(variationName)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Text("Use this if it matches the generic ingredient the recipe is talking about.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Use Suggested Match") {
                            Task { await applySuggestedMatch() }
                        }
                    }
                }

                Section("Find Canonical Ingredient") {
                    TextField("Search ingredients", text: $searchText)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()

                    Button {
                        Task { await searchIngredients() }
                    } label: {
                        HStack {
                            if isSearching {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Search Catalog")
                        }
                    }
                    .disabled(isSearching || searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if !searchResults.isEmpty {
                        ForEach(searchResults) { baseIngredient in
                            Button {
                                Task { await selectBaseIngredient(baseIngredient) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(baseIngredient.name)
                                            .foregroundStyle(.primary)
                                        if !baseIngredient.category.isEmpty {
                                            Text(baseIngredient.category)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedBaseIngredient?.id == baseIngredient.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isSearching {
                        Button {
                            newBaseIngredientContext = NewBaseIngredientContext(
                                suggestedName: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                                suggestedCategory: ingredient.category,
                                suggestedDefaultUnit: ingredient.unit
                            )
                        } label: {
                            Label("Create Base Ingredient", systemImage: "plus.circle")
                        }
                    }
                }

                if let selectedBaseIngredient {
                    Section("Selected Ingredient") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(selectedBaseIngredient.name)
                                .font(.headline)
                            if !selectedBaseIngredient.category.isEmpty {
                                Text(selectedBaseIngredient.category)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if !selectedBaseIngredient.defaultUnit.isEmpty {
                                Text("Default unit: \(selectedBaseIngredient.defaultUnit)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Product Variation") {
                        if isLoadingVariations {
                            ProgressView("Loading product matches…")
                        } else if variations.isEmpty {
                            Text("No specific product variations are stored yet. This ingredient can stay generic.")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Variation", selection: $selectedVariationID) {
                                Text("Generic ingredient").tag("")
                                ForEach(variations) { variation in
                                    Text(variationLabel(for: variation)).tag(variation.id)
                                }
                            }

                            if !selectedVariationID.isEmpty {
                                Toggle("Lock this recipe to the selected product", isOn: $lockToVariation)
                            }
                        }

                        Button {
                            newVariationContext = NewVariationContext(
                                baseIngredient: selectedBaseIngredient,
                                suggestedName: ingredient.ingredientName,
                                suggestedPackageSizeAmount: ingredient.quantity,
                                suggestedPackageSizeUnit: ingredient.unit,
                                suggestedNotes: ingredient.notes
                            )
                        } label: {
                            Label("Create Product Variation", systemImage: "plus.circle")
                        }
                    }

                    Section("Household Preference") {
                        Button("Set Household Preference") {
                            preferenceEditor = preferenceContext(for: selectedBaseIngredient)
                        }
                        Text("Use this when the recipe can stay generic but shopping should prefer a specific brand or product.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Clear Match", role: .destructive) {
                        clearSelection()
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("Ingredient Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applySelection()
                    }
                    .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
            .task {
                guard !didLoad else { return }
                didLoad = true
                await loadInitialState()
            }
        }
        .sheet(item: $preferenceEditor) { context in
            IngredientPreferenceEditorSheet(context: context)
        }
        .sheet(item: $newBaseIngredientContext) { context in
            NewBaseIngredientSheet(context: context) { created in
                Task {
                    searchText = created.name
                    searchResults = [created]
                    await selectBaseIngredient(created)
                }
            }
        }
        .sheet(item: $newVariationContext) { context in
            NewIngredientVariationSheet(context: context) { created in
                Task {
                    await loadVariations(for: created.baseIngredientId)
                    selectedVariationID = created.ingredientVariationId
                    lockToVariation = true
                }
            }
        }
    }

    private var currentPreviewIngredient: RecipeIngredient {
        var updated = ingredient
        updated.baseIngredientId = selectedBaseIngredient?.baseIngredientId
        updated.baseIngredientName = selectedBaseIngredient?.name
        if let selectedVariation = selectedVariation {
            updated.ingredientVariationId = selectedVariation.ingredientVariationId
            updated.ingredientVariationName = selectedVariation.name
            updated.resolutionStatus = lockToVariation ? "locked" : "resolved"
        } else if selectedBaseIngredient != nil {
            updated.ingredientVariationId = nil
            updated.ingredientVariationName = nil
            updated.resolutionStatus = "resolved"
        } else if let suggestedResolution {
            updated.baseIngredientId = suggestedResolution.baseIngredientId
            updated.baseIngredientName = suggestedResolution.baseIngredientName
            updated.ingredientVariationId = suggestedResolution.ingredientVariationId
            updated.ingredientVariationName = suggestedResolution.ingredientVariationName
            updated.resolutionStatus = suggestedResolution.resolutionStatus
        } else {
            updated.baseIngredientId = nil
            updated.baseIngredientName = nil
            updated.ingredientVariationId = nil
            updated.ingredientVariationName = nil
            updated.resolutionStatus = "unresolved"
        }
        return updated
    }

    private var selectedVariation: IngredientVariation? {
        variations.first(where: { $0.ingredientVariationId == selectedVariationID })
    }

    private func loadInitialState() async {
        if let existingBaseName = ingredient.baseIngredientName, !existingBaseName.isEmpty {
            searchText = existingBaseName
        }
        await searchIngredients()
        if ingredient.baseIngredientId == nil {
            await loadSuggestedResolution()
        }
    }

    private func loadSuggestedResolution() async {
        do {
            isLoadingSuggestion = true
            suggestedResolution = try await appState.resolveIngredient(ingredient)
            if selectedBaseIngredient == nil,
               let suggestedBaseID = suggestedResolution?.baseIngredientId {
                if let matched = searchResults.first(where: { $0.baseIngredientId == suggestedBaseID }) {
                    await selectBaseIngredient(matched)
                } else if let suggestedBaseName = suggestedResolution?.baseIngredientName {
                    searchText = suggestedBaseName
                    await searchIngredients()
                    if let matched = searchResults.first(where: { $0.baseIngredientId == suggestedBaseID }) {
                        await selectBaseIngredient(matched)
                    }
                }
                if let suggestedVariationID = suggestedResolution?.ingredientVariationId {
                    selectedVariationID = suggestedVariationID
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoadingSuggestion = false
    }

    private func searchIngredients() async {
        do {
            isSearching = true
            errorMessage = nil
            searchResults = try await appState.searchBaseIngredients(
                query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 20
            )
            if let existingBaseID = ingredient.baseIngredientId,
               let matched = searchResults.first(where: { $0.baseIngredientId == existingBaseID }),
               selectedBaseIngredient == nil {
                await selectBaseIngredient(matched)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }

    private func selectBaseIngredient(_ baseIngredient: BaseIngredient) async {
        selectedBaseIngredient = baseIngredient
        selectedVariationID = ingredient.ingredientVariationId ?? suggestedResolution?.ingredientVariationId ?? ""
        lockToVariation = ingredient.resolutionStatus == "locked"
        await loadVariations(for: baseIngredient.baseIngredientId)
    }

    private func loadVariations(for baseIngredientID: String) async {
        do {
            isLoadingVariations = true
            variations = try await appState.fetchIngredientVariations(baseIngredientID: baseIngredientID)
            if !selectedVariationID.isEmpty,
               !variations.contains(where: { $0.ingredientVariationId == selectedVariationID }) {
                selectedVariationID = ""
                lockToVariation = false
            }
        } catch {
            errorMessage = error.localizedDescription
            variations = []
        }
        isLoadingVariations = false
    }

    private func applySuggestedMatch() async {
        guard let suggestedResolution else { return }
        if let baseIngredientID = suggestedResolution.baseIngredientId,
           let matched = searchResults.first(where: { $0.baseIngredientId == baseIngredientID }) {
            await selectBaseIngredient(matched)
        }
        selectedVariationID = suggestedResolution.ingredientVariationId ?? ""
        lockToVariation = suggestedResolution.resolutionStatus == "locked"
    }

    private func clearSelection() {
        selectedBaseIngredient = nil
        selectedVariationID = ""
        lockToVariation = false
    }

    private func applySelection() {
        var updated = ingredient
        if let selectedBaseIngredient {
            updated.baseIngredientId = selectedBaseIngredient.baseIngredientId
            updated.baseIngredientName = selectedBaseIngredient.name
            updated.normalizedName = updated.normalizedName ?? selectedBaseIngredient.normalizedName
            if let selectedVariation {
                updated.ingredientVariationId = selectedVariation.ingredientVariationId
                updated.ingredientVariationName = selectedVariation.name
                updated.resolutionStatus = lockToVariation ? "locked" : "resolved"
            } else {
                updated.ingredientVariationId = nil
                updated.ingredientVariationName = nil
                updated.resolutionStatus = "resolved"
            }
        } else {
            updated.baseIngredientId = nil
            updated.baseIngredientName = nil
            updated.ingredientVariationId = nil
            updated.ingredientVariationName = nil
            updated.resolutionStatus = "unresolved"
        }
        onApply(updated)
        dismiss()
    }

    private func variationLabel(for variation: IngredientVariation) -> String {
        if variation.brand.isEmpty {
            return variation.name
        }
        return "\(variation.brand) • \(variation.name)"
    }

    private func preferenceContext(for baseIngredient: BaseIngredient) -> IngredientPreferenceEditorContext {
        if let existing = appState.ingredientPreferences.first(where: { $0.baseIngredientId == baseIngredient.baseIngredientId }) {
            return IngredientPreferenceEditorContext(preference: existing)
        }
        return IngredientPreferenceEditorContext(
            seedBaseIngredientID: baseIngredient.baseIngredientId,
            seedBaseIngredientName: baseIngredient.name,
            seedPreferredVariationID: selectedVariationID.isEmpty ? nil : selectedVariationID
        )
    }
}

private struct NewBaseIngredientContext: Identifiable {
    let id = UUID()
    let suggestedName: String
    let suggestedCategory: String
    let suggestedDefaultUnit: String
}

private struct NewVariationContext: Identifiable {
    let id = UUID()
    let baseIngredient: BaseIngredient
    let suggestedName: String
    let suggestedPackageSizeAmount: Double?
    let suggestedPackageSizeUnit: String
    let suggestedNotes: String
}

private struct NewBaseIngredientSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: NewBaseIngredientContext
    let onCreated: (BaseIngredient) -> Void

    @State private var name: String
    @State private var category: String
    @State private var defaultUnit: String
    @State private var notes = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(context: NewBaseIngredientContext, onCreated: @escaping (BaseIngredient) -> Void) {
        self.context = context
        self.onCreated = onCreated
        _name = State(initialValue: context.suggestedName)
        _category = State(initialValue: context.suggestedCategory)
        _defaultUnit = State(initialValue: context.suggestedDefaultUnit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Base Ingredient") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Category", text: $category)
                        .textInputAutocapitalization(.words)
                    TextField("Default unit", text: $defaultUnit)
                        .textInputAutocapitalization(.never)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("New Base Ingredient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .smithToolbar()
        }
    }

    private func save() async {
        do {
            isSaving = true
            let created = try await appState.createBaseIngredient(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                category: category.trimmingCharacters(in: .whitespacesAndNewlines),
                defaultUnit: defaultUnit.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}

private struct NewIngredientVariationSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let context: NewVariationContext
    let onCreated: (IngredientVariation) -> Void

    @State private var name: String
    @State private var brand = ""
    @State private var packageSizeAmountText: String
    @State private var packageSizeUnit: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(context: NewVariationContext, onCreated: @escaping (IngredientVariation) -> Void) {
        self.context = context
        self.onCreated = onCreated
        _name = State(initialValue: context.suggestedName)
        _packageSizeAmountText = State(initialValue: context.suggestedPackageSizeAmount.map { $0.formatted() } ?? "")
        _packageSizeUnit = State(initialValue: context.suggestedPackageSizeUnit)
        _notes = State(initialValue: context.suggestedNotes)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Base Ingredient") {
                    Text(context.baseIngredient.name)
                        .font(.headline)
                    if !context.baseIngredient.category.isEmpty {
                        Text(context.baseIngredient.category)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Product Variation") {
                    TextField("Variation name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("Brand", text: $brand)
                        .textInputAutocapitalization(.words)
                    TextField("Package amount", text: $packageSizeAmountText)
                        .keyboardType(.decimalPad)
                    TextField("Package unit", text: $packageSizeUnit)
                        .textInputAutocapitalization(.never)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .paperBackground()
            .navigationTitle("New Variation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .foregroundStyle(SMColor.ember)
                    .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .smithToolbar()
        }
    }

    private func save() async {
        do {
            isSaving = true
            let created = try await appState.createIngredientVariation(
                baseIngredientID: context.baseIngredient.baseIngredientId,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                brand: brand.trimmingCharacters(in: .whitespacesAndNewlines),
                packageSizeAmount: Double(packageSizeAmountText.trimmingCharacters(in: .whitespacesAndNewlines)),
                packageSizeUnit: packageSizeUnit.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            onCreated(created)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}
