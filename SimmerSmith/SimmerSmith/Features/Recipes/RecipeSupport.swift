import Foundation
import SimmerSmithKit
import SwiftUI

struct RecipeEditorSheetContext: Identifiable {
    let id = UUID()
    let title: String
    let draft: RecipeDraft
}

struct RecipeAssignmentSheetContext: Identifiable {
    let id = UUID()
    let recipes: [RecipeSummary]
}

struct RecipeCompanionSheetContext: Identifiable {
    let id = UUID()
    let title: String
    let options: RecipeAIOptions
}

enum RecipeMealFilter: String, CaseIterable, Identifiable {
    case dinner
    case breakfast
    case lunch
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dinner:
            "Dinner"
        case .breakfast:
            "Breakfast"
        case .lunch:
            "Lunch"
        case .all:
            "All"
        }
    }

    func matches(_ recipe: RecipeSummary) -> Bool {
        guard self != .all else { return true }
        return recipe.mealType.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(rawValue) == .orderedSame
    }
}

enum RecipeSortOption: String, CaseIterable, Identifiable {
    case lastUsed
    case favorites
    case cuisine
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastUsed:
            "Last Used"
        case .favorites:
            "Favorites"
        case .cuisine:
            "Cuisine"
        case .name:
            "Name"
        }
    }
}

enum RecipeScaleOption: Double, CaseIterable, Identifiable {
    case quarter = 0.25
    case half = 0.5
    case single = 1.0
    case double = 2.0
    case fourX = 4.0

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .quarter:
            "1/4"
        case .half:
            "1/2"
        case .single:
            "1x"
        case .double:
            "2x"
        case .fourX:
            "4x"
        }
    }

    static func closest(to value: Double) -> RecipeScaleOption {
        allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .single
    }
}

enum MealSlotOption: String, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    var title: String { rawValue.capitalized }
}

enum RecipeVariationGoal: String, CaseIterable, Identifiable {
    case lowCarb = "Low-Carb"
    case dairyFree = "Dairy-Free"
    case glutenFree = "Gluten-Free"
    case vegetarian = "Vegetarian"
    case kidFriendly = "Kid-Friendly"
    case pantryFriendly = "Pantry-Friendly"

    var id: String { rawValue }

    var title: String { rawValue }
}

enum RecipeSuggestionGoal: String, CaseIterable, Identifiable {
    case weeknightDinner = "Weeknight Dinner"
    case breakfastRotation = "Breakfast Rotation"
    case lunchboxFriendly = "Lunchbox Friendly"
    case pantryReset = "Pantry Reset"
    case kidFriendlyDinner = "Kid-Friendly Dinner"

    var id: String { rawValue }

    var title: String { rawValue }
}

extension RecipeSummary {
    func editingDraft() -> RecipeDraft {
        RecipeDraft(
            recipeId: recipeId,
            baseRecipeId: baseRecipeId,
            name: name,
            mealType: mealType,
            cuisine: cuisine,
            servings: servings,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            tags: tags,
            instructionsSummary: instructionsSummary,
            favorite: favorite,
            source: source,
            sourceLabel: sourceLabel,
            sourceUrl: sourceUrl,
            notes: notes,
            memories: memories,
            lastUsed: lastUsed,
            ingredients: ingredients,
            steps: steps,
            nutritionSummary: nutritionSummary
        )
    }

    func variationDraft() -> RecipeDraft {
        RecipeDraft(
            recipeId: nil,
            baseRecipeId: baseRecipeId ?? recipeId,
            name: isVariant ? name : "\(name) Variation",
            mealType: mealType,
            cuisine: cuisine,
            servings: servings,
            prepMinutes: prepMinutes,
            cookMinutes: cookMinutes,
            tags: tags,
            instructionsSummary: instructionsSummary,
            favorite: favorite,
            source: source,
            sourceLabel: sourceLabel,
            sourceUrl: sourceUrl,
            notes: notes,
            memories: memories,
            lastUsed: nil,
            ingredients: ingredients,
            steps: steps,
            nutritionSummary: nutritionSummary
        )
    }

