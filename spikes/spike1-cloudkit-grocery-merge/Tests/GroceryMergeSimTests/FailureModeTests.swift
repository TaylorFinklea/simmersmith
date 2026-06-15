import Testing
@testable import GroceryMergeSim

// Spike 1 — does the grocery smart-merge survive CloudKit's conflict model?
//
// Each failure mode runs the SAME two-replica concurrent scenario under both
// sync models:
//   • .lastWriterWins  → NSPersistentCloudKitContainer (blanket record LWW)
//   • .fieldMerge       → CKSyncEngine + the proposed groceryResolver
//
// The assertions document, deterministically, that blanket LWW corrupts the
// "sticky" fields (tombstone / override / event_quantity) while field-merge
// preserves them — and that plain-value fields (check state) are fine under LWW.

// MARK: - Scenario helpers

private func seedSynced(_ replicas: [Replica], _ fabric: SyncFabric, items: [GroceryItem]) {
    var store: [String: GroceryItem] = [:]
    for item in items { store[item.id] = item }
    for replica in replicas { replica.load(store) }
    fabric.seedServer(store)
}

/// Push two replicas in the given order, then pull both — the steady state every
/// CloudKit peer eventually reaches.
private func converge(_ first: Replica, _ second: Replica, _ fabric: SyncFabric) {
    fabric.push(first)
    fabric.push(second)
    fabric.pull(first)
    fabric.pull(second)
}

private func autoItem(id: String, name: String, qty: Double, clock: ClockSource) -> GroceryItem {
    GroceryItem(
        id: id,
        resolutionStatus: "unresolved",
        unit: "",
        quantityText: String(qty),
        normalizedName: name,
        totalQuantity: qty,
        sourceMeals: "meal:dinner",
        modifiedAt: clock.next()
    )
}

private func freshRow(name: String, qty: Double) -> FreshRow {
    FreshRow(
        resolutionStatus: "unresolved",
        unit: "",
        quantityText: String(qty),
        normalizedName: name,
        totalQuantity: qty,
        sourceMeals: "meal:dinner"
    )
}

private func world(_ mode: SyncMode) -> (a: Replica, b: Replica, fabric: SyncFabric, clock: ClockSource) {
    let clock = ClockSource()
    return (Replica(name: "A", clock: clock), Replica(name: "B", clock: clock), SyncFabric(mode: mode), clock)
}

// MARK: - Failure mode 1 — tombstone resurrection

@Test("LWW resurrects a tombstone when a stale regen writes last")
func tombstoneResurrectsUnderLWW() {
    let (a, b, fabric, clock) = world(.lastWriterWins)
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    a.removeItem("X")                                       // A tombstones (earlier)
    b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])  // B refreshes (later, unaware)
    converge(a, b, fabric)

    let x = fabric.server["X"]
    #expect(x != nil)
    #expect(x?.isUserRemoved == false)   // RESURRECTED — the removed item comes back
}

@Test("LWW tombstone outcome is order-dependent (so: nondeterministic, unsafe)")
func tombstoneIsOrderDependentUnderLWW() {
    let (a, b, fabric, clock) = world(.lastWriterWins)
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])  // B refreshes (earlier)
    a.removeItem("X")                                            // A tombstones (later)
    converge(b, a, fabric)

    // Same edits as the previous test, opposite interleaving → opposite result.
    #expect(fabric.server["X"]?.isUserRemoved == true)
}

@Test("Field-merge keeps a tombstone removed regardless of interleaving")
func tombstoneSurvivesUnderFieldMerge() {
    for regenFirst in [true, false] {
        let (a, b, fabric, clock) = world(.fieldMerge(resolver: groceryResolver))
        seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

        if regenFirst {
            b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])
            a.removeItem("X")
            converge(b, a, fabric)
        } else {
            a.removeItem("X")
            b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])
            converge(a, b, fabric)
        }
        #expect(fabric.server["X"]?.isUserRemoved == true)
    }
}

// MARK: - Failure mode 2 — event_quantity loss / double-count

@Test("LWW drops an event contribution when a stale regen writes last")
func eventQuantityLostUnderLWW() {
    let (a, b, fabric, clock) = world(.lastWriterWins)
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    a.setEventQuantity("X", 3)                                   // A merges an event (earlier)
    b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])  // B regen, never saw the merge
    converge(a, b, fabric)

    #expect(fabric.server["X"]?.eventQuantity == nil)   // event portion lost
}

@Test("Field-merge preserves the event contribution across a concurrent regen")
func eventQuantityPreservedUnderFieldMerge() {
    let (a, b, fabric, clock) = world(.fieldMerge(resolver: groceryResolver))
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    a.setEventQuantity("X", 3)
    b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])
    converge(a, b, fabric)

    #expect(fabric.server["X"]?.eventQuantity == 3)
}

// MARK: - Failure mode 3 — user override survival

@Test("LWW clobbers a quantity override with a concurrent regen")
func overrideLostUnderLWW() {
    let (a, b, fabric, clock) = world(.lastWriterWins)
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    a.setQuantityOverride("X", 5)                               // A overrides to 5 (earlier)
    b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)]) // B regen (later, no override)
    converge(a, b, fabric)

    #expect(fabric.server["X"]?.quantityOverride == nil)   // override lost
}

@Test("Field-merge preserves a user override across a concurrent regen")
func overridePreservedUnderFieldMerge() {
    let (a, b, fabric, clock) = world(.fieldMerge(resolver: groceryResolver))
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    a.setQuantityOverride("X", 5)
    b.regenerate(freshRows: [freshRow(name: "tomato", qty: 2)])
    converge(a, b, fabric)

    #expect(fabric.server["X"]?.quantityOverride == 5)
}

// MARK: - Failure mode 4 — check-state convergence (the one LWW handles fine)

@Test("Check state converges under plain LWW — no special handling needed")
func checkStateConvergesUnderLWW() {
    let (a, b, fabric, clock) = world(.lastWriterWins)
    seedSynced([a, b], fabric, items: [autoItem(id: "X", name: "tomato", qty: 2, clock: clock)])

    a.setChecked("X", true)
    b.setChecked("X", false)   // B writes last
    converge(a, b, fabric)

    // Both replicas + server agree on one value (the last write); no divergence.
    #expect(fabric.server["X"]?.isChecked == false)
    #expect(a.snapshot()["X"]?.isChecked == false)
    #expect(b.snapshot()["X"]?.isChecked == false)
}
