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
#endif
