#if canImport(CloudKit)
import CloudKit
import Foundation

/// Local mirror of a household zone's records — the source of truth `CKSyncEngine`
/// uploads from and applies fetched changes into. Phase 2a keeps it in memory + generic
/// over `CKRecord`; Phase 2b/4 layer typed models + the grocery field-merge on top of
/// `applyRemoteModification`.
///
/// Thread-safe (NSLock): `CKSyncEngine` calls the delegate off arbitrary tasks.
///
/// Ownership contract: the store is the sole owner of its `CKRecord` instances — no
/// instance ever crosses the store boundary in either direction. Accessors hand back
/// private copies (mutating a returned record is invisible to the store); mutators store
/// a private copy of the caller's record (mutating the caller's instance afterward is
/// invisible to the store). Changes only become visible to the store via `setRecord`/
/// `applyRemoteModification` (the sync-side analog of `save`).
public final class HouseholdLocalStore {
    private let lock = NSLock()
    private var records: [CKRecord.ID: CKRecord] = [:]

    public init() {}

    public func record(for id: CKRecord.ID) -> CKRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id].map { $0.copy() as! CKRecord }
    }

    public func allRecords() -> [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.map { $0.copy() as! CKRecord }
    }

    /// All locally-mirrored records of a given CloudKit type (e.g. the week's GroceryItems
    /// for the event-merge / post-batch dedupe sibling set).
    public func records(ofType recordType: String) -> [CKRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { $0.recordType == recordType }.map { $0.copy() as! CKRecord }
    }

    public func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    /// Local upsert from app code (a pending save).
    public func setRecord(_ record: CKRecord) {
        lock.lock(); defer { lock.unlock() }
        let copy = record.copy() as! CKRecord
        records[copy.recordID] = copy
    }

    public func removeRecord(_ id: CKRecord.ID) {
        lock.lock(); defer { lock.unlock() }
        records[id] = nil
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }

    /// Record IDs of the local children that CASCADE off `parentName` — i.e. records holding
    /// a `.deleteSelf` CKReference to it. Phase 2b's typed codec encodes CASCADE parents as
    /// `.deleteSelf`, so this scan is the client-side orphan sweep (CloudKit only cascades on
    /// the deleting device). Manifest-independent: the `.deleteSelf` action IS the marker.
    public func recordIDsCascadingFrom(_ parentName: String) -> [CKRecord.ID] {
        lock.lock(); defer { lock.unlock() }
        var result: [CKRecord.ID] = []
        for (id, record) in records {
            for key in record.allKeys() {
                if let reference = record[key] as? CKRecord.Reference,
                   reference.action == .deleteSelf,
                   reference.recordID.recordName == parentName {
                    result.append(id)
                    break
                }
            }
        }
        return result
    }

    /// Apply a record fetched from the server. Plain household records are
    /// last-writer-wins pass-through (the server copy is canonical); the grocery /
    /// event types override this with the field-merge resolver at Phase 4.
    public func applyRemoteModification(_ record: CKRecord) {
        lock.lock(); defer { lock.unlock() }
        let copy = record.copy() as! CKRecord
        records[copy.recordID] = copy
    }
}
#endif
