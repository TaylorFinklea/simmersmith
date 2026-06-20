import Testing
@testable import GroceryMerge

// SP-C slice 3 — fidelity tests for the on-device grocery regen port
// (app/services/grocery.py: build_grocery_rows_for_week + regenerate_grocery_for_week).
// High fidelity to the Python is the acceptance bar: a 2-meal week with a shared ingredient
// sums; a user override survives; a tombstone stays removed; an eventQuantity survives; a
// checked item stays checked.

// MARK: - Fixtures

private func line(
    _ name: String, qty: Double? = nil, unit: String = "", category: String = "",
    notes: String = "", base: String? = nil
) -> GroceryIngredientLine {
    GroceryIngredientLine(
        ingredientName: name, normalizedName: "", unit: unit, quantity: qty,
        category: category, notes: notes, baseIngredientID: base
    )
}

/// A recipe-backed meal whose factor is 1.0 (baseServings == servings) unless overridden.
private func meal(
    day: String, slot: String = "dinner", recipe: String,
    servings: Double? = 2, baseServings: Double? = 2,
    _ ingredients: [GroceryIngredientLine], sides: [GroceryMealSide] = []
) -> GroceryMeal {
    GroceryMeal(
        dayName: day, slot: slot, recipeName: recipe,
        scaleMultiplier: nil, servings: servings, baseServings: baseServings,
        ingredients: ingredients, sides: sides
    )
}

// MARK: - build / aggregation

@Test("a 2-meal week sharing an ingredient sums totalQuantity and collects both source meals")
func twoMealsShareIngredientSummed() {
    let monday = meal(day: "Mon", recipe: "Chili", [line("Tomato", qty: 2, unit: "cup", category: "Produce")])
    let tuesday = meal(day: "Tue", recipe: "Soup", [line("Tomato", qty: 1, unit: "cup", category: "Produce")])

    let r = GroceryGenerator.regenerate(meals: [monday, tuesday], existing: [], weekID: "W",
                                        newRecordName: { _ in "G_tomato" })

    #expect(r.tombstones.isEmpty)
    #expect(r.upserts.count == 1)
    let tomato = r.upserts[0]
    #expect(tomato.totalQuantity == 3)               // 2 + 1
    #expect(tomato.unit == "cup")
    // both meals contribute to sourceMeals, sorted + "; "-joined
    #expect(tomato.sourceMeals == "Mon / dinner / Chili; Tue / dinner / Soup")
}

@Test("different units do NOT merge — they form distinct rows")
func differentUnitsDistinct() {
    let m = meal(day: "Mon", recipe: "Bake", [
        line("Flour", qty: 2, unit: "cup"),
        line("Flour", qty: 3, unit: "oz"),
    ])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [], weekID: "W")
    #expect(r.upserts.count == 2)
    #expect(Set(r.upserts.map(\.unit)) == ["cup", "oz"])
}

@Test("scale_multiplier scales the recipe quantity")
func scaleMultiplierApplied() {
    var m = meal(day: "Mon", recipe: "Stew", [line("Carrot", qty: 4, unit: "ct")])
    m.scaleMultiplier = 1.5
    let r = GroceryGenerator.regenerate(meals: [m], existing: [], weekID: "W")
    #expect(r.upserts.count == 1)
    #expect(r.upserts[0].totalQuantity == 6)         // 4 * 1.5
}

@Test("servings/baseServings drive the factor when no scale_multiplier")
func servingsFactor() {
    // 4 servings cooked from a 2-serving base recipe → factor 2.0
    let m = meal(day: "Mon", recipe: "Pasta", servings: 4, baseServings: 2,
                 [line("Noodles", qty: 8, unit: "oz")])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [], weekID: "W")
    #expect(r.upserts[0].totalQuantity == 16)        // 8 * (4/2)
}

