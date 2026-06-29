import Foundation
import Testing
@testable import SimmerSmithKit

// V-T2/T3 — the resolver is the production risk surface (MealUpdateRequest construction:
// UTC mealDate, slot, recipe match vs free-text, intent sentinels). Tested directly + a
// serialization round-trip guarding the weeks_update_meals tool contract.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
}()

/// A Date at UTC midnight for the given y/m/d.
private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    return utc.date(from: c)!
}

/// Build a minimal RecipeSummary via its tolerant decoder.
private func recipe(_ id: String, _ name: String, archived: Bool = false) throws -> RecipeSummary {
    let json = #"{"recipe_id":"\#(id)","name":"\#(name)","archived":\#(archived),"updated_at":"2026-01-01T00:00:00Z"}"#
    return try SimmerSmithJSONCoding.makeDecoder().decode(RecipeSummary.self, from: Data(json.utf8))
}

private func entry(_ day: String, _ slot: String, _ dish: String, _ intent: String) -> ParsedMealEntry {
    ParsedMealEntry(day: day, slot: slot, rawDish: dish, intent: intent)
}

// 2026-06-29 is a Monday (per the app's own "Jun 29 · Monday").
private let monday = utcDay(2026, 6, 29)

@Test("named days map to the right UTC mealDate + dayName (the offset landmine)")
func namedDaysUTC() {
    let plan = ParsedWeeklyPlan(entries: [
        entry("Monday", "dinner", "tacos", "recipe"),
        entry("Wednesday", "lunch", "salad", "recipe"),
        entry("Sunday", "breakfast", "pancakes", "recipe"),
    ])
    let out = VoicePlanResolver.resolve(plan, recipes: [], weekStart: monday)
    #expect(out.count == 3)
    #expect(out[0].dayName == "Monday")
    #expect(out[0].mealDate == utcDay(2026, 6, 29))   // Monday + 0
    #expect(out[0].slot == "dinner")
    #expect(out[1].dayName == "Wednesday")
    #expect(out[1].mealDate == utcDay(2026, 7, 1))     // Monday + 2
    #expect(out[2].dayName == "Sunday")
    #expect(out[2].mealDate == utcDay(2026, 7, 5))     // Monday + 6 (crosses month — UTC, no TZ drift)
}

@Test("recipe intent: best-match sets recipeId, else free-text recipeName")
func recipeMatchVsFreeText() throws {
    let recipes = [try recipe("r1", "Honey Garlic Salmon"), try recipe("r2", "Chicken Tikka")]
    let plan = ParsedWeeklyPlan(entries: [
        entry("Monday", "dinner", "that salmon recipe", "recipe"),   // → matches r1
        entry("Tuesday", "dinner", "quinoa surprise bowl", "recipe"), // → no match → free-text
    ])
    let out = VoicePlanResolver.resolve(plan, recipes: recipes, weekStart: monday)
    #expect(out[0].recipeId == "r1")
    #expect(out[0].recipeName == "Honey Garlic Salmon")
    #expect(out[1].recipeId == nil)
    #expect(out[1].recipeName == "Quinoa Surprise Bowl")
}

@Test("archived recipes are not matched")
func archivedExcluded() throws {
    let recipes = [try recipe("r1", "Honey Garlic Salmon", archived: true)]
    let out = VoicePlanResolver.resolve(
        ParsedWeeklyPlan(entries: [entry("Monday", "dinner", "honey garlic salmon", "recipe")]),
        recipes: recipes, weekStart: monday)
    #expect(out[0].recipeId == nil)   // archived → free-text, not matched
}

@Test("intents: eatOut + leftovers map to recipe-less names; skip omits the slot")
func intents() {
    let plan = ParsedWeeklyPlan(entries: [
        entry("Friday", "dinner", "order pizza", "eatOut"),
        entry("Tuesday", "dinner", "taco", "leftovers"),
        entry("Wednesday", "breakfast", "leftovers", "leftovers"),
        entry("Thursday", "lunch", "whatever", "skip"),
    ])
    let out = VoicePlanResolver.resolve(plan, recipes: [], weekStart: monday)
    #expect(out.count == 3)  // skip omitted
    let fri = out.first { $0.dayName == "Friday" }
    #expect(fri?.recipeId == nil)
    #expect(fri?.recipeName == "Eating Out")
    let tue = out.first { $0.dayName == "Tuesday" }
    #expect(tue?.recipeName == "Taco Leftovers")
    let wed = out.first { $0.dayName == "Wednesday" }
    #expect(wed?.recipeName == "Leftovers")
    #expect(!out.contains { $0.dayName == "Thursday" })
}

@Test("'today'/'tomorrow' resolve via the injected now, in-week")
func relativeDays() {
    // now = Wednesday 2026-07-01 (in the Mon 6/29 week).
    let now = utcDay(2026, 7, 1)
    let plan = ParsedWeeklyPlan(entries: [
        entry("today", "dinner", "stir fry", "recipe"),
        entry("tomorrow", "dinner", "soup", "recipe"),
    ])
    let out = VoicePlanResolver.resolve(plan, recipes: [], weekStart: monday, now: now)
    #expect(out[0].dayName == "Wednesday")
    #expect(out[1].dayName == "Thursday")
}

@Test("relative day outside the planned week is dropped, not mis-mapped to the wrong week")
func relativeDayOutsideWeek() {
    // now = Friday 2026-06-26, three days BEFORE the Mon 6/29 week.
    let now = utcDay(2026, 6, 26)
    let plan = ParsedWeeklyPlan(entries: [
        entry("today", "dinner", "stir fry", "recipe"),  // outside the week → dropped
        entry("Monday", "dinner", "tacos", "recipe"),     // named weekday → kept
    ])
    let out = VoicePlanResolver.resolve(plan, recipes: [], weekStart: monday, now: now)
    #expect(out.count == 1)
    #expect(out[0].dayName == "Monday")
}

@Test("garbage day/slot are dropped, not mis-placed")
func dropsGarbage() {
    let plan = ParsedWeeklyPlan(entries: [
        entry("Funday", "dinner", "x", "recipe"),     // bad day → dropped
        entry("Monday", "brunchsupper", "x", "recipe"), // bad slot → dropped
        entry("Monday", "dinner", "x", "recipe"),       // good
    ])
    let out = VoicePlanResolver.resolve(plan, recipes: [], weekStart: monday)
    #expect(out.count == 1)
    #expect(out[0].dayName == "Monday" && out[0].slot == "dinner")
}

@Test("contract: resolved meals round-trip through the snake_case coder (weeks_update_meals payload)")
func contractRoundTrip() throws {
    let recipes = [try recipe("r1", "Honey Garlic Salmon")]
    let out = VoicePlanResolver.resolve(
        ParsedWeeklyPlan(entries: [
            entry("Monday", "dinner", "salmon", "recipe"),
            entry("Friday", "dinner", "pizza", "eatOut"),
        ]),
        recipes: recipes, weekStart: monday)
    // Encode like the assistant tool, then decode back as the tool's handler does — must not throw.
    let data = try SimmerSmithJSONCoding.makeEncoder().encode(out)
    let decoded = try SimmerSmithJSONCoding.makeDecoder().decode([MealUpdateRequest].self, from: data)
    #expect(decoded == out)
}
