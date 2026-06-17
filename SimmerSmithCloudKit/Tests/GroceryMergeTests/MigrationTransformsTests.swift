import Foundation
import Testing
@testable import GroceryMerge

// SP-A Phase 7 — the per-type migration transforms (fanned out across the 5-model fleet, then
// normalized + verified here). Each transform: legacy JSON row → CloudKit value type, defensive.

@Test func migrateEventGroceryItem_renamesTotalQuantityAndIsDefensive() {
    let row: [String: Any] = [
        "id": "E1", "merged_into_grocery_item_id": "G7", "merged_into_week_id": NSNull(),
        "total_quantity": NSNumber(value: 4.5), "base_ingredient_id": "b1",
        "ingredient_name": "Tomato", "normalized_name": "tomato", "unit": "cup",
        "source_meals": "event:Party", "resolution_status": "locked", "updated_at_clock": NSNumber(value: 9)]
    let got = migrateEventGroceryItem(row)
    #expect(got?.recordName == "E1")
    #expect(got?.eventQuantity == 4.5)              // prod total_quantity -> eventQuantity
    #expect(got?.mergedIntoGroceryItemID == "G7")
    #expect(got?.mergedIntoWeekID == nil)           // NSNull -> nil
    #expect(got?.ingredientName == "Tomato" && got?.unit == "cup")
    #expect(got?.resolutionStatus == "locked" && got?.modifiedAt == 9)
    #expect(migrateEventGroceryItem(["total_quantity": NSNumber(value: 1)]) == nil)   // no id -> nil
}

@Test func migrateEvent_autoMergeDefaultsTrueAndBoolFromInt() {
    let full: [String: Any] = ["id": "EV1", "name": "Party", "event_date": "2026-07-04",
        "linked_week_id": "W1", "manually_merged": NSNumber(value: 1), "auto_merge_grocery": NSNumber(value: 0),
        "updated_at_clock": NSNumber(value: 5)]
    let got = migrateEvent(full)
    #expect(got == Event(recordName: "EV1", name: "Party", eventDate: "2026-07-04",
                         linkedWeekID: "W1", manuallyMerged: true, autoMergeGrocery: false, modifiedAt: 5))
    // auto_merge_grocery MISSING -> defaults TRUE; event_date null -> ""
    let minimal = migrateEvent(["id": "EV2", "event_date": NSNull()])
    #expect(minimal == Event(recordName: "EV2", autoMergeGrocery: true))
    #expect(migrateEvent([:]) == nil)
}

@Test func migrateWeek_mapsRange() {
    #expect(migrateWeek(["id": "W1", "week_start": "2026-06-29", "week_end": "2026-07-05",
                         "updated_at_clock": NSNumber(value: 3)])
            == Week(recordName: "W1", weekStart: "2026-06-29", weekEnd: "2026-07-05", modifiedAt: 3))
    #expect(migrateWeek(["week_start": "x"]) == nil)
}

@Test func migrateWeekMeal_mapsSlotAndSortOrder() {
    #expect(migrateWeekMeal(["id": "M1", "week_id": "W1", "day_name": "Monday", "slot": "dinner",
                             "sort_order": NSNumber(value: 2), "updated_at_clock": NSNumber(value: 8)])
            == WeekMeal(recordName: "M1", weekID: "W1", dayName: "Monday", slot: "dinner", sortOrder: 2, modifiedAt: 8))
    #expect(migrateWeekMeal(["id": ""]) == nil)
}

@Test func migrateWeekChangeBatch_maps() {
    #expect(migrateWeekChangeBatch(["id": "B1", "week_id": "W1", "created_at_clock": NSNumber(value: 42)])
            == WeekChangeBatch(recordName: "B1", weekID: "W1", createdAt: 42))
    #expect(migrateWeekChangeBatch(["week_id": "W1"]) == nil)
}