    var sortRecencyBucket: Int {
        if let daysSinceLastUsed {
            return daysSinceLastUsed
        }
        return Int.max
    }

    var sortFavoriteBucket: Int {
        favorite ? 0 : 1
    }

    var usageSummary: String {
        if let daysSinceLastUsed {
            if daysSinceLastUsed == 0 {
                return "Used this week"
            }
            if daysSinceLastUsed == 1 {
                return "Used 1 day ago"
            }
            return "Used \(daysSinceLastUsed) days ago"
        }
        if let familyDaysSinceLastUsed {
            if familyDaysSinceLastUsed == 0 {
                return "Family used this week"
            }
            return "Family used \(familyDaysSinceLastUsed) days ago"
        }
        return "Not used yet"
    }

    var subtitleFragments: [String] {
        [mealType.capitalized, cuisine, sourceLabel]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var tagSummary: String {
        tags.joined(separator: " • ")
    }

    var calorieSummaryLine: String? {
        guard let nutritionSummary else { return nil }
        if let caloriesPerServing = nutritionSummary.caloriesPerServing {
            return "\(Int(caloriesPerServing.rounded())) cal/serving"
        }
        if let totalCalories = nutritionSummary.totalCalories {
            return "\(Int(totalCalories.rounded())) cal total"
        }
        return nil
    }
}

extension WeekMeal {
    func asMealUpdateRequest() -> MealUpdateRequest {
        MealUpdateRequest(
            mealId: mealId,
            dayName: dayName,
            mealDate: mealDate,
            slot: slot,
            recipeId: recipeId,
            recipeName: recipeName,
            servings: servings,
            scaleMultiplier: scaleMultiplier,
            notes: notes,
            approved: approved
        )
    }
}

extension RecipeIngredient {
    func scaled(by multiplier: Double) -> RecipeIngredient {
        guard let quantity else { return self }
        var copy = self
        copy.quantity = quantity * multiplier
        return copy
    }
}

func defaultMealSlot(for mealType: String) -> MealSlotOption {
    switch mealType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "breakfast":
        .breakfast
    case "lunch":
        .lunch
    case "snack":
        .snack
    default:
        .dinner
    }
}

extension NutritionSummary {
    var statusLabel: String {
        switch coverageStatus {
        case "complete":
            return "Complete estimate"
        case "partial":
            return "Partial estimate"
        default:
            return "No estimate yet"
        }
    }
}

private struct IngredientReviewRecipeGroup: Identifiable {
    let recipe: RecipeSummary
    let ingredients: [RecipeIngredient]

    var id: String { recipe.recipeId }
}

