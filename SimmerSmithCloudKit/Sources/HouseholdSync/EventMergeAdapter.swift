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
    private func saveGrocery(_ item: GroceryItem) {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        if let existing = engine.store.record(for: id) {
            GroceryCodec.encode(item, into: existing); engine.save(existing)
        } else {
            engine.save(GroceryCodec.makeRecord(item, zoneID: zoneID))
        }
    }

    private func saveEventRow(_ item: EventGroceryItem) {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
        if let existing = engine.store.record(for: id) {
            EventGroceryCodec.encode(item, into: existing); engine.save(existing)
        } else {
            engine.save(EventGroceryCodec.makeRecord(item, zoneID: zoneID))
        }
    }

    /// Update the Event record's linkedWeekID (+ bump updatedAt) if it's locally present.
    private func updateEventLink(_ event: Event, linkedWeekID: String?, at now: Date) {
        let id = CKRecord.ID(recordName: event.recordName, zoneID: zoneID)
        guard let record = engine.store.record(for: id) else { return }
        record["linkedWeekID"] = linkedWeekID as CKRecordValue?
        record["updatedAt"] = now as CKRecordValue
        engine.save(record)
    }

    // MARK: merge / unmerge (Layer F)

    @discardableResult
    public func merge(event: Event, eventRows: [EventGroceryItem], intoWeek weekID: String,
                      now: Date = Date()) -> EventMergeEngine.EventMergeOutcome {
        let outcome = EventMergeEngine.mergeEventIntoWeek(
            event: event, eventRows: eventRows, weekRows: weekGroceryRows(weekID),
            weekID: weekID, makeID: { UUID().uuidString })
        for row in outcome.weekRows { saveGrocery(row) }
        for row in outcome.eventRows { saveEventRow(row) }
        updateEventLink(event, linkedWeekID: outcome.linkedWeekID, at: now)
        return outcome
    }

    @discardableResult
    public func unmerge(event: Event, eventRows: [EventGroceryItem], fromWeek weekID: String,
                        keepLink: Bool = false, now: Date = Date()) -> EventMergeEngine.EventUnmergeOutcome {
        let outcome = EventMergeEngine.unmergeEventFromWeek(
            eventRows: eventRows, weekRows: weekGroceryRows(weekID), weekID: weekID,
            eventName: event.name, keepLink: keepLink, currentLinkedWeekID: event.linkedWeekID)
        for row in outcome.weekRows { saveGrocery(row) }
        for name in outcome.hardDeletedRecordNames {
            engine.delete(CKRecord.ID(recordName: name, zoneID: zoneID))   // HARD delete (not tombstone)
        }
        for row in outcome.eventRows { saveEventRow(row) }
        updateEventLink(event, linkedWeekID: outcome.linkedWeekID, at: now)
        return outcome
    }

    // MARK: post-batch grocery dedupe (Layer E)

    /// Collapse duplicate grocery rows on a week — run after a fetched batch lands. Losers are
    /// TOMBSTONED (isUserRemoved=true), never hard-deleted (the corrected dedupe semantics).
    @discardableResult
    public func dedupeWeekGrocery(weekID: String, eventLinks: [EventGroceryItem] = [])
        -> ConflictRepair.GroceryDedupeResult {
        let result = ConflictRepair.dedupeGrocery(items: weekGroceryRows(weekID), eventLinks: eventLinks)
        for keeper in result.keepers { saveGrocery(keeper) }
        for dead in result.tombstoned { saveGrocery(dead) }       // isUserRemoved=true, syncs as a save
        for link in result.repointedLinks { saveEventRow(link) }
        return result
    }
}
#endif
