import Testing
@testable import GroceryMerge

// SP-A Phase 5 — verifies the event↔week port against the prod event_grocery.py scenarios.

private func counter() -> () -> String { var n = 0; return { n += 1; return "new-\(n)" } }

// MARK: match keys + unit normalization

@Test func matchKeyPrefersBaseIDElseName_andNormalizesUnit() {
    let withID = EventMergeEngine.matchKeys(baseIngredientID: "b1", normalizedName: "tomato", unit: "pounds")
    #expect(withID.base == EventMergeEngine.MatchKey(a: "b1", b: "lb", c: ""))   // pounds → lb
    #expect(withID.name == EventMergeEngine.MatchKey(a: "tomato", b: "lb", c: ""))
    let noID = EventMergeEngine.matchKeys(baseIngredientID: nil, normalizedName: "tomato", unit: "cups")
    #expect(noID.base == EventMergeEngine.MatchKey(a: "", b: "cup", c: "tomato"))
}

// MARK: merge_event_into_week

@Test func mergeAddsContributionToMatchingWeekRow() {
    let week = [GroceryItem(recordName: "G1", weekID: "W", baseIngredientID: "b1",
                            unit: "cup", normalizedName: "tomato", totalQuantity: 2)]
    let ev = [EventGroceryItem(recordName: "E1", eventQuantity: 3, baseIngredientID: "b1",
                               normalizedName: "tomato", unit: "cup")]
    let out = EventMergeEngine.mergeEventIntoWeek(event: Event(recordName: "EV", name: "Party"),
                                                  eventRows: ev, weekRows: week, weekID: "W", makeID: counter())
    #expect(out.matched == 1 && out.created == 0)
    #expect(out.weekRows.first { $0.recordName == "G1" }?.eventQuantity == 3)
    #expect(out.eventRows[0].mergedIntoWeekID == "W")
    #expect(out.eventRows[0].mergedIntoGroceryItemID == "G1")
    #expect(out.linkedWeekID == "W")
}

@Test func mergeCreatesEventOnlyRowWhenNoMatch() {
    let ev = [EventGroceryItem(recordName: "E1", eventQuantity: 5, ingredientName: "Sea Salt",
                               normalizedName: "salt", unit: "ea", category: "Pantry")]
    let out = EventMergeEngine.mergeEventIntoWeek(event: Event(recordName: "EV", name: "Party"),
                                                  eventRows: ev, weekRows: [], weekID: "W", makeID: counter())
    #expect(out.created == 1)
    let created = out.weekRows.first { $0.recordName == "new-1" }
    #expect(created?.eventQuantity == 5)
    #expect(created?.totalQuantity == nil)
    #expect(created?.sourceMeals == "event:Party")
    #expect(created?.weekID == "W")
    #expect(created?.ingredientName == "Sea Salt")   // display name carried (review fix)
    #expect(created?.category == "Pantry")           // category carried (review fix)
    #expect(out.eventRows[0].mergedIntoGroceryItemID == "new-1")
}

@Test func mergeIsIdempotent_noDoubleCount() {
    // The 3→6→9 guard: re-merging already-merged rows must NOT re-add the contribution.
    let event = Event(recordName: "EV", name: "Party")
    let week = [GroceryItem(recordName: "G1", weekID: "W", baseIngredientID: "b1", unit: "cup", normalizedName: "tomato", totalQuantity: 2)]
    let ev = [EventGroceryItem(recordName: "E1", eventQuantity: 3, baseIngredientID: "b1", normalizedName: "tomato", unit: "cup")]
    let first = EventMergeEngine.mergeEventIntoWeek(event: event, eventRows: ev, weekRows: week, weekID: "W", makeID: counter())
    let second = EventMergeEngine.mergeEventIntoWeek(event: event, eventRows: first.eventRows, weekRows: first.weekRows, weekID: "W", makeID: counter())
    #expect(second.matched == 0)   // skipped — already merged
    #expect(second.weekRows.first { $0.recordName == "G1" }?.eventQuantity == 3)   // NOT 6
}

