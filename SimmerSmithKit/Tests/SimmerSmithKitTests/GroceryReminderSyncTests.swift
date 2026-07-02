import Foundation
import Testing
@testable import SimmerSmithKit

// simmersmith-990.7 — headless tests for GroceryReminderSync, the pure logic extracted out
// of AppState+Reminders.swift / RemindersService.swift so the grocery ↔ Reminders bridge's
// title format, mapping match/cleanup, and check-state merge rules unit-test without
// EventKit or CloudKit in the loop.

// MARK: - Title / body formatting round-trip

@Test("title is the trimmed ingredient name — the frozen cart-automation contract")
func titleIsTrimmedName() {
    #expect(GroceryReminderSync.title(ingredientName: "  fresh dill  ") == "fresh dill")
    #expect(GroceryReminderSync.title(ingredientName: "Avocados") == "Avocados")
}

@Test("body first line round-trips quantity + unit for a plain case")
func bodyRoundTripsQuantityAndUnit() {
    let body = GroceryReminderSync.body(
        quantity: 2, unit: "cup", quantityText: "", storeLabel: "", sourceMeals: "", notesOverride: nil
    )
    #expect(body == "2 cup")
}

@Test("body formats common kitchen fractions and round-trips back to the source decimal")
func bodyFractionRoundTrip() {
    // (decimal quantity, expected fraction label)
    let cases: [(Double, String)] = [
        (0.5, "1/2"), (0.25, "1/4"), (0.75, "3/4"), (1.5, "1 1/2"), (0.125, "1/8"),
    ]
    for (decimal, label) in cases {
        let formatted = GroceryReminderSync.formatQuantity(decimal)
        #expect(formatted == label)
        // Round-trip: parse the formatted label back into a decimal (whole + fraction) and
        // confirm it matches the value that was formatted.
        let parts = formatted.split(separator: " ")
        let wholePart: Double
        let fractionPart: String
        if parts.count == 2 {
            wholePart = Double(parts[0]) ?? 0
            fractionPart = String(parts[1])
        } else {
            wholePart = 0
            fractionPart = String(parts[0])
        }
        let fractionPieces = fractionPart.split(separator: "/")
        let fractionValue = (Double(fractionPieces[0])!) / (Double(fractionPieces[1])!)
        #expect(abs((wholePart + fractionValue) - decimal) < 0.01)
    }
}

@Test("body falls back to quantityText, then bare unit, when quantity is nil")
func bodyDegenerateQuantityCases() {
    #expect(GroceryReminderSync.body(
        quantity: nil, unit: "", quantityText: "a splash", storeLabel: "", sourceMeals: "", notesOverride: nil
    ) == "a splash")
    #expect(GroceryReminderSync.body(
        quantity: nil, unit: "pkg", quantityText: "", storeLabel: "", sourceMeals: "", notesOverride: nil
    ) == "pkg")
    #expect(GroceryReminderSync.body(
        quantity: nil, unit: "", quantityText: "", storeLabel: "", sourceMeals: "", notesOverride: nil
    ) == "")
}

@Test("body prefixes the store line and appends meal + notes lines in order")
func bodyComposesAllLines() {
    let body = GroceryReminderSync.body(
        quantity: 1,
        unit: "bag",
        quantityText: "",
        storeLabel: "Aldi",
        sourceMeals: "Tuesday / Dinner / Chili; Wednesday / Lunch",
        notesOverride: "get the low-sodium kind"
    )
    #expect(body == "At Aldi\n1 bag\nFor: Tuesday Dinner — Chili; Wednesday Lunch\nget the low-sodium kind")
}

@Test("normalizedTitle collapses whitespace, case, and trailing punctuation")
func normalizedTitleCanonicalizes() {
    #expect(GroceryReminderSync.normalizedTitle("  Fresh Dill.  ") == "fresh dill")
    #expect(GroceryReminderSync.normalizedTitle("Paper Towels!") == GroceryReminderSync.normalizedTitle("paper towels"))
}

// MARK: - Mapping match (mapping survives an id-preserving upsert)

@Test("match resolves an id-mapped reminder whose grocery item is still present")
func matchResolvesExistingMapping() {
    let result = GroceryReminderSync.match(
        reminderID: "reminder-1",
        reminderTitle: "anything — id mapping wins first",
        reverseMapping: ["reminder-1": "grocery-A"],
        serverItemIDs: ["grocery-A", "grocery-B"],
        serverItemIDsByNormalizedTitle: [:]
    )
    #expect(result == .mapped(groceryItemID: "grocery-A"))
}

