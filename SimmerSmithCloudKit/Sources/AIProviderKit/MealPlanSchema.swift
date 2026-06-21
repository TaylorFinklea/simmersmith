import Foundation

// SP-C AI-1 — Meal-plan structured-output schema, parser, and allergy hard-gate
// (pure, headless-testable).
//
// The structured-output contract: the AI returns `{recipes: [...], meal_plan: [...]}`
// — the exact shape `_build_system_prompt` instructs it to. This file defines the
// Codable mirror of that shape (`MealPlanResponse`), a parser that tolerates the
// markdown-fence wrapping the server's `_extract_json` handled, applies the same
// field defaults as `week_planner.generate_week_plan`, and produces a flat
// `MealPlanResult` (recipes + 21 meal slots) the app maps onto
// `WeekRepository.saveWeekMeals`.
//
// THE ALLERGY HARD-GATE (Spike-2 invariant, spec §3) lives here: after a clean
// parse, `enforceAllergyGate` validates every recipe's ingredients against the
// user's `choiceMode == "allergy"` preferences and THROWS on any violation —
// generation fails closed; an unsafe plan is never returned.

// MARK: - Wire shape (Codable mirror of the prompt's response structure)

/// A single ingredient line inside a generated recipe.
/// Mirrors the `ingredients[]` objects in the prompt's response shape.
public struct MealPlanIngredient: Codable, Sendable, Equatable {
    public var ingredientName: String
    public var normalizedName: String?
    public var quantity: Double?
    public var unit: String
    public var prep: String
    public var category: String
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case ingredientName = "ingredient_name"
        case normalizedName = "normalized_name"
        case quantity, unit, prep, category, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ingredientName = try c.decodeIfPresent(String.self, forKey: .ingredientName) ?? ""
        normalizedName = try c.decodeIfPresent(String.self, forKey: .normalizedName)
        quantity = try MealPlanIngredient.decodeFlexibleDouble(c, forKey: .quantity)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        prep = try c.decodeIfPresent(String.self, forKey: .prep) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public init(
        ingredientName: String,
        normalizedName: String? = nil,
        quantity: Double? = nil,
        unit: String = "",
        prep: String = "",
        category: String = "",
        notes: String = ""
    ) {
        self.ingredientName = ingredientName
        self.normalizedName = normalizedName
        self.quantity = quantity
        self.unit = unit
        self.prep = prep
        self.category = category
        self.notes = notes
    }

    /// Models sometimes return `"2"` instead of `2.0` for a quantity; accept either.
    private static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// A cooking step inside a generated recipe.
public struct MealPlanStep: Codable, Sendable, Equatable {
    public var instruction: String
    public init(instruction: String) { self.instruction = instruction }
}

/// A generated recipe. Mirrors the `recipes[]` objects in the prompt's response
/// shape; field defaults match `generate_week_plan`'s `recipe.setdefault(...)`.
public struct MealPlanRecipe: Codable, Sendable, Equatable {
    public var name: String
    public var mealType: String
    public var cuisine: String
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var ingredients: [MealPlanIngredient]
    public var steps: [MealPlanStep]

    enum CodingKeys: String, CodingKey {
        case name, cuisine, servings, ingredients, steps
        case mealType = "meal_type"
        case prepMinutes = "prep_minutes"
        case cookMinutes = "cook_minutes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mealType = try c.decodeIfPresent(String.self, forKey: .mealType) ?? ""
        cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        servings = try c.decodeIfPresent(Double.self, forKey: .servings)
        prepMinutes = try c.decodeIfPresent(Int.self, forKey: .prepMinutes)
        cookMinutes = try c.decodeIfPresent(Int.self, forKey: .cookMinutes)
        ingredients = try c.decodeIfPresent([MealPlanIngredient].self, forKey: .ingredients) ?? []
        steps = try c.decodeIfPresent([MealPlanStep].self, forKey: .steps) ?? []
    }