@Test func mergeTextOnlyContributionMarksMergedWithoutAdding() {
    let ev = [EventGroceryItem(recordName: "E1", eventQuantity: nil, normalizedName: "salt", unit: "to taste")]
    let out = EventMergeEngine.mergeEventIntoWeek(event: Event(recordName: "EV", name: "P"),
                                                  eventRows: ev, weekRows: [], weekID: "W", makeID: counter())
    #expect(out.unmatchedTextOnly == 1 && out.created == 0)
    #expect(out.eventRows[0].mergedIntoWeekID == "W")
    #expect(out.eventRows[0].mergedIntoGroceryItemID == nil)
}

// MARK: unmerge_event_from_week — HARD delete, not tombstone

@Test func unmergeHardDeletesEmptyEventOnlyRow() {
    let week = [GroceryItem(recordName: "Gn", weekID: "W", normalizedName: "salt", sourceMeals: "event:Party", eventQuantity: 5)]
    let ev = [EventGroceryItem(recordName: "E1", mergedIntoGroceryItemID: "Gn", mergedIntoWeekID: "W",
                               eventQuantity: 5, normalizedName: "salt")]
    let out = EventMergeEngine.unmergeEventFromWeek(eventRows: ev, weekRows: week, weekID: "W",
                                                    eventName: "Party", currentLinkedWeekID: "W")
    #expect(out.hardDeletedRecordNames == ["Gn"])        // HARD delete (not a tombstone)
    #expect(out.weekRows.isEmpty)
    #expect(out.eventRows[0].mergedIntoWeekID == nil)
    #expect(out.clearedLink == true && out.linkedWeekID == nil)
}

@Test func unmergeKeepsInvestedEventOnlyRow() {
    // A checked event-only row must survive unmerge (user investment).
    let week = [GroceryItem(recordName: "Gn", weekID: "W", normalizedName: "salt", sourceMeals: "event:Party",
                            check: CheckState(isChecked: true, at: 5), eventQuantity: 5)]
    let ev = [EventGroceryItem(recordName: "E1", mergedIntoGroceryItemID: "Gn", mergedIntoWeekID: "W", eventQuantity: 5)]
    let out = EventMergeEngine.unmergeEventFromWeek(eventRows: ev, weekRows: week, weekID: "W",
                                                    eventName: "Party", currentLinkedWeekID: "W")
    #expect(out.hardDeletedRecordNames.isEmpty)
    #expect(out.weekRows.first { $0.recordName == "Gn" }?.eventQuantity == nil)   // contribution removed, row kept
}

@Test func unmergeKeepsRealMealRow() {
    // A row with a week-meal contribution (totalQuantity) is never event-only → never deleted.
    let week = [GroceryItem(recordName: "G1", weekID: "W", normalizedName: "tomato", totalQuantity: 2,
                            sourceMeals: "meal:mon", eventQuantity: 3)]
    let ev = [EventGroceryItem(recordName: "E1", mergedIntoGroceryItemID: "G1", mergedIntoWeekID: "W", eventQuantity: 3)]
    let out = EventMergeEngine.unmergeEventFromWeek(eventRows: ev, weekRows: week, weekID: "W",
                                                    eventName: "Party", currentLinkedWeekID: "W")
    #expect(out.hardDeletedRecordNames.isEmpty)
    let g1 = out.weekRows.first { $0.recordName == "G1" }
    #expect(g1?.totalQuantity == 2 && g1?.eventQuantity == nil)
}

// MARK: _resolve_target_week

@Test func resolveTargetWeekPrefersLinkThenLatestCovering() {
    let w1 = Week(recordName: "W1", weekStart: "2026-06-29", weekEnd: "2026-07-05")
    let w2 = Week(recordName: "W2", weekStart: "2026-07-01", weekEnd: "2026-07-12")  // overlaps w1
    // explicit link wins
    #expect(EventMergeEngine.resolveTargetWeek(event: Event(recordName: "E", linkedWeekID: "W2"), weeks: [w1, w2])?.recordName == "W2")
    // date in overlap → latest-starting (w2)
    #expect(EventMergeEngine.resolveTargetWeek(event: Event(recordName: "E", eventDate: "2026-07-04"), weeks: [w1, w2])?.recordName == "W2")
    // no date → nil
    #expect(EventMergeEngine.resolveTargetWeek(event: Event(recordName: "E", eventDate: ""), weeks: [w1, w2]) == nil)
}

