import Testing
@testable import GroceryMerge

// Cross-record conflict-repair (SP-A §5.3). The headline is the dedupe keeper +
// EventGroceryItem repointing — the M68 regression the adversarial review caught.

// MARK: - Grocery dedupe (M68)

@Test("dedupe keeps the auto-aggregated row and repoints event links onto it")
func dedupeSemanticKeeperAndRepoint() {
    // two rows collapse on (normalized_name, unit): an auto-aggregated meal row and
    // a stray duplicate created later. An event link points at the stray.
    let autoRow = GroceryItem(recordName: "G_auto", unit: "cup", normalizedName: "tomato",
                              totalQuantity: 2, sourceMeals: "meal:dinner", createdAt: 1)
    let stray = GroceryItem(recordName: "G_stray", unit: "cup", normalizedName: "tomato",
                            totalQuantity: 1, sourceMeals: "", createdAt: 9)
    let link = EventGroceryItem(recordName: "E1", mergedIntoGroceryItemID: "G_stray",
                                eventQuantity: 3, modifiedAt: 1)

    let r = ConflictRepair.dedupeGrocery(items: [autoRow, stray], eventLinks: [link])

    // keeper is the auto-aggregated row (NOT the lower recordName "G_auto" by luck —
    // assert the semantic policy: source_meals-populated wins)
    #expect(r.keepers.count == 1)
    #expect(r.keepers[0].recordName == "G_auto")
    #expect(r.deletedRecordNames == ["G_stray"])
    // the M68 fix: the event link is repointed onto the keeper, not left dangling
    #expect(r.repointedLinks.count == 1)
    #expect(r.repointedLinks[0].mergedIntoGroceryItemID == "G_auto")
    // rolled-up quantity
    #expect(r.keepers[0].totalQuantity == 3)   // 2 + 1
}

@Test("dedupe with no duplicates is a no-op")
func dedupeNoDuplicates() {
    let a = GroceryItem(recordName: "G1", unit: "cup", normalizedName: "tomato", sourceMeals: "m")
    let b = GroceryItem(recordName: "G2", unit: "lb", normalizedName: "beef", sourceMeals: "m")
    let r = ConflictRepair.dedupeGrocery(items: [a, b], eventLinks: [])
    #expect(r.keepers.count == 2)
    #expect(r.deletedRecordNames.isEmpty)
    #expect(r.repointedLinks.isEmpty)
}

@Test("dedupe falls back to earliest-created when no auto-aggregated row exists")
func dedupeEarliestFallback() {
    let userA = GroceryItem(recordName: "Gb", unit: "", normalizedName: "salt",
                            isUserAdded: true, createdAt: 2)
    let userB = GroceryItem(recordName: "Ga", unit: "", normalizedName: "salt",
                            isUserAdded: true, createdAt: 5)
    let r = ConflictRepair.dedupeGrocery(items: [userA, userB], eventLinks: [])
    #expect(r.keepers.count == 1)
    #expect(r.keepers[0].recordName == "Gb")   // earliest createdAt (2)
}

// MARK: - Duplicate slot repair

@Test("two meals in one slot get separated; never two-in-one")
func duplicateSlotRepair() {
    let m1 = WeekMeal(recordName: "M1", weekID: "W", dayName: "Mon", slot: "dinner", sortOrder: 0)
    let m2 = WeekMeal(recordName: "M2", weekID: "W", dayName: "Mon", slot: "dinner", sortOrder: 1)
    let fixed = ConflictRepair.repairDuplicateSlots([m1, m2], slots: ["breakfast", "lunch", "dinner"])
    let monSlots = fixed.filter { $0.dayName == "Mon" }.map(\.slot)
    #expect(Set(monSlots).count == 2)            // no collision
    #expect(monSlots.contains("dinner"))         // keeper (lower sortOrder) stays
}

@Test("slot repair falls back to a synthetic slot when the vocabulary is full")
func slotRepairSyntheticFallback() {
    let a = WeekMeal(recordName: "Ma", weekID: "W", dayName: "Tue", slot: "dinner", sortOrder: 0)
    let b = WeekMeal(recordName: "Mb", weekID: "W", dayName: "Tue", slot: "dinner", sortOrder: 1)
    let fixed = ConflictRepair.repairDuplicateSlots([a, b], slots: ["dinner"])  // only one slot
    #expect(Set(fixed.map(\.slot)).count == 2)
}

// MARK: - Duplicate week collapse

@Test("same week_start collapses to the lowest recordName")
func duplicateWeekCollapse() {
    let w1 = Week(recordName: "Wb", weekStart: "2026-06-15")
    let w2 = Week(recordName: "Wa", weekStart: "2026-06-15")
    let w3 = Week(recordName: "Wc", weekStart: "2026-06-22")   // distinct, untouched
    let out = ConflictRepair.collapseDuplicateWeeks([w1, w2, w3])
    #expect(out.count == 1)
    #expect(out[0].keeper == "Wa")
    #expect(out[0].losers == ["Wb"])
}

// MARK: - Sort reconcile + dangling null

@Test("sort order is reconciled gap-free and stable")
func sortReconcile() {
    let meals = [
        WeekMeal(recordName: "Mc", weekID: "W", dayName: "Mon", slot: "d", sortOrder: 5),
        WeekMeal(recordName: "Ma", weekID: "W", dayName: "Mon", slot: "l", sortOrder: 5),  // collision
        WeekMeal(recordName: "Mb", weekID: "W", dayName: "Mon", slot: "b", sortOrder: 2),
    ]
    let r = ConflictRepair.reconcileSortOrder(meals)
    #expect(r.map(\.sortOrder) == [0, 1, 2])
    // stable on (sortOrder, recordName): Mb(2) first, then Ma/Mc tie broken by name
    #expect(r.map(\.recordName) == ["Mb", "Ma", "Mc"])
}

@Test("dangling soft ref is nulled, live ref preserved")
func danglingNull() {
    #expect(ConflictRepair.nullingDangling("R1", existing: ["R1", "R2"]) == "R1")
    #expect(ConflictRepair.nullingDangling("R9", existing: ["R1", "R2"]) == nil)
    #expect(ConflictRepair.nullingDangling(nil, existing: ["R1"]) == nil)
}
