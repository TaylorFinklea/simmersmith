import Testing
@testable import GroceryMerge

// SP-C slice 4 — fidelity tests for the on-device EVENT-grocery generation port
// (app/services/event_grocery.py: _aggregate_event_rows + regenerate_event_grocery).
// The acceptance bar: a 2-meal event sharing an ingredient sums into one EventGroceryItem; a meal
// removed drops its rows; guest-assigned meals contribute nothing; the scale factor + 4-tuple key
// + JSON source_meals + (category, name) sort all match the server.

// MARK: - Fixtures

private func line(
    _ name: String, qty: Double? = nil, unit: String = "", category: String = "",
    notes: String = "", base: String? = nil, quantityText: String = "",
    status: String = "unresolved", variation: String? = nil
) -> GroceryIngredientLine {
    GroceryIngredientLine(
        ingredientName: name, normalizedName: "", unit: unit, quantity: qty,
        quantityText: quantityText, category: category, notes: notes, baseIngredientID: base,
        ingredientVariationID: variation, resolutionStatus: status
    )
}

/// A recipe-backed event meal whose factor is 1.0 (baseServings == servings) unless overridden.
private func meal(
    _ id: String, servings: Double? = 2, baseServings: Double? = 2,
    guest: String? = nil, scale: Double? = nil,
    _ ingredients: [GroceryIngredientLine]
) -> EventGroceryMeal {
    EventGroceryMeal(
        mealID: id, assignedGuestID: guest, scaleMultiplier: scale,
        servings: servings, baseServings: baseServings, ingredients: ingredients
    )
}

// MARK: - aggregation / summing

@Test("a 2-meal event sharing an ingredient sums into one EventGroceryItem with both meal IDs")
func eventTwoMealsShareIngredientSummed() {
    let m1 = meal("m1", [line("Tomato", qty: 2, unit: "cup", category: "Produce")])
    let m2 = meal("m2", [line("Tomato", qty: 1, unit: "cup", category: "Produce")])

    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m1, m2],
                                                newRecordName: { _ in "EG_tomato" })
    #expect(rows.count == 1)
    let tomato = rows[0]
    #expect(tomato.eventQuantity == 3)               // 2 + 1
    #expect(tomato.unit == "cup")
    #expect(tomato.ingredientName == "Tomato")
    // source_meals is a JSON array of the contributing meal IDs, sorted
    #expect(tomato.sourceMeals == "[\"m1\", \"m2\"]")
}

@Test("removing a meal drops the rows that only it contributed and de-sums shared ones")
func eventMealRemovedDropsItsRows() {
    let m1 = meal("m1", [
        line("Tomato", qty: 2, unit: "cup", category: "Produce"),
        line("Basil", qty: 1, unit: "bunch", category: "Produce"),
    ])
    let m2 = meal("m2", [line("Tomato", qty: 1, unit: "cup", category: "Produce")])

    // Both meals present: Tomato (3) + Basil (1).
    let before = EventGroceryGenerator.regenerate(eventID: "E", meals: [m1, m2])
    #expect(Set(before.map(\.ingredientName)) == ["Tomato", "Basil"])
    #expect(before.first { $0.ingredientName == "Tomato" }?.eventQuantity == 3)

    // Remove m1 → Basil row gone entirely; Tomato falls to m2's 1.
    let after = EventGroceryGenerator.regenerate(eventID: "E", meals: [m2])
    #expect(after.map(\.ingredientName) == ["Tomato"])
    #expect(after[0].eventQuantity == 1)
    #expect(after[0].sourceMeals == "[\"m2\"]")
}

@Test("a meal assigned to a guest contributes no grocery (the guest brings the dish)")
func eventGuestAssignedMealContributesNothing() {
    let hostMeal = meal("m1", [line("Chicken", qty: 2, unit: "lb")])
    let guestMeal = meal("m2", guest: "g1", [line("Salad", qty: 3, unit: "cup")])

    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [hostMeal, guestMeal])
    #expect(rows.map(\.ingredientName) == ["Chicken"])
    #expect(rows[0].eventQuantity == 2)
}

@Test("different units do NOT merge — they form distinct event rows")
func eventDifferentUnitsDistinct() {
    let m = meal("m1", [
        line("Flour", qty: 2, unit: "cup"),
        line("Flour", qty: 3, unit: "oz"),
    ])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m])
    #expect(rows.count == 2)
    #expect(Set(rows.map(\.unit)) == ["cup", "oz"])
}

