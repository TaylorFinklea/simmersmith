import Testing
@testable import GroceryMerge

// The field-merge resolver (SP-A §5) — generalizes Spike 1's groceryResolver.
// These re-prove the Spike-1 invariants on the production-shaped models and extend
// them to the check-state triple, event records, and the manual-merge pin.

private func auto(_ name: String, qty: Double, at: SyncClock) -> GroceryItem {
    GroceryItem(recordName: "X", quantityText: String(qty), normalizedName: name,
                totalQuantity: qty, sourceMeals: "meal:dinner", createdAt: 1, modifiedAt: at)
}

// MARK: - GroceryItem sticky fields

@Test("tombstone is monotonic — a stale regen can't resurrect it")
func tombstoneMonotonic() {
    var removed = auto("tomato", qty: 2, at: 5); removed.isUserRemoved = true
    let refreshed = auto("tomato", qty: 2, at: 9)   // later write, not removed
    #expect(FieldMergeResolver.merge(removed, refreshed).isUserRemoved == true)
    #expect(FieldMergeResolver.merge(refreshed, removed).isUserRemoved == true)  // order-independent
}

@Test("quantity override survives a concurrent regen")
func overrideSticky() {
    var overridden = auto("tomato", qty: 2, at: 5); overridden.quantityOverride = 5
    let refreshed = auto("tomato", qty: 2, at: 9)
    #expect(FieldMergeResolver.merge(overridden, refreshed).quantityOverride == 5)
}

@Test("event_quantity is never dropped by a stale regen")
func eventQuantityWriterOwned() {
    var merged = auto("tomato", qty: 2, at: 5); merged.eventQuantity = 3
    let refreshed = auto("tomato", qty: 2, at: 9)  // regen carries nil
    #expect(FieldMergeResolver.merge(merged, refreshed).eventQuantity == 3)
}

@Test("check-state triple resolves as a unit (never tears)")
func checkStateTripleAtomic() {
    var checkedByAlice = auto("tomato", qty: 2, at: 5)
    checkedByAlice.check = CheckState(isChecked: true, at: 10, by: "Alice")
    var uncheckedLater = auto("tomato", qty: 2, at: 6)
    uncheckedLater.check = CheckState(isChecked: false, at: 12, by: nil)  // later check-state write
    let m = FieldMergeResolver.merge(checkedByAlice, uncheckedLater).check
    // the later (uncheck) triple wins as a whole — not is_checked=false + by=Alice
    #expect(m.isChecked == false)
    #expect(m.by == nil)
}

// MARK: - EventGroceryItem

@Test("event link prefers a live merge pointer over a concurrent nil (unmerge)")
func eventLinkPrefersLivePointer() {
    let merged = EventGroceryItem(recordName: "E", mergedIntoGroceryItemID: "G1",
                                  mergedIntoWeekID: "W1", eventQuantity: 3, modifiedAt: 5)
    let unmergedStale = EventGroceryItem(recordName: "E", mergedIntoGroceryItemID: nil,
                                         mergedIntoWeekID: nil, eventQuantity: nil, modifiedAt: 4)
    let m = FieldMergeResolver.merge(merged, unmergedStale)
    #expect(m.mergedIntoGroceryItemID == "G1")
    #expect(m.eventQuantity == 3)
}

// MARK: - Event pin

@Test("manually_merged pin is sticky against a concurrent unrelated edit")
func manualMergePinSticky() {
    let pinned = Event(recordName: "EV", manuallyMerged: true, modifiedAt: 5)
    var movedDate = Event(recordName: "EV", eventDate: "2026-07-04", manuallyMerged: false, modifiedAt: 9)
    movedDate.autoMergeGrocery = false
    #expect(FieldMergeResolver.merge(pinned, movedDate).manuallyMerged == true)
    #expect(FieldMergeResolver.merge(movedDate, pinned).manuallyMerged == true)
}

// MARK: - Pass-through

@Test("plain pass-through records are last-writer-wins")
func passthroughLWW() {
    let a = Week(recordName: "W", weekStart: "2026-06-15", modifiedAt: 3)
    let b = Week(recordName: "W", weekStart: "2026-06-22", modifiedAt: 7)
    #expect(FieldMergeResolver.lww(a, b).weekStart == "2026-06-22")
}