// MARK: apply_auto_merge_policy branches

@Test func policyManuallyMergedMergesLinkedNeverUnmerges() {
    let event = Event(recordName: "EV", name: "Party", eventDate: "2026-09-09", linkedWeekID: "W1",
                      manuallyMerged: true, autoMergeGrocery: false)
    let ev = [EventGroceryItem(recordName: "E1", eventQuantity: 3, baseIngredientID: "b1", normalizedName: "tomato", unit: "cup")]
    let week = [GroceryItem(recordName: "G1", weekID: "W1", baseIngredientID: "b1", unit: "cup", normalizedName: "tomato", totalQuantity: 2)]
    let out = EventMergeEngine.applyAutoMergePolicy(
        event: event, eventRows: ev,
        weeksByID: ["W1": Week(recordName: "W1", weekStart: "2026-01-01", weekEnd: "2026-12-31")],
        weekRowsByID: ["W1": week], makeID: counter())
    #expect(out.event.linkedWeekID == "W1")
    #expect(out.weekRowsByID["W1"]?.first { $0.recordName == "G1" }?.eventQuantity == 3)
    #expect(out.hardDeletedRecordNames.isEmpty)
}

@Test func policyAutoMergeReDatedUnmergesOldThenMergesNew() {
    // Event was merged into W1; its date moved into W2's range. Policy must unmerge W1 + merge W2.
    let event = Event(recordName: "EV", name: "Party", eventDate: "2026-07-10", linkedWeekID: "W1",
                      manuallyMerged: false, autoMergeGrocery: true)
    let ev = [EventGroceryItem(recordName: "E1", mergedIntoGroceryItemID: "Gn", mergedIntoWeekID: "W1",
                               eventQuantity: 5, normalizedName: "salt", unit: "ea")]
    let w1Rows = [GroceryItem(recordName: "Gn", weekID: "W1", normalizedName: "salt", sourceMeals: "event:Party", eventQuantity: 5)]
    let out = EventMergeEngine.applyAutoMergePolicy(
        event: event, eventRows: ev,
        weeksByID: ["W1": Week(recordName: "W1", weekStart: "2026-06-29", weekEnd: "2026-07-05"),
                    "W2": Week(recordName: "W2", weekStart: "2026-07-06", weekEnd: "2026-07-12")],
        weekRowsByID: ["W1": w1Rows, "W2": []], makeID: counter())
    #expect(out.event.linkedWeekID == "W2")                 // re-resolved onto the covering week
    #expect(out.hardDeletedRecordNames == ["Gn"])           // old event-only row hard-deleted on unmerge
    #expect(out.weekRowsByID["W2"]?.contains { $0.eventQuantity == 5 } == true)   // re-created in W2
}

@Test func policyAutoMergeOffUnmergesLinked() {
    let event = Event(recordName: "EV", name: "Party", eventDate: "2026-07-02", linkedWeekID: "W1",
                      manuallyMerged: false, autoMergeGrocery: false)
    let ev = [EventGroceryItem(recordName: "E1", mergedIntoGroceryItemID: "Gn", mergedIntoWeekID: "W1", eventQuantity: 5)]
    let w1Rows = [GroceryItem(recordName: "Gn", weekID: "W1", normalizedName: "salt", sourceMeals: "event:Party", eventQuantity: 5)]
    let out = EventMergeEngine.applyAutoMergePolicy(
        event: event, eventRows: ev,
        weeksByID: ["W1": Week(recordName: "W1", weekStart: "2026-06-29", weekEnd: "2026-07-05")],
        weekRowsByID: ["W1": w1Rows], makeID: counter())
    #expect(out.event.linkedWeekID == nil)                  // teardown cleared the link
    #expect(out.hardDeletedRecordNames == ["Gn"])
}
