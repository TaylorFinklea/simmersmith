import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-1 — week-gen prompt port + structured parse + allergy hard-gate.
// Verifies fidelity to `app/services/week_planner.py` (prompt structure), the
// parser round-trip, and the Spike-2 allergy hard-gate (rejects a violating plan,
// passes a clean one).

// A fixed week-start: Monday 2026-06-22 (UTC). Day labels + example dates derive
// from this.
private func weekStart() -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 22
    c.hour = 0; c.minute = 0; c.second = 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

private func fixtureContext() -> PlanningContext {
    PlanningContext(
        hardAvoids: ["cilantro", "olives"],
        strongLikes: ["garlic", "lemon"],
        likedCuisines: ["Italian", "Thai"],
        dislikedCuisines: ["German"],
        brands: ["Rao's"],
        staples: ["olive oil", "salt", "rice"],
        recentMeals: ["Sheet Pan Chicken", "Tofu Stir Fry"],
        rules: [],
        dietaryGoal: DietaryGoalContext(
            goalType: "cut", dailyCalories: 2000, proteinG: 160,
            carbsG: 180, fatG: 60, fiberG: 30, notes: "high protein"
        ),
        allergies: ["peanut", "shellfish"],
        termAliases: ["chx": "chicken", "veg": "vegetables"]
    )
}

// MARK: - Prompt structure (fidelity to _build_system_prompt)

@Test("prompt embeds identity, units, profile, and the exact JSON response shape")
func promptCoreStructure() {
    let prompt = WeekGenPrompt.buildSystemPrompt(
        profileSettings: ["household_name": "The Smiths", "dietary_constraints": "no pork"],
        weekStart: weekStart(),
        context: nil,
        unitSystem: .us
    )
    #expect(prompt.hasPrefix("You are SimmerSmith, an AI meal planning assistant."))
    #expect(prompt.contains("UNIT SYSTEM — US CUSTOMARY ONLY"))
    // Title-cased profile labels in fixed order.
    #expect(prompt.contains("- Household Name: The Smiths"))
    #expect(prompt.contains("- Dietary Constraints: no pork"))
    // Response-shape contract.
    #expect(prompt.contains("\"recipes\": ["))
    #expect(prompt.contains("\"meal_plan\": ["))
    #expect(prompt.contains("Each recipe_name in meal_plan must match exactly one recipe in the recipes array"))
    #expect(prompt.contains("= 21 meals total"))
    // Week label uses the Monday start + ISO dates.
    #expect(prompt.contains("Week: Monday (2026-06-22) through Sunday (2026-06-28)"))
    // Example meal_date in the JSON block is the week-start day.
    #expect(prompt.contains("\"meal_date\": \"2026-06-22\""))
}

@Test("empty profile + no context yields the no-preferences placeholder and no extra rules")
func promptDegradesGracefully() {
    let prompt = WeekGenPrompt.buildSystemPrompt(
        profileSettings: [:], weekStart: weekStart(), context: nil
    )
    #expect(prompt.contains("(no preferences set)"))
    // The reuse-cap extra rule is only emitted when a context is present.
    #expect(!prompt.contains("A single recipe may appear at most 3 times"))
    #expect(!prompt.contains("HARD ALLERGIES"))
}

@Test("metric unit directive is selected for metric users")
func promptMetricDirective() {
    let prompt = WeekGenPrompt.buildSystemPrompt(
        profileSettings: [:], weekStart: weekStart(), context: nil, unitSystem: .metric
    )
    #expect(prompt.contains("UNIT SYSTEM — METRIC ONLY"))
    #expect(!prompt.contains("US CUSTOMARY"))
}