@Test("a recipe-backed side aggregates scaled by the parent meal and tags [side: name]")
func sideAggregates() {
    let side = GroceryMealSide(name: "Garlic Bread", baseServings: 2,
                               ingredients: [line("Butter", qty: 1, unit: "tbsp")])
    let m = meal(day: "Fri", recipe: "Steak", servings: 2, baseServings: 2,
                 [line("Steak", qty: 1, unit: "lb")], sides: [side])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [], weekID: "W")
    #expect(r.upserts.count == 2)
    let butter = r.upserts.first { $0.normalizedName == "butter" }
    #expect(butter?.sourceMeals == "Fri / dinner / Steak [side: Garlic Bread]")
}

@Test("a side without a recipe contributes nothing")
func sideWithoutRecipeIgnored() {
    let side = GroceryMealSide(name: "Salad", baseServings: nil, ingredients: [])
    let m = meal(day: "Fri", recipe: "Steak", [line("Steak", qty: 1, unit: "lb")], sides: [side])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [], weekID: "W")
    #expect(r.upserts.count == 1)
}

// MARK: - sticky preservation across regen

@Test("a quantityOverride survives a regen — override kept, auto value still refreshed underneath")
func quantityOverrideSurvives() {
    // Existing row the user overrode to 5; the auto aggregation now says 3.
    var existing = GroceryItem(recordName: "G_tomato", weekID: "W", unit: "cup",
                               normalizedName: "tomato", ingredientName: "Tomato",
                               totalQuantity: 2, sourceMeals: "old", quantityOverride: 5,
                               createdAt: 1)
    // sanity: its mergeKey is (normalizedName, "", unit, "")
    _ = existing

    let monday = meal(day: "Mon", recipe: "Chili", [line("Tomato", qty: 2, unit: "cup")])
    let tuesday = meal(day: "Tue", recipe: "Soup", [line("Tomato", qty: 1, unit: "cup")])

    let r = GroceryGenerator.regenerate(meals: [monday, tuesday], existing: [existing], weekID: "W")
    #expect(r.tombstones.isEmpty)
    #expect(r.upserts.count == 1)
    let row = r.upserts[0]
    #expect(row.recordName == "G_tomato")            // matched, not re-created
    #expect(row.quantityOverride == 5)               // override preserved
    // grocery.py:383-384 — when quantity_override is set, total_quantity is NOT refreshed
    // (the override owns display; the stale auto value is intentionally left untouched).
    #expect(row.totalQuantity == 2)
    // a NON-overridden auto field (sourceMeals) still refreshes from the new aggregation.
    #expect(row.sourceMeals == "Mon / dinner / Chili; Tue / dinner / Soup")
}

@Test("a tombstoned (isUserRemoved) item stays removed and is never resurrected")
func tombstonedItemStaysRemoved() {
    var removed = GroceryItem(recordName: "G_salt", weekID: "W", unit: "tsp",
                              normalizedName: "salt", ingredientName: "Salt",
                              totalQuantity: 1, isUserRemoved: true, createdAt: 1)
    _ = removed

    // The meal still references salt — the server would re-match but leave the tombstone as-is.
    let m = meal(day: "Mon", recipe: "Chili", [line("Salt", qty: 1, unit: "tsp")])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [removed], weekID: "W")
    // tombstone is matched → left untouched (NOT in upserts, NOT resurrected, NOT deleted)
    #expect(r.upserts.isEmpty)
    #expect(r.tombstones.isEmpty)
}

@Test("an eventQuantity survives a regen even when no meal references the row")
func eventQuantitySurvives() {
    // A mixed row: had a week-meal portion (totalQuantity) + an event portion (eventQuantity).
    // No meal references it anymore → week portion dropped, event portion kept.
    var mixed = GroceryItem(recordName: "G_cheese", weekID: "W", unit: "oz",
                            normalizedName: "cheese", ingredientName: "Cheese",
                            totalQuantity: 4, sourceMeals: "old", eventQuantity: 8, createdAt: 1)
    _ = mixed

    let r = GroceryGenerator.regenerate(meals: [], existing: [mixed], weekID: "W")
    #expect(r.tombstones.isEmpty)                    // NOT deleted — event portion holds it
    #expect(r.upserts.count == 1)
    let row = r.upserts[0]
    #expect(row.eventQuantity == 8)                  // event portion preserved
    #expect(row.totalQuantity == nil)                // stale week portion dropped
}

