import Foundation
import Testing
@testable import SimmerSmithKit

// SP-C AI-3 — Headless tests for NutritionCalculator (deterministic catalog port).
// TDD against the server's `calculate_recipe_nutrition` math: known ingredient macros →
// correct totals/per-serving/coverage; unmatched handling; a unit-conversion case.

// MARK: - Fixture catalog

/// A tiny per-100g catalog keyed by baseIngredientID, mirroring the server's macro seed.
/// Reference amount/unit = 100 g (the USDA seed convention from nutrition.py).
private func fixtureLookup(_ table: [String: CatalogMacros]) -> NutritionCalculator.CatalogLookup {
    { key in
        if let id = key.baseIngredientID, let macros = table[id] { return macros }
        // name fallback (mirrors the server's nutrition-item name match path)
        if let macros = table[key.ingredientName] { return macros }
        return nil
    }
}

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

private func makeCalculator(_ table: [String: CatalogMacros]) -> NutritionCalculator {
    NutritionCalculator(lookup: fixtureLookup(table), now: { fixedNow })
}

private func ingredient(
    _ name: String,
    base: String? = nil,
    quantity: Double?,
    unit: String,
    normalized: String? = nil
) -> NutritionCalculator.Ingredient {
    NutritionCalculator.Ingredient(
        key: .init(ingredientName: name, normalizedName: normalized, baseIngredientID: base),
        quantity: quantity,
        unit: unit
    )
}

// MARK: - Totals + per-serving + coverage

@Test
func nutritionCompleteCoverageTotalsAndPerServing() {
    // chicken: 165 cal / 100 g; rice: 130 cal / 100 g.
    let calc = makeCalculator([
        "chicken": CatalogMacros(referenceAmount: 100, referenceUnit: "g", calories: 165),
        "rice": CatalogMacros(referenceAmount: 100, referenceUnit: "g", calories: 130),
    ])
    let summary = calc.calculateRecipeNutrition(
        ingredients: [
            ingredient("Chicken breast", base: "chicken", quantity: 200, unit: "g"),
            ingredient("Rice", base: "rice", quantity: 150, unit: "g"),
        ],
        servings: 2
    )
    // chicken: 165 * (200/100) = 330.0 ; rice: 130 * (150/100) = 195.0 ; total 525.0
    #expect(summary.totalCalories == 525.0)
    #expect(summary.caloriesPerServing == 262.5) // 525 / 2
    #expect(summary.coverageStatus == "complete")
    #expect(summary.matchedIngredientCount == 2)
    #expect(summary.unmatchedIngredientCount == 0)
    #expect(summary.unmatchedIngredients.isEmpty)
}

@Test
func nutritionPartialCoverageCollectsUnmatched() {
    let calc = makeCalculator([
        "chicken": CatalogMacros(referenceAmount: 100, referenceUnit: "g", calories: 165),
    ])
    let summary = calc.calculateRecipeNutrition(
        ingredients: [
            ingredient("Chicken breast", base: "chicken", quantity: 100, unit: "g"),
            ingredient("Exotic Spice", quantity: 5, unit: "g"),          // no catalog entry
            ingredient("Exotic Spice", quantity: 2, unit: "g"),          // duplicate → not listed twice
        ],
        servings: nil
    )
    #expect(summary.totalCalories == 165.0)
    #expect(summary.caloriesPerServing == nil) // no servings
    #expect(summary.coverageStatus == "partial")
    #expect(summary.matchedIngredientCount == 1)
    #expect(summary.unmatchedIngredientCount == 1)
    #expect(summary.unmatchedIngredients == ["Exotic Spice"])
}

@Test
func nutritionUnavailableWhenNothingMatches() {
    let calc = makeCalculator([:])
    let summary = calc.calculateRecipeNutrition(
        ingredients: [ingredient("Mystery", quantity: 1, unit: "ea")],
        servings: 4
    )
    #expect(summary.totalCalories == nil)
    #expect(summary.caloriesPerServing == nil)
    #expect(summary.coverageStatus == "unavailable")
    #expect(summary.matchedIngredientCount == 0)
    #expect(summary.unmatchedIngredientCount == 1)
}