struct IngredientReviewQueueView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var editorContext: RecipeEditorSheetContext?
    @State private var preferenceEditor: IngredientPreferenceEditorContext?
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            Group {
                if recipeGroupsNeedingReview.isEmpty && groceryItemsNeedingReview.isEmpty {
                    ContentUnavailableView(
                        "No Ingredient Review Needed",
                        systemImage: "checkmark.circle",
                        description: Text("Imported recipe ingredients and grocery items that need follow-up will appear here.")
                    )
                } else {
                    List {
                        if !recipeGroupsNeedingReview.isEmpty {
                            Section("Recipes Needing Review") {
                                ForEach(recipeGroupsNeedingReview) { group in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(group.recipe.name)
                                                    .font(.headline)
                                                Text("\(group.ingredients.count) ingredient\(group.ingredients.count == 1 ? "" : "s") need review")
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Button("Open Recipe") {
                                                editorContext = RecipeEditorSheetContext(
                                                    title: group.recipe.name,
                                                    draft: group.recipe.editingDraft()
                                                )
                                            }
                                            .buttonStyle(.bordered)
                                        }

                                        ForEach(group.ingredients, id: \.ingredientId) { ingredient in
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 8) {
                                                    IngredientReviewStatusBadge(status: ingredient.resolutionStatus)
                                                    Text(ingredient.ingredientName)
                                                        .font(.subheadline.weight(.medium))
                                                }
                                                if let baseIngredientName = ingredient.baseIngredientName, !baseIngredientName.isEmpty {
                                                    Text(baseIngredientName)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                } else {
                                                    Text("No canonical ingredient selected yet")
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            .padding(.leading, 2)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        if !groceryItemsNeedingReview.isEmpty {
                            Section("Grocery Items Needing Review") {
                                ForEach(groceryItemsNeedingReview) { item in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                HStack(spacing: 8) {
                                                    IngredientReviewStatusBadge(status: item.resolutionStatus)
                                                    Text(item.ingredientName)
                                                        .font(.headline)
                                                }
                                                if !item.sourceMeals.isEmpty {
                                                    Text(item.sourceMeals)
                                                        .font(.footnote)
                                                        .foregroundStyle(.secondary)
                                                }
                                                if !item.reviewFlag.isEmpty {
                                                    Label(item.reviewFlag, systemImage: "exclamationmark.circle")
                                                        .font(.caption)
                                                        .foregroundStyle(.orange)
                                                }
                                                if let baseIngredientName = item.baseIngredientName, !baseIngredientName.isEmpty {
                                                    Text(baseIngredientName)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                                if let variationName = item.ingredientVariationName, !variationName.isEmpty {
                                                    Text(variationName)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer()
                                        }

                                        if let context = preferenceContext(for: item) {
                                            Button("Set Preference") {
                                                preferenceEditor = context
                                            }
                                            .buttonStyle(.bordered)
                                        } else {
                                            Text("Resolve this ingredient in a recipe first before setting a household preference.")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Review Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshQueue() }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                if appState.recipes.isEmpty || appState.currentWeek == nil {
                    await refreshQueue()
                }
            }
        }
        .sheet(item: $editorContext) { context in
            RecipeEditorView(title: context.title, initialDraft: context.draft) { _ in
                Task {
                    await appState.refreshRecipes()
                    await appState.refreshWeek()
                }
            }
        }
        .sheet(item: $preferenceEditor) { context in
            IngredientPreferenceEditorSheet(context: context)
        }
    }

    private var recipeGroupsNeedingReview: [IngredientReviewRecipeGroup] {
        appState.recipes
            .map { recipe in
                IngredientReviewRecipeGroup(
                    recipe: recipe,
                    ingredients: recipe.ingredients.filter { ingredient in
                        ingredient.resolutionStatus == "unresolved" || ingredient.resolutionStatus == "suggested"
                    }
                )
            }
            .filter { !$0.ingredients.isEmpty }
            .sorted { $0.recipe.name.localizedCaseInsensitiveCompare($1.recipe.name) == .orderedAscending }
    }

    private var groceryItemsNeedingReview: [GroceryItem] {
        (appState.currentWeek?.groceryItems ?? [])
            .filter { item in
                !item.reviewFlag.isEmpty || item.resolutionStatus == "unresolved" || item.resolutionStatus == "suggested"
            }
            .sorted { $0.ingredientName.localizedCaseInsensitiveCompare($1.ingredientName) == .orderedAscending }
    }

    private func preferenceContext(for item: GroceryItem) -> IngredientPreferenceEditorContext? {
        if let existing = appState.ingredientPreferences.first(where: { $0.baseIngredientId == item.baseIngredientId }) {
            return IngredientPreferenceEditorContext(preference: existing)
        }
        guard let baseIngredientID = item.baseIngredientId,
              let baseIngredientName = item.baseIngredientName,
              !baseIngredientName.isEmpty else {
            return nil
        }
        return IngredientPreferenceEditorContext(
            seedBaseIngredientID: baseIngredientID,
            seedBaseIngredientName: baseIngredientName,
            seedPreferredVariationID: item.ingredientVariationId
        )
    }

    private func refreshQueue() async {
        isRefreshing = true
        await appState.refreshRecipes()
        await appState.refreshWeek()
        await appState.refreshIngredientPreferences()
        isRefreshing = false
    }
}

private struct IngredientReviewStatusBadge: View {
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
