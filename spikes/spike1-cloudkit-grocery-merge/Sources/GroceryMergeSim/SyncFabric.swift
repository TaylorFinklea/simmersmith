import Foundation

/// How concurrent edits to the SAME record are resolved when two replicas sync.
/// This is the single property that decides whether the grocery merge is safe.
public enum SyncMode {
    /// `NSPersistentCloudKitContainer` behavior: whole-record last-writer-wins,
    /// ordered by modification clock. No hook to merge individual fields.
    case lastWriterWins
    /// `CKSyncEngine` behavior: on a conflicting concurrent edit the app's custom
    /// resolver merges the two record versions field-by-field.
    case fieldMerge(resolver: (_ mine: GroceryItem, _ theirs: GroceryItem) -> GroceryItem)
}

/// Models CloudKit propagation between replicas through a shared "server" record
/// set. Faithful to the property under test: how same-record conflicts resolve.
/// (Row deletes are out of scope — tombstones here are kept rows via
/// `is_user_removed`, exactly as the production schema models them.)
public final class SyncFabric {
    public private(set) var server: [String: GroceryItem] = [:]
    private let mode: SyncMode

    public init(mode: SyncMode) { self.mode = mode }

    public func seedServer(_ store: [String: GroceryItem]) { server = store }

    /// Push a replica's local store to the server, resolving each record against
    /// what the server already holds.
    public func push(_ replica: Replica) {
        for (id, mine) in replica.snapshot() {
            if let theirs = server[id] {
                server[id] = resolve(mine: mine, theirs: theirs)
            } else {
                server[id] = mine
            }
        }
    }

    /// Pull the converged server state into a replica (CloudKit eventually brings
    /// every peer to the server record set).
    public func pull(_ replica: Replica) {
        replica.load(server)
    }

    private func resolve(mine: GroceryItem, theirs: GroceryItem) -> GroceryItem {
        switch mode {
        case .lastWriterWins:
            return mine.modifiedAt >= theirs.modifiedAt ? mine : theirs
        case .fieldMerge(let resolver):
            return resolver(mine, theirs)
        }
    }
}

/// The proposed `CKSyncEngine` conflict resolver for grocery rows. Take the newer
/// record as the base (most fields are safely last-writer-wins), then re-assert
/// the "sticky" fields whose semantics blanket LWW would corrupt.
public func groceryResolver(mine: GroceryItem, theirs: GroceryItem) -> GroceryItem {
    var winner = mine.modifiedAt >= theirs.modifiedAt ? mine : theirs

    // Tombstone is sticky: once any replica removes it, it stays removed.
    winner.isUserRemoved = mine.isUserRemoved || theirs.isUserRemoved

    // Overrides are sticky: prefer whichever side has one set.
    winner.quantityOverride = mine.quantityOverride ?? theirs.quantityOverride
    winner.unitOverride = mine.unitOverride ?? theirs.unitOverride
    winner.notesOverride = mine.notesOverride ?? theirs.notesOverride

    // event_quantity is owned by the event merge/unmerge pair: never let a stale
    // regen (which carries nil) drop a real contribution.
    winner.eventQuantity = mergeEventQuantity(mine.eventQuantity, theirs.eventQuantity)

    // is_checked: plain last-writer-wins is correct, already inherited from winner.
    return winner
}

private func mergeEventQuantity(_ a: Double?, _ b: Double?) -> Double? {
    switch (a, b) {
    case let (x?, nil): return x
    case let (nil, y?): return y
    case let (x?, y?): return max(x, y)   // both saw a contribution — conservative
    case (nil, nil): return nil
    }
}
