import Foundation

// SP-C AI-1 — Week-gen planning context (pure, headless-testable).
//
// Swift port of the `PlanningContext` / `DietaryGoalContext` dataclasses in
// `app/services/week_planner.py`. These are the prompt-enrichment inputs the
// app-layer gather assembles from CloudKit + the private plane (pantry staples,
// dietary goal, ingredient preferences, recent meals) and hands to
// `WeekGenPrompt`. Kept dependency-free (no SimmerSmithKit / CloudKit) so the
// whole prompt-builder + parser + allergy-gate unit-tests in this package.

/// Snapshot of a user's daily calorie + macro target.
/// Mirrors `week_planner.DietaryGoalContext`.
public struct DietaryGoalContext: Sendable, Equatable {
    public var goalType: String
    public var dailyCalories: Int
    public var proteinG: Int
    public var carbsG: Int
    public var fatG: Int
    public var fiberG: Int?
    public var notes: String

    public init(
        goalType: String = "maintain",
        dailyCalories: Int = 0,
        proteinG: Int = 0,
        carbsG: Int = 0,
        fatG: Int = 0,
        fiberG: Int? = nil,
        notes: String = ""
    ) {
        self.goalType = goalType
        self.dailyCalories = dailyCalories
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.fiberG = fiberG
        self.notes = notes
    }
}

/// Structured context gathered from the data plane for prompt enrichment.
/// Mirrors `week_planner.PlanningContext` field-for-field. The app-layer gather
/// fills these from the new CloudKit/private-plane stores (NOT Fly); every field
/// degrades gracefully on empties (the server handled empties — so does the port).
public struct PlanningContext: Sendable, Equatable {
    public var hardAvoids: [String]
    public var strongLikes: [String]
    public var likedCuisines: [String]
    public var dislikedCuisines: [String]
    public var brands: [String]
    public var staples: [String]
    public var recentMeals: [String]
    public var rules: [String]
    public var dietaryGoal: DietaryGoalContext?
    /// Catalog-level ingredient allergies (`IngredientPreference.choiceMode == "allergy"`).
    /// Surfaced as a separate, more-emphasized prompt line than regular avoids — and
    /// the source of truth for the allergy hard-gate (`MealPlanParser.enforceAllergyGate`).
    public var allergies: [String]
    /// Household shorthand aliases (e.g. "chx" → "chicken"). Injected as a preamble
    /// so the AI treats the term as if the user typed the expansion.
    public var termAliases: [String: String]

    public init(
        hardAvoids: [String] = [],
        strongLikes: [String] = [],
        likedCuisines: [String] = [],
        dislikedCuisines: [String] = [],
        brands: [String] = [],
        staples: [String] = [],
        recentMeals: [String] = [],
        rules: [String] = [],
        dietaryGoal: DietaryGoalContext? = nil,
        allergies: [String] = [],
        termAliases: [String: String] = [:]
    ) {
        self.hardAvoids = hardAvoids
        self.strongLikes = strongLikes
        self.likedCuisines = likedCuisines
        self.dislikedCuisines = dislikedCuisines
        self.brands = brands
        self.staples = staples
        self.recentMeals = recentMeals
        self.rules = rules
        self.dietaryGoal = dietaryGoal
        self.allergies = allergies
        self.termAliases = termAliases
    }
}

/// The unit system the AI must lock recipes to. Mirrors `ai.unit_system(...)`.
public enum UnitSystem: String, Sendable, Equatable {
    case us
    case metric

    /// Normalize a raw `unit_system` profile setting. Empty / unrecognized → `.us`
    /// (legacy users with no setting keep the original behavior). Mirrors
    /// `ai.unit_system`.
    public static func normalized(_ raw: String?) -> UnitSystem {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "metric" ? .metric : .us
    }
}
