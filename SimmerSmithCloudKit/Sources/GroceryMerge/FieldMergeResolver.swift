import Foundation

/// The reusable CKSyncEngine conflict resolver (SP-A §5). When two devices edit the
/// same record concurrently, CKSyncEngine surfaces both versions; these functions
/// produce the merged record. Generalizes Spike 1's `groceryResolver` to the full
/// sticky-field policy across grocery + event records. Pure — no CloudKit types —
/// so it unit-tests headlessly; the CKSyncEngine adapter just calls in here.
public enum FieldMergeResolver {

    // MARK: - GroceryItem (the canonical sticky-merge case)

    /// Per-field merge. Base = the later-modified record (its refreshed auto values
    /// are correct), then the sticky fields are re-asserted so blanket LWW can't
    /// corrupt them — exactly the Spike-1 finding.
    public static func merge(_ a: GroceryItem, _ b: GroceryItem) -> GroceryItem {
        precondition(a.recordName == b.recordName, "merge requires the same record")
        var winner = a.modifiedAt >= b.modifiedAt ? a : b

        // Tombstone: monotonic — once removed by either side, never resurrected.
        winner.isUserRemoved = a.isUserRemoved || b.isUserRemoved

        // User-added flag: sticky (an event/regen writer never clears it).
        winner.isUserAdded = a.isUserAdded || b.isUserAdded

        // Overrides: prefer whichever side set one (sticky over the auto value).
        winner.quantityOverride = a.quantityOverride ?? b.quantityOverride
        winner.unitOverride = a.unitOverride ?? b.unitOverride
        winner.notesOverride = a.notesOverride ?? b.notesOverride

        // Check state: resolve the WHOLE triple by its own clock (never tear).
        winner.check = a.check.at >= b.check.at ? a.check : b.check

        // event_quantity: writer-ownership — a stale regen carries nil/0 and must
        // never drop a real contribution. Keep the non-nil; if both, the larger.
        winner.eventQuantity = Self.mergeEventQuantity(a.eventQuantity, b.eventQuantity)

        return winner
    }

    static func mergeEventQuantity(_ x: Double?, _ y: Double?) -> Double? {
        switch (x, y) {
        case let (a?, nil): return a
        case let (nil, b?): return b
        case let (a?, b?): return Swift.max(a, b)
        case (nil, nil): return nil
        }
    }

    // MARK: - EventGroceryItem (cross-aggregate pointers)

    public static func merge(_ a: EventGroceryItem, _ b: EventGroceryItem) -> EventGroceryItem {
        precondition(a.recordName == b.recordName, "merge requires the same record")
        var winner = a.modifiedAt >= b.modifiedAt ? a : b
        winner.eventQuantity = Self.mergeEventQuantity(a.eventQuantity, b.eventQuantity)
        // Merge-trace pointers travel with the contribution: prefer a live pointer
        // over nil (a concurrent unmerge that nils it loses to an active merge),
        // tie-break to the later writer.
        winner.mergedIntoGroceryItemID = Self.preferLive(
            a.mergedIntoGroceryItemID, a.modifiedAt, b.mergedIntoGroceryItemID, b.modifiedAt)
        winner.mergedIntoWeekID = Self.preferLive(
            a.mergedIntoWeekID, a.modifiedAt, b.mergedIntoWeekID, b.modifiedAt)
        return winner
    }

    private static func preferLive(_ x: String?, _ xt: SyncClock, _ y: String?, _ yt: SyncClock) -> String? {
        switch (x, y) {
        case (nil, nil): return nil
        case let (v?, nil): return v
        case let (nil, v?): return v
        case let (v1?, v2?): return v1 == v2 ? v1 : (xt >= yt ? v1 : v2)
        }
    }

    // MARK: - Event (sticky manual-merge pin)

    public static func merge(_ a: Event, _ b: Event) -> Event {
        precondition(a.recordName == b.recordName, "merge requires the same record")
        var winner = a.modifiedAt >= b.modifiedAt ? a : b
        // The pin is sticky: if one device pins while the other moves event_date or
        // clears auto-merge, the pin must NOT be silently unset.
        winner.manuallyMerged = a.manuallyMerged || b.manuallyMerged
        return winner
    }

    // MARK: - Pass-through (plain CRUD records sharing the household CKSyncEngine)

    /// Records whose intended semantics are last-writer-wins (recipes, guests,
    /// aliases, audit, …). The single household CKSyncEngine handles them by doing
    /// nothing special — pick the later write.
    public static func lww<R: Mergeable>(_ a: R, _ b: R) -> R {
        a.modifiedAt >= b.modifiedAt ? a : b
    }
}
