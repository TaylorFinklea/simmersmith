#if canImport(CloudKit)
import CloudKit
import GroceryMerge

// SP-A Phase 4 — the field-merge seam. The household CKSyncEngine consults a RecordMerger
// wherever two versions of a record meet: the fetch handler (a peer's change arrives) AND
// serverRecordChanged (our save lost a race). For sticky types this runs FieldMergeResolver
// so blanket LWW can't corrupt the tombstone / overrides / check-state triple / event_quantity
// (the Spike-1 finding). Plain records have no merger → the engine keeps its LWW behavior.

public struct MergeResult {
    /// The merged record to store/enqueue. Carries `remote`'s system fields (change tag), so a
    /// re-save matches the server version it merged against.
    public let record: CKRecord
    /// True when the merged value differs from `remote` — i.e. we hold sticky state the server
    /// lacks and must push it back. False → convergence reached, no re-save (no ping-pong).
    public let needsResave: Bool
    public init(record: CKRecord, needsResave: Bool) {
        self.record = record; self.needsResave = needsResave
    }
}

public protocol RecordMerger {
    func handles(_ recordType: String) -> Bool
    /// Merge the local edit with the server/remote version. `remote` carries the authoritative
    /// change tag; the result writes the merged fields onto a copy of it.
    func resolve(local: CKRecord, remote: CKRecord) -> MergeResult
}

/// The grocery (and event) sticky merger — wraps the pure GroceryMerge resolver.
public struct GrocerySyncMerger: RecordMerger {
    public init() {}

    public func handles(_ recordType: String) -> Bool {
        recordType == GroceryCodec.recordType
    }

    public func resolve(local: CKRecord, remote: CKRecord) -> MergeResult {
        let localValue = GroceryCodec.decode(local)
        let remoteValue = GroceryCodec.decode(remote)
        let merged = FieldMergeResolver.merge(localValue, remoteValue)
        // Apply merged fields onto a copy of `remote` so the server change tag is preserved.
        let mergedRecord = remote
        GroceryCodec.encode(merged, into: mergedRecord)
        return MergeResult(record: mergedRecord, needsResave: merged != remoteValue)
    }
}

/// The event-side contribution merger. A concurrent unmerge that nils a `mergedInto` pointer
/// loses to an active merge (preferLive); `eventQuantity` is writer-owned (a stale nil regen
/// never drops a contribution). Wraps the pure `FieldMergeResolver.merge(EventGroceryItem)`.
public struct EventGrocerySyncMerger: RecordMerger {
    public init() {}
    public func handles(_ recordType: String) -> Bool { recordType == EventGroceryCodec.recordType }
    public func resolve(local: CKRecord, remote: CKRecord) -> MergeResult {
        let localValue = EventGroceryCodec.decode(local)
        let remoteValue = EventGroceryCodec.decode(remote)
        let merged = FieldMergeResolver.merge(localValue, remoteValue)
        let mergedRecord = remote
        EventGroceryCodec.encode(merged, into: mergedRecord)
        return MergeResult(record: mergedRecord, needsResave: merged != remoteValue)
    }
}

/// Composes multiple type-specific mergers (grocery + event-grocery + …) behind the engine's
/// single `merger` seam: the first registered merger that `handles` the record type resolves it.
public struct DispatchingMerger: RecordMerger {
    public let mergers: [RecordMerger]
    public init(_ mergers: [RecordMerger]) { self.mergers = mergers }
    public func handles(_ recordType: String) -> Bool { mergers.contains { $0.handles(recordType) } }
    public func resolve(local: CKRecord, remote: CKRecord) -> MergeResult {
        for merger in mergers where merger.handles(remote.recordType) {
            return merger.resolve(local: local, remote: remote)
        }
        return MergeResult(record: remote, needsResave: false)   // unreachable: gated by handles()
    }
}
#endif
