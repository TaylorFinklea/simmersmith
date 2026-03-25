import Foundation
import SimmerSmithKit

struct RecipeEditorSheetContext: Identifiable {
    let id = UUID()
    let title: String
    let draft: RecipeDraft
}

struct RecipeAssignmentSheetContext: Identifiable {
    let id = UUID()
    let recipes: [RecipeSummary]
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