@Test("isChecked + checkedBy/At are preserved across a regen")
func checkStatePreserved() {
    var checked = GroceryItem(recordName: "G_egg", weekID: "W", unit: "ea",
                              normalizedName: "egg", ingredientName: "Egg",
                              totalQuantity: 6, check: CheckState(isChecked: true, at: 7, by: "userA"),
                              createdAt: 1)
    _ = checked

    let m = meal(day: "Mon", recipe: "Omelette", [line("Egg", qty: 6, unit: "ea")])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [checked], weekID: "W")
    #expect(r.upserts.count == 1)
    let row = r.upserts[0]
    #expect(row.check.isChecked == true)
    #expect(row.check.by == "userA")
    #expect(row.check.at == 7)
}

@Test("a user-added row is left untouched even when no meal references it")
func userAddedRowUntouched() {
    let userAdded = GroceryItem(recordName: "G_user", weekID: "W", unit: "",
                                normalizedName: "paper towels", ingredientName: "Paper Towels",
                                isUserAdded: true, createdAt: 1)
    let r = GroceryGenerator.regenerate(meals: [], existing: [userAdded], weekID: "W")
    #expect(r.upserts.isEmpty)                       // not refreshed
    #expect(r.tombstones.isEmpty)                    // not deleted
}

@Test("a checked auto row that lost its meal is kept (user investment) and flagged, not deleted")
func checkedAutoRowLosingMealIsFlaggedNotDeleted() {
    let checked = GroceryItem(recordName: "G_old", weekID: "W", unit: "cup",
                              normalizedName: "tomato", ingredientName: "Tomato",
                              totalQuantity: 2, sourceMeals: "Mon / dinner / Chili",
                              check: CheckState(isChecked: true, at: 3, by: "u"), createdAt: 1)
    // empty week → no meal references tomato
    let r = GroceryGenerator.regenerate(meals: [], existing: [checked], weekID: "W")
    #expect(r.tombstones.isEmpty)
    #expect(r.upserts.count == 1)
    #expect(r.upserts[0].reviewFlag == "no longer in any meal")
    #expect(r.upserts[0].check.isChecked == true)
}

@Test("a pure auto row whose meal is gone is tombstoned (deleted)")
func pureAutoRowDeletedWhenMealGone() {
    let auto = GroceryItem(recordName: "G_stale", weekID: "W", unit: "cup",
                           normalizedName: "tomato", ingredientName: "Tomato",
                           totalQuantity: 2, sourceMeals: "Mon / dinner / Chili", createdAt: 1)
    let r = GroceryGenerator.regenerate(meals: [], existing: [auto], weekID: "W")
    #expect(r.upserts.isEmpty)
    #expect(r.tombstones.map(\.recordName) == ["G_stale"])
}

@Test("storeLabel is preserved on a refreshed auto row")
func storeLabelPreserved() {
    let withStore = GroceryItem(recordName: "G_milk", weekID: "W", unit: "gal",
                                normalizedName: "milk", ingredientName: "Milk",
                                totalQuantity: 1, sourceMeals: "old", storeLabel: "Costco",
                                createdAt: 1)
    let m = meal(day: "Mon", recipe: "Cereal", [line("Milk", qty: 1, unit: "gal")])
    let r = GroceryGenerator.regenerate(meals: [m], existing: [withStore], weekID: "W")
    #expect(r.upserts.count == 1)
    #expect(r.upserts[0].storeLabel == "Costco")
}
