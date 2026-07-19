#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge

// SP-A Phase 5 Layers E+F — bridges the pure EventMergeEngine / ConflictRepair value-type
// outcomes to the household CKSyncEngine: reads the affected week's rows out of the local store,
// runs the pure logic, then saves/deletes the results back through the engine (which syncs them).
public struct EventMergeAdapter {
    public let engine: HouseholdSyncEngine
    public let zoneID: CKRecordZone.ID

    public init(engine: HouseholdSyncEngine, zoneID: CKRecordZone.ID) {
        self.engine = engine; self.zoneID = zoneID
    }

    // MARK: store read/write helpers

    private func weekGroceryRows(_ weekID: String) -> [GroceryItem] {
        engine.store.records(ofType: GroceryCodec.recordType)
            .filter { ($0["weekID"] as? String) == weekID }
            .map(GroceryCodec.decode)
    }

    /// Upsert a GroceryItem, preserving the server change tag when the record already exists
    /// (so concurrent edits resolve via the grocery merger instead of a blind overwrite).
    @discardableResult
    private func saveGrocery(_ item: GroceryItem) -> Bool {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        if let existing = engine.store.record(for: id) {
            GroceryCodec.encode(item, into: existing); return engine.save(existing)
        } else {
            return engine.save(GroceryCodec.makeRecord(item, zoneID: zoneID))
        }
    }

    @discardableResult
    private func saveEventRow(_ item: EventGroceryItem) -> Bool {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        if let existing = engine.store.record(for: id) {
            EventGroceryCodec.encode(item, into: existing); return engine.save(existing)
        } else {
            return engine.save(EventGroceryCodec.makeRecord(item, zoneID: zoneID))
        }
    }

    /// Update the Event record's linkedWeekID (+ bump updatedAt) if it's locally present.
    @discardableResult
    private func updateEventLink(_ event: Event, linkedWeekID: String?, at now: Date) -> Bool {
        let id = CKRecord.ID(recordName: event.recordName, zoneID: zoneID)
        guard let record = engine.store.record(for: id) else { return true }
        record["linkedWeekID"] = linkedWeekID as CKRecordValue?
        record["updatedAt"] = now as CKRecordValue
        return engine.save(record)
    }

    // MARK: merge / unmerge (Layer F)

    @discardableResult
    public func merge(event: Event, eventRows: [EventGroceryItem], intoWeek weekID: String,
                      now: Date = Date()) throws -> EventMergeEngine.EventMergeOutcome {
        let outcome = EventMergeEngine.mergeEventIntoWeek(
            event: event, eventRows: eventRows, weekRows: weekGroceryRows(weekID),
            weekID: weekID, makeID: { UUID().uuidString })
        for row in outcome.weekRows {
            guard saveGrocery(row) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        for row in outcome.eventRows {
            guard saveEventRow(row) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        guard updateEventLink(event, linkedWeekID: outcome.linkedWeekID, at: now) else {
            throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
        }
        return outcome
    }

    @discardableResult
    public func unmerge(event: Event, eventRows: [EventGroceryItem], fromWeek weekID: String,
                        keepLink: Bool = false, now: Date = Date()) throws -> EventMergeEngine.EventUnmergeOutcome {
        let outcome = EventMergeEngine.unmergeEventFromWeek(
            eventRows: eventRows, weekRows: weekGroceryRows(weekID), weekID: weekID,
            eventName: event.name, keepLink: keepLink, currentLinkedWeekID: event.linkedWeekID)

        // Do not create replacement week rows or repoint links when this session cannot make
        // the hard deletes in the same outcome. A late WAL failure remains non-atomic, but it
        // still stops this loop before later deletes or success-tail writes.
        if !outcome.hardDeletedRecordNames.isEmpty {
            let authorization = engine.dataPlaneResult(for: .delete)
            guard authorization == .allowed else { throw authorization }
        }
        for row in outcome.weekRows {
            guard saveGrocery(row) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        for name in outcome.hardDeletedRecordNames {
            let result = engine.delete(CKRecord.ID(recordName: name, zoneID: zoneID))
            guard result == .allowed else { throw result }   // HARD delete (not tombstone)
        }
        for row in outcome.eventRows {
            guard saveEventRow(row) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        guard updateEventLink(event, linkedWeekID: outcome.linkedWeekID, at: now) else {
            throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
        }
        return outcome
    }

    // MARK: post-batch grocery dedupe (Layer E)

    /// Collapse duplicate grocery rows on a week — run after a fetched batch lands. Losers are
    /// TOMBSTONED (isUserRemoved=true), never hard-deleted (the corrected dedupe semantics).
    @discardableResult
    public func dedupeWeekGrocery(weekID: String, eventLinks: [EventGroceryItem] = [])
        throws -> ConflictRepair.GroceryDedupeResult {
        let result = ConflictRepair.dedupeGrocery(items: weekGroceryRows(weekID), eventLinks: eventLinks)
        try Self.applyDedupeResult(
            result,
            saveGrocery: saveGrocery,
            saveEventRow: saveEventRow
        )
        return result
    }

    /// Apply only the repair write set. `keepers` also contains unchanged survivors for callers
    /// that need the full converged view; re-saving those rows would make every post-send repair
    /// schedule another identical sync pass.
    static func applyDedupeResult(
        _ result: ConflictRepair.GroceryDedupeResult,
        saveGrocery: (GroceryItem) -> Bool,
        saveEventRow: (EventGroceryItem) -> Bool
    ) throws {
        for keeper in result.changedKeepers {
            guard saveGrocery(keeper) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        for dead in result.tombstoned {
            guard saveGrocery(dead) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
        for link in result.repointedLinks {
            guard saveEventRow(link) else {
                throw HouseholdDataPlaneResult.durabilityFailure(MirrorDurabilityFailure())
            }
        }
    }
}
#endif