@Test("scale_multiplier scales the event meal's quantities")
func eventScaleMultiplierApplied() {
    let m = meal("m1", scale: 1.5, [line("Carrot", qty: 4, unit: "ct")])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m])
    #expect(rows.count == 1)
    #expect(rows[0].eventQuantity == 6)              // 4 * 1.5
}

@Test("servings/baseServings drive the factor when no scale_multiplier")
func eventServingsFactor() {
    // 8 servings cooked from a 2-serving base recipe → factor 4.0
    let m = meal("m1", servings: 8, baseServings: 2, [line("Noodles", qty: 8, unit: "oz")])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m])
    #expect(rows[0].eventQuantity == 32)             // 8 * (8/2)
}

@Test("an inline event meal (no recipe) aggregates its own lines at factor 1 unless scaled")
func eventInlineMealNoRecipe() {
    // baseServings: nil → inline. factor = scaleMultiplier ?? 1.0.
    let inline = EventGroceryMeal(mealID: "m1", baseServings: nil,
                                  ingredients: [line("Ice", qty: 5, unit: "lb")])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [inline])
    #expect(rows.count == 1)
    #expect(rows[0].eventQuantity == 5)              // factor 1.0, no servings ratio
}

@Test("rows are sorted by (category, ingredient name), case-insensitively")
func eventSortedByCategoryThenName() {
    let m = meal("m1", [
        line("Zucchini", qty: 1, unit: "ct", category: "Produce"),
        line("Apple", qty: 1, unit: "ct", category: "Produce"),
        line("Milk", qty: 1, unit: "gal", category: "Dairy"),
    ])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m])
    // Dairy < Produce; within Produce, Apple < Zucchini.
    #expect(rows.map(\.ingredientName) == ["Milk", "Apple", "Zucchini"])
}

@Test("a locked variation participates in the aggregation key; an unlocked one does not")
func eventLockedVariationKeying() {
    // Same base, same unit, but two different variations — only the LOCKED ones split the key.
    let m = meal("m1", [
        line("Cheese", qty: 1, unit: "oz", base: "b_cheese", status: "locked", variation: "v_cheddar"),
        line("Cheese", qty: 2, unit: "oz", base: "b_cheese", status: "locked", variation: "v_swiss"),
    ])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m])
    #expect(rows.count == 2)                          // locked variations split into 2 rows

    // Unlocked: same base/unit → one merged row summing to 3.
    let m2 = meal("m2", [
        line("Cheese", qty: 1, unit: "oz", base: "b_cheese", status: "resolved", variation: "v_cheddar"),
        line("Cheese", qty: 2, unit: "oz", base: "b_cheese", status: "resolved", variation: "v_swiss"),
    ])
    let merged = EventGroceryGenerator.regenerate(eventID: "E", meals: [m2])
    #expect(merged.count == 1)
    #expect(merged[0].eventQuantity == 3)
}

@Test("a quantity-text-only line (no numeric quantity) carries the text + a quantity-review flag")
func eventQuantityTextOnly() {
    let m = meal("m1", [line("Salt", qty: nil, unit: "", quantityText: "to taste")])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m])
    #expect(rows.count == 1)
    #expect(rows[0].eventQuantity == nil)
    #expect(rows[0].quantityText == "to taste")
    #expect(rows[0].reviewFlag == "quantity review")
}

@Test("notes and prep from a line are collected onto the row, sorted + joined")
func eventNotesAndPrepCollected() {
    let m = meal("m1", [
        line("Onion", qty: 2, unit: "ct", notes: "yellow"),
    ])
    // prep is a separate field on the line.
    var withPrep = m
    withPrep.ingredients[0].prep = "diced"
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [withPrep])
    #expect(rows.count == 1)
    #expect(rows[0].notes == "diced; yellow")        // sorted: diced < yellow
}

@Test("an empty event (no meals) produces no rows")
func eventEmptyEventEmpty() {
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [])
    #expect(rows.isEmpty)
}

@Test("regen stamps the clock as modifiedAt and uses the minted record name")
func eventClockAndRecordName() {
    let m = meal("m1", [line("Egg", qty: 6, unit: "ea")])
    let rows = EventGroceryGenerator.regenerate(eventID: "E", meals: [m], clock: 42,
                                                newRecordName: { _ in "EG_egg" })
    #expect(rows.count == 1)
    #expect(rows[0].recordName == "EG_egg")
    #expect(rows[0].modifiedAt == 42)
    #expect(rows[0].mergedIntoWeekID == nil)         // fresh row: no merge pointer yet
    #expect(rows[0].mergedIntoGroceryItemID == nil)
}