@Test("context enriches the prompt with allergies, avoids, staples, recents, goal, and extra rules")
func promptWithContext() {
    let prompt = WeekGenPrompt.buildSystemPrompt(
        profileSettings: ["cuisine_preferences": "loves spice"],
        weekStart: weekStart(),
        context: fixtureContext(),
        unitSystem: .us
    )
    // Alias preamble appears before preference signals.
    #expect(prompt.contains("Household shorthand (treat each term as if the user typed the expansion):"))
    #expect(prompt.contains("- chx → chicken"))
    let aliasIdx = prompt.range(of: "Household shorthand")!.lowerBound
    let signalsIdx = prompt.range(of: "Preference signals:")!.lowerBound
    #expect(aliasIdx < signalsIdx)
    // Allergy line sits above the generic MUST AVOID line and emphasizes HARD.
    #expect(prompt.contains("- HARD ALLERGIES — NEVER include these or any dish containing them: peanut, shellfish"))
    #expect(prompt.contains("- MUST AVOID: cilantro, olives"))
    let allergyIdx = prompt.range(of: "HARD ALLERGIES")!.lowerBound
    let avoidIdx = prompt.range(of: "MUST AVOID")!.lowerBound
    #expect(allergyIdx < avoidIdx)
    // Likes / brands / cuisines.
    #expect(prompt.contains("- Strongly likes: garlic, lemon"))
    #expect(prompt.contains("- Preferred brands: Rao's"))
    #expect(prompt.contains("- Liked cuisines: Italian, Thai"))
    #expect(prompt.contains("- Disliked cuisines: German"))
    // Staples + recents.
    #expect(prompt.contains("Pantry staples (always available, use freely):\nolive oil, salt, rice"))
    #expect(prompt.contains("Recent meals (avoid repeating these for variety):\nSheet Pan Chicken, Tofu Stir Fry"))
    // Dietary goal block.
    #expect(prompt.contains("Dietary goal (per-person, per-day):"))
    #expect(prompt.contains("- Daily target: 2000 calories, 160g protein, 180g carbs, 60g fat, 30g fiber"))
    #expect(prompt.contains("- Goal type: cut"))
    #expect(prompt.contains("- Notes: high protein"))
    // Extra rules (context-only).
    #expect(prompt.contains("- NEVER include ingredients from the MUST AVOID list"))
    #expect(prompt.contains("- A single recipe may appear at most 3 times in one week (e.g., leftovers)"))
    #expect(prompt.contains("- Design each day so the three meals together land within ±10% of the daily calorie target"))
    #expect(prompt.contains("- Leverage pantry staples when possible to reduce grocery costs"))
}

@Test("a zero-calorie dietary goal omits the goal block and its calorie rules")
func promptZeroCalorieGoalOmitted() {
    var ctx = fixtureContext()
    ctx.dietaryGoal = DietaryGoalContext(goalType: "maintain", dailyCalories: 0)
    let prompt = WeekGenPrompt.buildSystemPrompt(
        profileSettings: [:], weekStart: weekStart(), context: ctx
    )
    #expect(!prompt.contains("Dietary goal (per-person, per-day):"))
    #expect(!prompt.contains("±10% of the daily calorie target"))
}

// MARK: - Parser round-trip

private let sampleResponse = """
{
  "recipes": [
    {
      "name": "Lemon Garlic Chicken",
      "meal_type": "dinner",
      "cuisine": "Mediterranean",
      "servings": 4,
      "prep_minutes": 15,
      "cook_minutes": 30,
      "ingredients": [
        {"ingredient_name": "chicken breast", "quantity": 2.0, "unit": "lb", "prep": "cubed", "category": "protein"},
        {"ingredient_name": "garlic", "quantity": 4, "unit": "clove", "category": "aromatic"}
      ],
      "steps": [
        {"instruction": "Season the chicken."},
        {"instruction": "Roast at 400F for 30 minutes."}
      ]
    }
  ],
  "meal_plan": [
    {"day_name": "Monday", "meal_date": "2026-06-22", "slot": "dinner", "recipe_name": "Lemon Garlic Chicken", "servings": 4, "notes": "double it"}
  ]
}
"""

@Test("parser round-trips the documented response shape")
func parserRoundTrip() throws {
    let result = try MealPlanParser.parse(sampleResponse)
    #expect(result.recipes.count == 1)
    #expect(result.mealPlan.count == 1)
    let recipe = try #require(result.recipes.first)
    #expect(recipe.name == "Lemon Garlic Chicken")
    #expect(recipe.servings == 4)
    #expect(recipe.prepMinutes == 15)
    #expect(recipe.ingredients.count == 2)
    // String quantity ("4") decodes to a Double.
    #expect(recipe.ingredients[1].quantity == 4)
    #expect(recipe.steps.count == 2)
    let slot = try #require(result.mealPlan.first)
    #expect(slot.slot == "dinner")
    #expect(slot.recipeName == "Lemon Garlic Chicken")
    #expect(slot.servings == 4)
    #expect(slot.notes == "double it")
    // source defaults to "ai", approved to false (matching generate_week_plan defaults).
    #expect(slot.source == "ai")
    #expect(slot.approved == false)
    // The slot resolves back to its recipe by name.
    #expect(result.recipe(for: slot)?.name == "Lemon Garlic Chicken")
}

@Test("parser strips a markdown code fence (```json) before decoding")
func parserStripsFence() throws {
    let fenced = "```json\n" + sampleResponse + "\n```"
    let result = try MealPlanParser.parse(fenced)
    #expect(result.mealPlan.count == 1)
    #expect(result.recipes.first?.name == "Lemon Garlic Chicken")
}