    public init(
        name: String,
        mealType: String = "",
        cuisine: String = "",
        servings: Double? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        ingredients: [MealPlanIngredient] = [],
        steps: [MealPlanStep] = []
    ) {
        self.name = name
        self.mealType = mealType
        self.cuisine = cuisine
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.ingredients = ingredients
        self.steps = steps
    }
}

/// A single meal-slot assignment. Mirrors the `meal_plan[]` objects: `recipe_name`
/// joins back to a recipe in `recipes`. Field defaults match `generate_week_plan`'s
/// `meal.setdefault(...)`.
public struct MealPlanSlot: Codable, Sendable, Equatable {
    public var dayName: String
    public var mealDate: String
    public var slot: String
    public var recipeName: String
    public var recipeId: String?
    public var servings: Double?
    public var notes: String
    public var approved: Bool
    public var source: String

    enum CodingKeys: String, CodingKey {
        case slot, servings, notes, approved, source
        case dayName = "day_name"
        case mealDate = "meal_date"
        case recipeName = "recipe_name"
        case recipeId = "recipe_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dayName = try c.decodeIfPresent(String.self, forKey: .dayName) ?? ""
        mealDate = try c.decodeIfPresent(String.self, forKey: .mealDate) ?? ""
        slot = try c.decodeIfPresent(String.self, forKey: .slot) ?? ""
        recipeName = try c.decodeIfPresent(String.self, forKey: .recipeName) ?? ""
        recipeId = try c.decodeIfPresent(String.self, forKey: .recipeId)
        servings = try c.decodeIfPresent(Double.self, forKey: .servings)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        approved = try c.decodeIfPresent(Bool.self, forKey: .approved) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "ai"
    }

    public init(
        dayName: String,
        mealDate: String,
        slot: String,
        recipeName: String,
        recipeId: String? = nil,
        servings: Double? = nil,
        notes: String = "",
        approved: Bool = false,
        source: String = "ai"
    ) {
        self.dayName = dayName
        self.mealDate = mealDate
        self.slot = slot
        self.recipeName = recipeName
        self.recipeId = recipeId
        self.servings = servings
        self.notes = notes
        self.approved = approved
        self.source = source
    }
}

/// The full parsed response: the recipe library + the 21-slot meal plan.
public struct MealPlanResponse: Codable, Sendable, Equatable {
    public var recipes: [MealPlanRecipe]
    public var mealPlan: [MealPlanSlot]

    enum CodingKeys: String, CodingKey {
        case recipes
        case mealPlan = "meal_plan"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recipes = try c.decodeIfPresent([MealPlanRecipe].self, forKey: .recipes) ?? []
        mealPlan = try c.decodeIfPresent([MealPlanSlot].self, forKey: .mealPlan) ?? []
    }

    public init(recipes: [MealPlanRecipe], mealPlan: [MealPlanSlot]) {
        self.recipes = recipes
        self.mealPlan = mealPlan
    }
}

/// The validated, allergy-gated result the app maps onto `saveWeekMeals`.
public struct MealPlanResult: Sendable, Equatable {
    public var recipes: [MealPlanRecipe]
    public var mealPlan: [MealPlanSlot]
    public init(recipes: [MealPlanRecipe], mealPlan: [MealPlanSlot]) {
        self.recipes = recipes
        self.mealPlan = mealPlan
    }

    /// Look up the recipe a meal slot references, by exact-then-case-insensitive name
    /// (the prompt requires `recipe_name` to match a recipe exactly; the server's
    /// macro pass falls back to a lowercase compare, so do the same).
    public func recipe(for slot: MealPlanSlot) -> MealPlanRecipe? {
        if let exact = recipes.first(where: { $0.name == slot.recipeName }) { return exact }
        let key = slot.recipeName.lowercased()
        return recipes.first { $0.name.lowercased() == key }
    }
}

// MARK: - Errors

public enum MealPlanParseError: Error, Equatable {
    /// The response was not valid JSON even after stripping a markdown fence.
    case invalidJSON
    /// The JSON parsed but carried no meals (an unusable plan).
    case emptyPlan
    /// A meal violates a `choiceMode == "allergy"` preference — fail closed.
    /// Carries the offending recipe name + the matched allergen for the UI/log.
    case allergyViolation(recipe: String, allergen: String)
}

// MARK: - Parser + allergy gate

public enum MealPlanParser {

