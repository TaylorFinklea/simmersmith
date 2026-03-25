import SwiftUI
import SimmerSmithKit

struct RecipeDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let recipeID: String

    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var editorContext: RecipeEditorSheetContext?
    @State private var assignmentContext: RecipeAssignmentSheetContext?
    @State private var nutritionMatchContext: RecipeNutritionMatchContext?
    @State private var pendingDelete = false
    @State private var selectedScale: RecipeScaleOption = .single
    @State private var isGeneratingVariation = false

    var body: some View {
        Group {
            if let recipe {
                List {
                    summarySection(recipe)

                    if isGeneratingVariation {
                        Section {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Generating AI variation draft…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Scale") {
                        Picker("Scale", selection: $selectedScale) {
                            ForEach(RecipeScaleOption.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if let nutritionSummary = recipe.nutritionSummary {
                        Section("Calories") {
                            VStack(alignment: .leading, spacing: 6) {
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
                                Text("\(nutritionSummary.matchedIngredientCount) matched • \(nutritionSummary.unmatchedIngredientCount) unmatched")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            if !nutritionSummary.unmatchedIngredients.isEmpty {
                                ForEach(nutritionSummary.unmatchedIngredients, id: \.self) { ingredient in
                                    Button {
                                        let normalizedName = recipe.ingredients.first {
                                            $0.ingredientName.localizedCaseInsensitiveCompare(ingredient) == .orderedSame
                                        }?.normalizedName
                                        nutritionMatchContext = RecipeNutritionMatchContext(
                                            ingredientName: ingredient,
                                            normalizedName: normalizedName
                                        )
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(ingredient)
                                                    .foregroundStyle(.primary)
                                                Text("Match nutrition to improve this estimate")
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
                        }
                    }

                    if !variantRecipes(for: recipe).isEmpty {
                        Section("Variations") {
                            ForEach(variantRecipes(for: recipe)) { variant in
                                NavigationLink {
                                    RecipeDetailView(recipeID: variant.recipeId)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(variant.name)
                                        Text(variant.usageSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if !recipe.ingredients.isEmpty {
                        Section("Ingredients") {
                            ForEach(recipe.ingredients.map { $0.scaled(by: selectedScale.rawValue) }) { ingredient in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ingredient.ingredientName)
                                    Text(ingredientLine(for: ingredient))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if !recipe.steps.isEmpty {
                        Section("Steps") {
                            ForEach(recipe.steps.sorted(by: { $0.sortOrder < $1.sortOrder })) { step in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Step \(step.sortOrder)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(step.instruction)
                                    ForEach(step.substeps.sorted(by: { $0.sortOrder < $1.sortOrder })) { substep in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("\(substepMarker(for: substep.sortOrder)).")
                                                .foregroundStyle(.secondary)
                                            Text(substep.instruction)
                                        }
                                        .font(.footnote)
                                        .padding(.leading, 12)
                                    }
                                }
                            }
                        }
                    } else if !recipe.instructionsSummary.isEmpty {
                        Section("Instructions") {
                            Text(recipe.instructionsSummary)
                        }
                    }

                    if !recipe.notes.isEmpty {
                        Section("Notes") {
                            Text(recipe.notes)
                        }
                    }

                    if !recipe.memories.isEmpty {
                        Section("Memories") {
                            Text(recipe.memories)
                        }
                    }

                    if !recipe.sourceLabel.isEmpty || !recipe.sourceUrl.isEmpty || recipe.sourceRecipeCount > 0 {
                        Section("Source") {
                            if !recipe.sourceLabel.isEmpty {
                                Text(recipe.sourceLabel)
                            }
                            if recipe.sourceRecipeCount > 0 {
                                Text("\(recipe.sourceRecipeCount) recipes from this source")
                                    .foregroundStyle(.secondary)
                            }
                            if let url = URL(string: recipe.sourceUrl), !recipe.sourceUrl.isEmpty {
                                Link(destination: url) {
                                    Label("Open original recipe", systemImage: "safari")
                                }
                            }
                        }
                    }

                    if let errorMessage {
                        Section {
                            Text(errorMessage)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else if isLoading {
                ProgressView("Loading recipe…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Recipe Unavailable",
                    systemImage: "book.closed",
                    description: Text(errorMessage ?? "The recipe could not be loaded.")
                )
            }
        }
        .navigationTitle(recipe?.name ?? "Recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let recipe {
                    Menu("Actions") {
                        Button("Edit") {
                            editorContext = RecipeEditorSheetContext(title: "Edit Recipe", draft: recipe.editingDraft())
                        }
                        Button("Create Variation") {
                            editorContext = RecipeEditorSheetContext(title: "New Variation", draft: recipe.variationDraft())
                        }
                        Menu("AI Variation Draft") {
                            ForEach(RecipeVariationGoal.allCases) { goal in
                                Button(goal.title) {
                                    Task { await generateVariation(recipe, goal: goal) }
                                }
                                .disabled(isGeneratingVariation)
                            }
                        }
                        Button("Add to Week") {
                            assignmentContext = RecipeAssignmentSheetContext(recipes: [recipe])
                        }
                        Divider()
                        if recipe.archived {
                            Button("Restore") {
                                Task { await restore(recipe) }
                            }
                        } else {
                            Button("Archive") {
                                Task { await archive(recipe) }
                            }
                        }
                        Button("Delete", role: .destructive) {
                            pendingDelete = true
                        }
                    }
                }
            }
        }
        .task(id: recipeID) {
            await loadRecipe()
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { _ in
                Task { await loadRecipe(forceRefresh: true) }
            }
        }
        .sheet(item: $assignmentContext) { context in
            RecipeWeekAssignmentView(recipes: context.recipes)
        }
        .sheet(item: $nutritionMatchContext) { context in
            RecipeNutritionMatchView(context: context) {
                Task { await loadRecipe(forceRefresh: true) }
            }
        }
        .confirmationDialog(
            "Delete this recipe?",
            isPresented: $pendingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let recipe {
                    Task { await delete(recipe) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the recipe from the library. Existing week meals keep their copied names and ingredients.")
        }
    }

    private var recipe: RecipeSummary? {
        appState.recipes.first { $0.recipeId == recipeID }
    }

    private func summarySection(_ recipe: RecipeSummary) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text(recipe.name)
                        .font(.title3.bold())
                    if recipe.favorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.pink)
                    }
                }

                if !recipe.subtitleFragments.isEmpty {
                    Text(recipe.subtitleFragments.joined(separator: " • "))
                        .foregroundStyle(.secondary)
                }

                if let calorieSummaryLine = recipe.calorieSummaryLine {
                    Label(calorieSummaryLine, systemImage: "flame.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Label(recipe.usageSummary, systemImage: "clock.arrow.circlepath")
                    Spacer()
                    if recipe.archived {
                        Label("Archived", systemImage: "archivebox")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if !recipe.overrideFields.isEmpty {
                    Text("Overrides: \(recipe.overrideFields.joined(separator: ", "))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !recipe.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recipe.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.thinMaterial, in: Capsule())
                            }
                        }
                    }
                }

                HStack {
                    if let servings = recipe.servings {
                        Label("\(servings.formatted()) servings", systemImage: "person.2")
                    }
                    if let prepMinutes = recipe.prepMinutes {
                        Label("\(prepMinutes)m prep", systemImage: "timer")
                    }
                    if let cookMinutes = recipe.cookMinutes {
                        Label("\(cookMinutes)m cook", systemImage: "flame")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    private func ingredientLine(for ingredient: RecipeIngredient) -> String {
        [
            ingredient.quantity.map { $0.formatted() },
            ingredient.unit.isEmpty ? nil : ingredient.unit,
            ingredient.prep.isEmpty ? nil : ingredient.prep,
            ingredient.category.isEmpty ? nil : ingredient.category,
        ]
        .compactMap { $0 }
        .joined(separator: " • ")
    }

    private func variantRecipes(for recipe: RecipeSummary) -> [RecipeSummary] {
        let rootID = recipe.baseRecipeId ?? recipe.recipeId
        return appState.recipes
            .filter { $0.baseRecipeId == rootID && $0.recipeId != recipe.recipeId && !$0.archived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func substepMarker(for index: Int) -> String {
        let base = UnicodeScalar(UInt32(96 + max(index, 1))) ?? UnicodeScalar(97)!
        return String(Character(base))
    }

    private func loadRecipe(forceRefresh: Bool = false) async {
        if !forceRefresh, recipe != nil {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            _ = try await appState.fetchRecipe(recipeID: recipeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func archive(_ recipe: RecipeSummary) async {
        do {
            try await appState.archiveRecipe(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateVariation(_ recipe: RecipeSummary, goal: RecipeVariationGoal) async {
        isGeneratingVariation = true
        defer { isGeneratingVariation = false }

        do {
            let aiDraft = try await appState.generateRecipeVariationDraft(recipeID: recipe.recipeId, goal: goal.title)
            editorContext = RecipeEditorSheetContext(
                title: "\(aiDraft.goal) Draft",
                draft: aiDraft.draft
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ recipe: RecipeSummary) async {
        do {
            try await appState.restoreRecipe(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ recipe: RecipeSummary) async {
        do {
            try await appState.deleteRecipe(recipe)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