@Test("parser throws invalidJSON on non-JSON output")
func parserInvalidJSON() {
    #expect(throws: MealPlanParseError.invalidJSON) {
        _ = try MealPlanParser.parse("the AI is taking a break, sorry!")
    }
}

@Test("parser throws emptyPlan when meal_plan is empty")
func parserEmptyPlan() {
    #expect(throws: MealPlanParseError.emptyPlan) {
        _ = try MealPlanParser.parse(#"{"recipes": [], "meal_plan": []}"#)
    }
}

@Test("parser applies recipe/ingredient field defaults for sparse objects")
func parserDefaults() throws {
    let sparse = """
    {"recipes": [{"name": "Plain Oats", "ingredients": [{"ingredient_name": "oats"}]}],
     "meal_plan": [{"day_name": "Monday", "meal_date": "2026-06-22", "slot": "breakfast", "recipe_name": "Plain Oats"}]}
    """
    let result = try MealPlanParser.parse(sparse)
    let recipe = try #require(result.recipes.first)
    #expect(recipe.mealType == "")
    #expect(recipe.cuisine == "")
    #expect(recipe.servings == nil)
    #expect(recipe.steps.isEmpty)
    #expect(recipe.ingredients.first?.unit == "")
    let slot = try #require(result.mealPlan.first)
    #expect(slot.notes == "")
    #expect(slot.recipeId == nil)
}

// MARK: - Allergy hard-gate (Spike-2 invariant)

@Test("allergy gate passes a clean plan")
func allergyGatePassesClean() throws {
    let result = try MealPlanParser.parse(sampleResponse)
    // peanut / shellfish are not present in the sample.
    try MealPlanParser.enforceAllergyGate(result, allergies: ["peanut", "shellfish"])
}

@Test("allergy gate rejects a plan whose ingredient contains an allergen")
func allergyGateRejectsIngredient() throws {
    let violating = """
    {
      "recipes": [{
        "name": "Thai Noodles",
        "ingredients": [
          {"ingredient_name": "rice noodles"},
          {"ingredient_name": "Peanut Butter"}
        ]
      }],
      "meal_plan": [{"day_name": "Monday", "meal_date": "2026-06-22", "slot": "lunch", "recipe_name": "Thai Noodles"}]
    }
    """
    let result = try MealPlanParser.parse(violating)
    #expect(throws: MealPlanParseError.allergyViolation(recipe: "Thai Noodles", allergen: "peanut")) {
        try MealPlanParser.enforceAllergyGate(result, allergies: ["peanut"])
    }
}

@Test("allergy gate rejects a plan whose recipe NAME contains an allergen")
func allergyGateRejectsRecipeName() throws {
    let violating = """
    {
      "recipes": [{"name": "Shellfish Paella", "ingredients": [{"ingredient_name": "rice"}]}],
      "meal_plan": [{"day_name": "Tuesday", "meal_date": "2026-06-23", "slot": "dinner", "recipe_name": "Shellfish Paella"}]
    }
    """
    let result = try MealPlanParser.parse(violating)
    #expect(throws: MealPlanParseError.allergyViolation(recipe: "Shellfish Paella", allergen: "shellfish")) {
        try MealPlanParser.enforceAllergyGate(result, allergies: ["shellfish"])
    }
}

@Test("allergy gate is a no-op when the user has no allergies")
func allergyGateNoAllergies() throws {
    let violating = """
    {"recipes": [{"name": "Peanut Stew", "ingredients": [{"ingredient_name": "peanuts"}]}],
     "meal_plan": [{"day_name": "Monday", "meal_date": "2026-06-22", "slot": "dinner", "recipe_name": "Peanut Stew"}]}
    """
    let result = try MealPlanParser.parse(violating)
    // No allergens configured → no gate fires.
    try MealPlanParser.enforceAllergyGate(result, allergies: [])
    try MealPlanParser.enforceAllergyGate(result, allergies: ["   "])
}

@Test("parseAndGate fails closed on a violating plan before returning")
func parseAndGateFailsClosed() {
    let violating = """
    {"recipes": [{"name": "Crab Cakes", "ingredients": [{"ingredient_name": "crab", "normalized_name": "shellfish"}]}],
     "meal_plan": [{"day_name": "Monday", "meal_date": "2026-06-22", "slot": "lunch", "recipe_name": "Crab Cakes"}]}
    """
    #expect(throws: MealPlanParseError.allergyViolation(recipe: "Crab Cakes", allergen: "shellfish")) {
        _ = try MealPlanParser.parseAndGate(violating, allergies: ["shellfish"])
    }
}