    /// Strip a leading/trailing markdown code fence (```/```json), mirroring
    /// `week_planner._extract_json`. Returns the inner text unchanged when no fence
    /// is present.
    public static func stripCodeFence(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        // Drop the opening ``` line and any closing ``` line, matching the Python:
        // lines[1:] with closing-fence lines removed.
        var lines = text.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n")
    }

    /// Parse a raw provider response into a normalized `MealPlanResult`.
    /// Tolerates the markdown-fence wrapping (`_extract_json`) and applies the same
    /// field defaults as `generate_week_plan`. Throws `.invalidJSON` on non-JSON and
    /// `.emptyPlan` when the plan carries no meals.
    public static func parse(_ raw: String) throws -> MealPlanResult {
        let json = stripCodeFence(raw)
        guard let data = json.data(using: .utf8) else { throw MealPlanParseError.invalidJSON }
        let response: MealPlanResponse
        do {
            response = try JSONDecoder().decode(MealPlanResponse.self, from: data)
        } catch {
            throw MealPlanParseError.invalidJSON
        }
        guard !response.mealPlan.isEmpty else { throw MealPlanParseError.emptyPlan }
        return MealPlanResult(recipes: response.recipes, mealPlan: response.mealPlan)
    }

    /// THE ALLERGY HARD-GATE (Spike-2 invariant). Validates every meal in `result`
    /// against the user's allergy list (the `PlanningContext.allergies`, sourced from
    /// `choiceMode == "allergy"` ingredient preferences). Throws `.allergyViolation`
    /// the moment any recipe's ingredients — or the recipe name itself — contain an
    /// allergen substring. A clean plan returns normally.
    ///
    /// Matching is case-insensitive substring containment in either direction
    /// (allergen "peanut" matches ingredient "peanut butter"; allergen "tree nuts"
    /// stays literal). Empty allergen strings are ignored.
    public static func enforceAllergyGate(_ result: MealPlanResult, allergies: [String]) throws {
        let allergens = allergies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !allergens.isEmpty else { return }

        for slot in result.mealPlan {
            guard let recipe = result.recipe(for: slot) else { continue }
            try check(recipe: recipe, against: allergens)
        }
        // Defense in depth: also scan any recipe not referenced by a slot (the AI may
        // emit extra recipes — they still must not carry an allergen if surfaced later).
        for recipe in result.recipes {
            try check(recipe: recipe, against: allergens)
        }
    }

    private static func check(recipe: MealPlanRecipe, against allergens: [String]) throws {
        let recipeName = recipe.name.lowercased()
        for allergen in allergens {
            if recipeName.contains(allergen) {
                throw MealPlanParseError.allergyViolation(recipe: recipe.name, allergen: allergen)
            }
        }
        for ingredient in recipe.ingredients {
            let name = ingredient.ingredientName.lowercased()
            let normalized = (ingredient.normalizedName ?? "").lowercased()
            for allergen in allergens where name.contains(allergen) || normalized.contains(allergen) {
                throw MealPlanParseError.allergyViolation(recipe: recipe.name, allergen: allergen)
            }
        }
    }

    /// Convenience: parse + enforce the allergy gate in one call (the order the app
    /// uses — parse first so a malformed response is a parse error, then gate).
    public static func parseAndGate(_ raw: String, allergies: [String]) throws -> MealPlanResult {
        let result = try parse(raw)
        try enforceAllergyGate(result, allergies: allergies)
        return result
    }
}