@Test("mapping survives an id-preserving regen upsert — same grocery_item_id, no rebind needed")
func mappingSurvivesIDPreservingUpsert() {
    // Simulates GroceryRepository.regenerate/saveItem preserving `recordName` (== groceryItemId)
    // across a regen: the mapping (grocery_item_id -> reminder id) built before the regen still
    // resolves the SAME reminder to the SAME grocery item after the CloudKit rows are upserted.
    let mappingBeforeRegen = ["grocery-A": "reminder-1"]
    let reverseMapping = Dictionary(uniqueKeysWithValues: mappingBeforeRegen.map { ($0.value, $0.key) })
    // Regen preserved the id, so "grocery-A" is still a valid server item afterward.
    let serverItemIDsAfterRegen: Set<String> = ["grocery-A"]

    let result = GroceryReminderSync.match(
        reminderID: "reminder-1",
        reminderTitle: "flour",
        reverseMapping: reverseMapping,
        serverItemIDs: serverItemIDsAfterRegen,
        serverItemIDsByNormalizedTitle: [:]
    )
    #expect(result == .mapped(groceryItemID: "grocery-A"))
}

@Test("match falls back to title-rebind only when there was no existing id mapping")
func matchTitleRebindOnlyWithoutExistingMapping() {
    let result = GroceryReminderSync.match(
        reminderID: "reminder-new-identifier",
        reminderTitle: "Fresh Dill",
        reverseMapping: [:],
        serverItemIDs: ["grocery-A"],
        serverItemIDsByNormalizedTitle: ["fresh dill": "grocery-A"]
    )
    #expect(result == .titleRebind(groceryItemID: "grocery-A"))
}

@Test("match does NOT fall back to title-rebind when the reminder is already id-mapped")
func matchDoesNotTitleRebindWhenIDMapped() {
    // Mapped id points at a grocery item that's gone server-side; even though the title would
    // otherwise resolve via rebind, the original inline control flow never attempts it once an
    // id-mapping exists — it falls straight to `.unmatched` (caller re-creates as new).
    let result = GroceryReminderSync.match(
        reminderID: "reminder-1",
        reminderTitle: "Fresh Dill",
        reverseMapping: ["reminder-1": "grocery-gone"],
        serverItemIDs: ["grocery-A"],
        serverItemIDsByNormalizedTitle: ["fresh dill": "grocery-A"]
    )
    #expect(result == .unmatched)
}

@Test("match returns unmatched for a genuinely new reminder")
func matchUnmatchedForNewReminder() {
    let result = GroceryReminderSync.match(
        reminderID: "reminder-brand-new",
        reminderTitle: "Balloons",
        reverseMapping: [:],
        serverItemIDs: ["grocery-A"],
        serverItemIDsByNormalizedTitle: ["fresh dill": "grocery-A"]
    )
    #expect(result == .unmatched)
}

// MARK: - Stale-mapping cleanup

@Test("staleMappingIDs drops entries not seen this pass whose reminder is gone")
func staleMappingIDsDropsGoneReminders() {
    let mapping = ["grocery-A": "reminder-1", "grocery-B": "reminder-2", "grocery-C": "reminder-3"]
    let stale = GroceryReminderSync.staleMappingIDs(
        mapping: mapping,
        seenGroceryItemIDs: ["grocery-A"],       // B and C weren't matched this pass
        presentReminderIDs: ["reminder-1", "reminder-2"]  // reminder-3 no longer exists
    )
    #expect(stale == ["grocery-C"])
}

@Test("staleMappingIDs keeps an unseen entry whose reminder is still present")
func staleMappingIDsKeepsPresentReminder() {
    let mapping = ["grocery-A": "reminder-1"]
    let stale = GroceryReminderSync.staleMappingIDs(
        mapping: mapping,
        seenGroceryItemIDs: [],
        presentReminderIDs: ["reminder-1"]
    )
    #expect(stale.isEmpty)
}

// MARK: - Check-state two-way merge

@Test("reminderCheckStateShouldPropagate: pull direction pushes a diff, ignores a match")
func checkStateTwoWayMerge() {
    #expect(GroceryReminderSync.reminderCheckStateShouldPropagate(reminderIsCompleted: true, itemIsChecked: false))
    #expect(GroceryReminderSync.reminderCheckStateShouldPropagate(reminderIsCompleted: false, itemIsChecked: true))
    #expect(!GroceryReminderSync.reminderCheckStateShouldPropagate(reminderIsCompleted: true, itemIsChecked: true))
    #expect(!GroceryReminderSync.reminderCheckStateShouldPropagate(reminderIsCompleted: false, itemIsChecked: false))
}
