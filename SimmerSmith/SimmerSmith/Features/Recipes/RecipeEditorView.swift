import SwiftUI
import SimmerSmithKit

private enum ManagedRecipeField: String, Identifiable {
    case cuisine
    case tag
    case unit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cuisine:
            "New Cuisine"
        case .tag:
            "New Tag"
        case .unit:
            "New Unit"
        }
    }

    var kind: String {
        switch self {
        case .cuisine:
            "cuisine"
        case .tag:
            "tag"
        case .unit:
            "unit"
        }
    }

    var placeholder: String {
        switch self {
        case .cuisine:
            "Thai"
        case .tag:
            "Low carb"
        case .unit:
            "cup"
        }
    }
}

private struct IngredientResolutionSheetContext: Identifiable {
    let ingredientID: String
    let ingredient: RecipeIngredient

    var id: String { ingredientID }
}

private struct IngredientResolutionSummary: View {
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

private struct IngredientResolutionSheet: View {
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
            .navigationTitle("Ingredient Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        applySelection()
                    }
                }
            }
            .task {
                guard !didLoad else { return }
                didLoad = true
                await loadInitialState()
            }
        }
        .sheet(item: $preferenceEditor) { context in
            IngredientPreferenceEditorSheet(context: context)
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

struct RecipeEditorView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let title: String
    let initialDraft: RecipeDraft
    let onSaved: (RecipeSummary) -> Void

    @State private var draft: RecipeDraft
    @State private var servingsText: String
    @State private var prepMinutesText: String
    @State private var cookMinutesText: String
    @State private var nutritionSummary: NutritionSummary?
    @State private var isEstimatingNutrition = false
    @State private var nutritionEstimateError: String?
    @State private var nutritionMatchContext: RecipeNutritionMatchContext?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var pendingManagedField: ManagedRecipeField?
    @State private var pendingManagedValue = ""
    @State private var pendingUnitIngredientID: String?
    @State private var isCreatingManagedValue = false
    @State private var ingredientResolutionContext: IngredientResolutionSheetContext?

    init(
        title: String,
        initialDraft: RecipeDraft,
        onSaved: @escaping (RecipeSummary) -> Void
    ) {
        self.title = title
        self.initialDraft = initialDraft
        self.onSaved = onSaved
        _draft = State(initialValue: initialDraft)
        _servingsText = State(initialValue: initialDraft.servings.map { $0.formatted() } ?? "")
        _prepMinutesText = State(initialValue: initialDraft.prepMinutes.map(String.init) ?? "")
        _cookMinutesText = State(initialValue: initialDraft.cookMinutes.map(String.init) ?? "")
        _nutritionSummary = State(initialValue: initialDraft.nutritionSummary)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Core") {
                    LabeledContent("Recipe name") {
                        TextField("Pad Thai", text: $draft.name)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Meal type", selection: $draft.mealType) {
                        Text("Dinner").tag("dinner")
                        Text("Breakfast").tag("breakfast")
                        Text("Lunch").tag("lunch")
                        Text("Snack").tag("snack")
                        Text("Other").tag("")
                    }

                    Picker("Cuisine", selection: $draft.cuisine) {
                        Text("None").tag("")
                        ForEach(appState.recipeMetadata?.cuisines ?? []) { cuisine in
                            Text(cuisine.name).tag(cuisine.name)
                        }
                    }

                    Button {
                        pendingManagedField = .cuisine
                        pendingManagedValue = ""
                    } label: {
                        Label("Add cuisine", systemImage: "plus.circle")
                    }

                    Toggle("Favorite", isOn: $draft.favorite)
                }

                Section("Tags") {
                    if draft.tags.isEmpty {
                        Text("Tags show up as filters and quick chips in the recipe library.")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(draft.tags, id: \.self) { tag in
                                    Button {
                                        removeTag(tag)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Text(tag)
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(.thinMaterial, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    Menu {
                        ForEach(availableTags, id: \.self) { tag in
                            Button(tag) { addTag(tag) }
                        }
                        Divider()
                        Button("Create new tag") {
                            pendingManagedField = .tag
                            pendingManagedValue = ""
                        }
                    } label: {
                        Label("Add tag", systemImage: "tag")
                    }
                }

                Section("Assistant") {
                    Button {
                        Task {
                            do {
                                try await appState.beginAssistantLaunch(
                                    initialText: "Help me refine this recipe draft and make it clearer, more balanced, and easier to cook.",
                                    title: draft.name.isEmpty ? "Recipe Draft" : draft.name,
                                    attachedRecipeDraft: draft,
                                    intent: "recipe_refinement"
                                )
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Refine With Assistant", systemImage: "sparkles")
                    }

                    Text("Open this draft in the Assistant chat to talk through substitutions, structure, and cooking notes before saving.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Timing") {
                    LabeledContent("Servings") {
                        TextField("4", text: $servingsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Prep minutes") {
                        TextField("15", text: $prepMinutesText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Cook minutes") {
                        TextField("20", text: $cookMinutesText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Ingredients") {
                    if draft.ingredients.isEmpty {
                        Text("Add the ingredients you need and choose units from the shared list.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($draft.ingredients) { $ingredient in
                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent("Ingredient") {
                                TextField("Ingredient", text: $ingredient.ingredientName)
                                    .multilineTextAlignment(.trailing)
                            }

                            HStack {
                                LabeledContent("Quantity") {
                                    TextField("Amount", text: binding(for: $ingredient.quantity))
                                        .keyboardType(.decimalPad)
                                        .multilineTextAlignment(.trailing)
                                }
                                Picker("Unit", selection: $ingredient.unit) {
                                    Text("None").tag("")
                                    ForEach(appState.recipeMetadata?.units ?? []) { unit in
                                        Text(unit.name).tag(unit.name)
                                    }
                                }
                            }

                            HStack {
                                Button {
                                    pendingManagedField = .unit
                                    pendingManagedValue = ""
                                    pendingUnitIngredientID = ingredient.id
                                } label: {
                                    Label("Add unit", systemImage: "plus.circle")
                                }

                                Spacer()
                            }

                            LabeledContent("Prep") {
                                TextField("Optional", text: $ingredient.prep)
                                    .multilineTextAlignment(.trailing)
                            }

                            LabeledContent("Category") {
                                TextField("Optional", text: $ingredient.category)
                                    .multilineTextAlignment(.trailing)
                            }

                            LabeledContent("Notes") {
                                TextField("Optional", text: $ingredient.notes, axis: .vertical)
                                    .multilineTextAlignment(.trailing)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                IngredientResolutionSummary(ingredient: ingredient)
                                Button {
                                    ingredientResolutionContext = IngredientResolutionSheetContext(
                                        ingredientID: ingredient.id,
                                        ingredient: ingredient
                                    )
                                } label: {
                                    Label(
                                        ingredient.baseIngredientId == nil ? "Review ingredient match" : "Change ingredient match",
                                        systemImage: "arrow.triangle.branch"
                                    )
                                }
                                .font(.footnote)
                            }

                            HStack {
                                Spacer()
                                Button("Remove ingredient", role: .destructive) {
                                    removeIngredient(ingredient.id)
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Button {
                        addIngredient()
                    } label: {
                        Label("Add ingredient", systemImage: "plus.circle")
                    }
                }

                Section("Calories") {
                    if let nutritionSummary {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                if let caloriesPerServing = nutritionSummary.caloriesPerServing {
                                    Text("\(Int(caloriesPerServing.rounded())) calories per serving")
                                        .font(.headline)
                                } else if let totalCalories = nutritionSummary.totalCalories {
                                    Text("\(Int(totalCalories.rounded())) calories total")
                                        .font(.headline)
                                } else {
                                    Text("No calorie estimate yet")
                                        .font(.headline)
                                }

                                Text(nutritionSummary.statusLabel)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isEstimatingNutrition {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Text("\(nutritionSummary.matchedIngredientCount) matched • \(nutritionSummary.unmatchedIngredientCount) unmatched")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if !nutritionSummary.unmatchedIngredients.isEmpty {
                            ForEach(nutritionSummary.unmatchedIngredients, id: \.self) { ingredient in
                                Button {
                                    presentNutritionMatcher(for: ingredient)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(ingredient)
                                                .foregroundStyle(.primary)
                                            Text("Match this ingredient to improve the estimate")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.footnote)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if isEstimatingNutrition {
                        ProgressView("Calculating calories…")
                    } else {
                        Text("Calories update from the current ingredient list and servings.")
                            .foregroundStyle(.secondary)
                    }

                    if let nutritionEstimateError {
                        Text(nutritionEstimateError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Instructions") {
                    if draft.steps.isEmpty {
                        Text("Add main steps, then add optional lettered substeps underneath.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach($draft.steps) { $step in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Step \(step.sortOrder)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Up") { moveStep(step.id, direction: -1) }
                                    .disabled(step.sortOrder == 1)
                                Button("Down") { moveStep(step.id, direction: 1) }
                                    .disabled(step.sortOrder == draft.steps.count)
                            }

                            TextField("Main instruction", text: $step.instruction, axis: .vertical)

                            if !step.substeps.isEmpty {
                                ForEach($step.substeps) { $substep in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(substepLabel(for: substep.sortOrder))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button("Up") { moveSubstep(stepID: step.id, substepID: substep.id, direction: -1) }
                                                .disabled(substep.sortOrder == 1)
                                            Button("Down") { moveSubstep(stepID: step.id, substepID: substep.id, direction: 1) }
                                                .disabled(substep.sortOrder == step.substeps.count)
                                        }

                                        TextField("Optional substep", text: $substep.instruction, axis: .vertical)
                                            .padding(.leading, 12)

                                        HStack {
                                            Spacer()
                                            Button("Remove substep", role: .destructive) {
                                                removeSubstep(stepID: step.id, substepID: substep.id)
                                            }
                                            .font(.footnote)
                                        }
                                    }
                                }
                            }

                            HStack {
                                Button {
                                    addSubstep(to: step.id)
                                } label: {
                                    Label("Add substep", systemImage: "plus.circle")
                                }

                                Spacer()

                                Button("Remove step", role: .destructive) {
                                    removeStep(step.id)
                                }
                                .font(.footnote)
                            }
                        }
                        .padding(.vertical, 6)
                    }

                    Button {
                        addStep()
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                    }
                }

                Section("Details") {
                    LabeledContent("Notes") {
                        TextField("Anything that matters while cooking", text: $draft.notes, axis: .vertical)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Memories") {
                        TextField("Why this recipe matters to your family", text: $draft.memories, axis: .vertical)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Source label") {
                        TextField("Serious Eats", text: $draft.sourceLabel)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Source URL") {
                        TextField("https://example.com/recipe", text: $draft.sourceUrl)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await saveRecipe() }
                    }
                    .disabled(isSaving || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                if appState.recipeMetadata == nil {
                    await appState.refreshRecipeMetadata()
                }
                await refreshNutritionEstimate(force: true)
            }
            .task(id: nutritionEstimateSignature) {
                await refreshNutritionEstimate()
            }
            .sheet(item: $nutritionMatchContext) { context in
                RecipeNutritionMatchView(context: context) {
                    Task {
                        await refreshNutritionEstimate(force: true)
                    }
                }
            }
            .sheet(item: $ingredientResolutionContext) { context in
                IngredientResolutionSheet(ingredient: context.ingredient) { updatedIngredient in
                    replaceIngredient(id: context.ingredientID, with: updatedIngredient)
                }
            }
            .alert(
                pendingManagedField?.title ?? "",
                isPresented: Binding(
                    get: { pendingManagedField != nil },
                    set: { presented in
                        if !presented {
                            pendingManagedField = nil
                            pendingManagedValue = ""
                            pendingUnitIngredientID = nil
                        }
                    }
                )
            ) {
                TextField(pendingManagedField?.placeholder ?? "", text: $pendingManagedValue)
                Button("Cancel", role: .cancel) {
                    pendingManagedField = nil
                    pendingManagedValue = ""
                    pendingUnitIngredientID = nil
                }
                Button(isCreatingManagedValue ? "Saving…" : "Save") {
                    Task { await createManagedValue() }
                }
                .disabled(isCreatingManagedValue || pendingManagedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("This adds the option to the shared recipe list so it can be reused everywhere.")
            }
        }
    }

    private var availableTags: [String] {
        let selected = Set(draft.tags.map { $0.lowercased() })
        return (appState.recipeMetadata?.tags ?? [])
            .map(\.name)
            .filter { !selected.contains($0.lowercased()) }
    }

    private var nutritionEstimateSignature: String {
        let ingredientsSignature = draft.ingredients.map {
            [
                $0.ingredientName,
                $0.normalizedName ?? "",
                $0.quantity.map { "\($0)" } ?? "",
                $0.unit,
            ].joined(separator: "|")
        }
        .joined(separator: "||")
        return [servingsText, ingredientsSignature].joined(separator: "::")
    }

    private func addIngredient() {
        draft.ingredients.append(
            RecipeIngredient(
                ingredientId: UUID().uuidString,
                ingredientName: "",
                normalizedName: nil,
                quantity: nil,
                unit: "",
                prep: "",
                category: "",
                notes: ""
            )
        )
    }

    private func removeIngredient(_ ingredientID: String) {
        draft.ingredients.removeAll { $0.id == ingredientID }
    }

    private func replaceIngredient(id ingredientID: String, with updatedIngredient: RecipeIngredient) {
        guard let index = draft.ingredients.firstIndex(where: { $0.id == ingredientID }) else { return }
        var ingredient = updatedIngredient
        ingredient.ingredientId = draft.ingredients[index].ingredientId
        draft.ingredients[index] = ingredient
    }

    private func addTag(_ tag: String) {
        guard !draft.tags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) else {
            return
        }
        draft.tags.append(tag)
        draft.tags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func removeTag(_ tag: String) {
        draft.tags.removeAll { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }
    }

    private func addStep() {
        draft.steps.append(
            RecipeStep(
                stepId: UUID().uuidString,
                sortOrder: draft.steps.count + 1,
                instruction: "",
                substeps: []
            )
        )
    }

    private func removeStep(_ stepID: String) {
        draft.steps.removeAll { $0.id == stepID }
        normalizeSteps()
    }

    private func moveStep(_ stepID: String, direction: Int) {
        guard let index = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
        let destination = index + direction
        guard draft.steps.indices.contains(destination) else { return }
        draft.steps.swapAt(index, destination)
        normalizeSteps()
    }

    private func addSubstep(to stepID: String) {
        guard let index = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
        draft.steps[index].substeps.append(
            RecipeStep(
                stepId: UUID().uuidString,
                sortOrder: draft.steps[index].substeps.count + 1,
                instruction: ""
            )
        )
    }

    private func removeSubstep(stepID: String, substepID: String) {
        guard let index = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
        draft.steps[index].substeps.removeAll { $0.id == substepID }
        normalizeSubsteps(for: index)
    }

    private func moveSubstep(stepID: String, substepID: String, direction: Int) {
        guard let stepIndex = draft.steps.firstIndex(where: { $0.id == stepID }) else { return }
        guard let substepIndex = draft.steps[stepIndex].substeps.firstIndex(where: { $0.id == substepID }) else { return }
        let destination = substepIndex + direction
        guard draft.steps[stepIndex].substeps.indices.contains(destination) else { return }
        draft.steps[stepIndex].substeps.swapAt(substepIndex, destination)
        normalizeSubsteps(for: stepIndex)
    }

    private func normalizeSteps() {
        draft.steps = draft.steps.enumerated().map { index, step in
            var updated = step
            updated.sortOrder = index + 1
            updated.substeps = updated.substeps.enumerated().map { subIndex, substep in
                var updatedSubstep = substep
                updatedSubstep.sortOrder = subIndex + 1
                return updatedSubstep
            }
            return updated
        }
    }

    private func normalizeSubsteps(for stepIndex: Int) {
        draft.steps[stepIndex].substeps = draft.steps[stepIndex].substeps.enumerated().map { index, substep in
            var updated = substep
            updated.sortOrder = index + 1
            return updated
        }
    }

    private func binding(for quantity: Binding<Double?>) -> Binding<String> {
        Binding(
            get: {
                quantity.wrappedValue.map { $0.formatted() } ?? ""
            },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                quantity.wrappedValue = trimmed.isEmpty ? nil : Double(trimmed)
            }
        )
    }

    private func substepLabel(for sortOrder: Int) -> String {
        let scalar = UnicodeScalar(UInt32(96 + max(sortOrder, 1))) ?? UnicodeScalar(97)!
        return String(Character(scalar))
    }

    private func createManagedValue() async {
        guard let pendingManagedField else { return }
        isCreatingManagedValue = true
        errorMessage = nil
        let value = pendingManagedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { isCreatingManagedValue = false }

        do {
            let created = try await appState.createManagedListItem(kind: pendingManagedField.kind, name: value)
            switch pendingManagedField {
            case .cuisine:
                draft.cuisine = created.name
            case .tag:
                addTag(created.name)
            case .unit:
                if let ingredientID = pendingUnitIngredientID,
                   let index = draft.ingredients.firstIndex(where: { $0.id == ingredientID }) {
                    draft.ingredients[index].unit = created.name
                }
            }
            self.pendingManagedField = nil
            pendingManagedValue = ""
            pendingUnitIngredientID = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveRecipe() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let prepared = preparedDraft()

        do {
            let saved = try await appState.saveRecipe(prepared)
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func preparedDraft() -> RecipeDraft {
        var prepared = draft
        prepared.name = prepared.name.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.cuisine = prepared.cuisine.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.sourceLabel = prepared.sourceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.sourceUrl = prepared.sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.servings = Double(servingsText.trimmingCharacters(in: .whitespacesAndNewlines))
        prepared.prepMinutes = Int(prepMinutesText.trimmingCharacters(in: .whitespacesAndNewlines))
        prepared.cookMinutes = Int(cookMinutesText.trimmingCharacters(in: .whitespacesAndNewlines))
        prepared.tags = prepared.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        prepared.ingredients = prepared.ingredients.compactMap { ingredient in
            let name = ingredient.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            var updated = ingredient
            updated.ingredientName = name
            updated.unit = ingredient.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.prep = ingredient.prep.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.category = ingredient.category.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.notes = ingredient.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return updated
        }
        prepared.steps = prepared.steps.compactMap { step in
            let instruction = step.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !instruction.isEmpty else { return nil }
            var updated = step
            updated.instruction = instruction
            updated.substeps = step.substeps.compactMap { substep in
                let subInstruction = substep.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !subInstruction.isEmpty else { return nil }
                var updatedSubstep = substep
                updatedSubstep.instruction = subInstruction
                return updatedSubstep
            }
            return updated
        }
        prepared.steps = prepared.steps.enumerated().map { index, step in
            var updated = step
            updated.sortOrder = index + 1
            updated.substeps = step.substeps.enumerated().map { subIndex, substep in
                var updatedSubstep = substep
                updatedSubstep.sortOrder = subIndex + 1
                return updatedSubstep
            }
            return updated
        }
        if !prepared.steps.isEmpty {
            prepared.instructionsSummary = prepared.steps
                .sorted { $0.sortOrder < $1.sortOrder }
                .flatMap { step -> [String] in
                    let main = "\(step.sortOrder). \(step.instruction)"
                    let substeps = step.substeps
                        .sorted { $0.sortOrder < $1.sortOrder }
                        .map { "   \(substepLabel(for: $0.sortOrder)). \($0.instruction)" }
                    return [main] + substeps
                }
                .joined(separator: "\n")
        } else {
            prepared.instructionsSummary = prepared.instructionsSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        prepared.nutritionSummary = nutritionSummary
        return prepared
    }

    private func refreshNutritionEstimate(force: Bool = false) async {
        let estimateDraft = preparedDraft()
        let hasNamedIngredients = estimateDraft.ingredients.contains {
            !$0.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasNamedIngredients else {
            nutritionSummary = nil
            nutritionEstimateError = nil
            return
        }
        if !force {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
        }
        do {
            isEstimatingNutrition = true
            nutritionSummary = try await appState.estimateRecipeNutrition(estimateDraft)
            nutritionEstimateError = nil
        } catch {
            nutritionEstimateError = error.localizedDescription
        }
        isEstimatingNutrition = false
    }

    private func presentNutritionMatcher(for ingredientName: String) {
        let ingredient = draft.ingredients.first {
            $0.ingredientName.localizedCaseInsensitiveCompare(ingredientName) == .orderedSame
        }
        nutritionMatchContext = RecipeNutritionMatchContext(
            ingredientName: ingredientName,
            normalizedName: ingredient?.normalizedName
        )
    }
}