// MARK: - Unit conversion (cross-unit within a dimension)

@Test
func nutritionConvertsAcrossMassUnits() {
    // butter: 717 cal / 100 g. Recipe asks for 2 oz → 2 * 28.3495 = 56.699 g.
    // factor = 56.699 / 100 = 0.56699 ; 717 * 0.56699 = 406.531... → round(_, 2) per server = 406.53
    let calc = makeCalculator([
        "butter": CatalogMacros(referenceAmount: 100, referenceUnit: "g", calories: 717),
    ])
    let summary = calc.calculateRecipeNutrition(
        ingredients: [ingredient("Butter", base: "butter", quantity: 2, unit: "oz")],
        servings: nil
    )
    #expect(summary.coverageStatus == "complete")
    #expect(summary.matchedIngredientCount == 1)
    #expect(summary.totalCalories == 406.5) // round(406.53, 1)
}

@Test
func nutritionDoesNotConvertAcrossDimensions() {
    // reference is volume (ml) but recipe is mass (g): no shared dimension → unmatched.
    let calc = makeCalculator([
        "milk": CatalogMacros(referenceAmount: 100, referenceUnit: "ml", calories: 42),
    ])
    let summary = calc.calculateRecipeNutrition(
        ingredients: [ingredient("Milk", base: "milk", quantity: 50, unit: "g")],
        servings: nil
    )
    #expect(summary.coverageStatus == "unavailable")
    #expect(summary.unmatchedIngredients == ["Milk"])
}

@Test
func nutritionSameUnitVolumeScaling() {
    // honey: 64 cal / tbsp. Recipe: 3 tbsp → 64 * 3 = 192.
    let calc = makeCalculator([
        "honey": CatalogMacros(referenceAmount: 1, referenceUnit: "tbsp", calories: 64),
    ])
    let summary = calc.calculateRecipeNutrition(
        ingredients: [ingredient("Honey", base: "honey", quantity: 3, unit: "tbsp")],
        servings: nil
    )
    #expect(summary.totalCalories == 192.0)
    #expect(summary.coverageStatus == "complete")
}

// MARK: - Macro aggregation (forward-compat with full catalog macros)

@Test
func macroBreakdownScalesAndAggregates() {
    // chicken per 100 g: 165 cal, 31 P, 0 C, 3.6 F, 0 fiber.
    // 200 g → factor 2.0 → 330 cal, 62 P, 0 C, 7.2 F.
    let calc = makeCalculator([
        "chicken": CatalogMacros(
            referenceAmount: 100, referenceUnit: "g",
            calories: 165, proteinG: 31, carbsG: 0, fatG: 3.6, fiberG: 0
        ),
    ])
    let macros = calc.calculateMealMacros(ingredients: [
        ingredient("Chicken", base: "chicken", quantity: 200, unit: "g"),
    ])
    #expect(macros.calories == 330)
    #expect(macros.proteinG == 62)
    #expect(macros.fatG == 7.2)
    #expect(macros.carbsG == 0)
}

// MARK: - Unit-conversion helper (direct port checks)

@Test
func caloriesForReferenceRejectsNonPositive() {
    #expect(NutritionCalculator.caloriesForReference(
        quantity: 0, unit: "g", referenceAmount: 100, referenceUnit: "g", calories: 165) == nil)
    #expect(NutritionCalculator.caloriesForReference(
        quantity: 100, unit: "g", referenceAmount: 0, referenceUnit: "g", calories: 165) == nil)
    #expect(NutritionCalculator.caloriesForReference(
        quantity: 100, unit: "g", referenceAmount: 100, referenceUnit: "g", calories: nil) == nil)
}

@Test
func normalizeNameMatchesServerSemantics() {
    #expect(NutritionCalculator.normalizeName("  Fl Oz ") == "fl oz")
    #expect(NutritionCalculator.normalizeName("Salt & Pepper") == "salt and pepper")
    #expect(NutritionCalculator.normalizeName("All-Purpose Flour!") == "all purpose flour")
}
