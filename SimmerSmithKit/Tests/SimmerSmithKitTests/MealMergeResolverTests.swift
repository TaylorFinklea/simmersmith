import Foundation
import Testing
@testable import SimmerSmithKit

// simmersmith-enx — MealMergeResolver.fold is the fix for weeks_update_meals's data-loss bug
// (saveWeekMeals is a full REPLACE; the tool must only ever send a MERGE payload). Covers:
// upsert-one-leaves-rest, clear-one-slot, add-new-slot, idempotence, full-set passthrough.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
}()

/// A Date at UTC midnight for the given y/m/d.
private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents(); c.year = y; c.month = m; c.day = d
    return utc.date(from: c)!
}

// 2026-06-29 is a Monday.
private let monday = utcDay(2026, 6, 29)
private let tuesday = utcDay(2026, 6, 30)
private let wednesday = utcDay(2026, 7, 1)
private let friday = utcDay(2026, 7, 3)

private func meal(
    _ id: String?, _ day: String, _ date: Date, _ slot: String, _ recipeName: String
) -> MealUpdateRequest {
    MealUpdateRequest(mealId: id, dayName: day, mealDate: date, slot: slot, recipeName: recipeName, approved: true)
}

@Test("upserting one slot leaves every other existing meal untouched")
func upsertOneLeavesRest() {
    let existing = [
        meal("m1", "Monday", monday, "breakfast", "Oatmeal"),
        meal("m2", "Monday", monday, "lunch", "Salad"),
        meal("m3", "Tuesday", tuesday, "dinner", "Stew"),
    ]
    let updates = [meal(nil, "Monday", monday, "lunch", "Wrap")]
    let merged = MealMergeResolver.fold(updates: updates, into: existing)

    #expect(merged.count == 3)
    #expect(merged.contains { $0.mealId == "m1" && $0.recipeName == "Oatmeal" })   // untouched
    #expect(merged.contains { $0.mealId == "m3" && $0.recipeName == "Stew" })      // untouched
    let mondayLunch = merged.first { $0.dayName == "Monday" && $0.slot == "lunch" }
    #expect(mondayLunch?.recipeName == "Wrap")
    #expect(mondayLunch?.mealId == "m2")   // preserved existing id → updates in place
}

@Test("an empty recipeName clears that one slot, leaving the rest")
func clearOneSlot() {
    let existing = [
        meal("m1", "Monday", monday, "breakfast", "Oatmeal"),
        meal("m2", "Monday", monday, "lunch", "Salad"),
        meal("m3", "Tuesday", tuesday, "dinner", "Stew"),
    ]
    let updates = [meal(nil, "Monday", monday, "lunch", "")]
    let merged = MealMergeResolver.fold(updates: updates, into: existing)

    #expect(merged.count == 2)
    #expect(!merged.contains { $0.dayName == "Monday" && $0.slot == "lunch" })
    #expect(merged.contains { $0.mealId == "m1" })
    #expect(merged.contains { $0.mealId == "m3" })
}

@Test("clearing a slot that has no existing meal is a no-op")
func clearMissingSlotIsNoOp() {
    let existing = [meal("m1", "Monday", monday, "breakfast", "Oatmeal")]
    let updates = [meal(nil, "Friday", friday, "dinner", "")]
    let merged = MealMergeResolver.fold(updates: updates, into: existing)
    #expect(merged.count == 1)
    #expect(merged == existing)
}

@Test("a new day+slot not present in the existing week is appended")
func addNewSlot() {
    let existing = [meal("m1", "Monday", monday, "breakfast", "Oatmeal")]
    let updates = [meal(nil, "Friday", friday, "dinner", "Pizza")]
    let merged = MealMergeResolver.fold(updates: updates, into: existing)

    #expect(merged.count == 2)
    #expect(merged.contains { $0.mealId == "m1" })
    let addedFriday = merged.first { $0.dayName == "Friday" && $0.slot == "dinner" }
    #expect(addedFriday?.recipeName == "Pizza")
    #expect(addedFriday?.mealId == nil)   // brand-new slot → no existing record to preserve
}

@Test("folding the same updates twice is idempotent")
func idempotence() {
    let existing = [
        meal("m1", "Monday", monday, "breakfast", "Oatmeal"),
        meal("m2", "Tuesday", tuesday, "dinner", "Stew"),
    ]
    let updates = [
        meal(nil, "Monday", monday, "breakfast", "Pancakes"),
        meal(nil, "Wednesday", wednesday, "lunch", "Soup"),
        meal(nil, "Tuesday", tuesday, "dinner", ""),   // clear
    ]
    let once = MealMergeResolver.fold(updates: updates, into: existing)
    let twice = MealMergeResolver.fold(updates: updates, into: once)
    #expect(twice == once)
}

@Test("passing the full current meal set through (old full-replace shape) round-trips unchanged")
func fullSetPassthrough() {
    let existing = [
        meal("m1", "Monday", monday, "breakfast", "Oatmeal"),
        meal("m2", "Monday", monday, "lunch", "Salad"),
        meal("m3", "Tuesday", tuesday, "dinner", "Stew"),
    ]
    // The model echoes back every meal (e.g. a pre-merge-fix caller) without ids.
    let updates = existing.map { meal(nil, $0.dayName, $0.mealDate, $0.slot, $0.recipeName) }
    let merged = MealMergeResolver.fold(updates: updates, into: existing)

    #expect(merged.count == existing.count)
    #expect(Set(merged.map(\.mealId)) == Set(existing.map(\.mealId)))   // ids preserved by slot lookup
    #expect(merged == existing)
}
