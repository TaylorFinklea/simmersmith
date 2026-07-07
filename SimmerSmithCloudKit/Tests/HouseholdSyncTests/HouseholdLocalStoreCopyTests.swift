#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync
import GroceryMerge

// simmersmith-pr9: `HouseholdLocalStore` is now the sole owner of its `CKRecord` instances —
// accessors hand back private copies and mutators store a private copy of the caller's
// record, so no instance (and no in-place mutation of one) ever crosses the store boundary.
// This guards against a real data race: `@MainActor` repositories mutate fetched instances
// in place while `CKSyncEngine`'s off-main delegate (`nextRecordZoneChangeBatch`) serializes
// the same instances concurrently — `CKRecord` is not thread-safe.

private let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)

private func recipeRecord(name: String, recordName: String = "recipe-1") -> CKRecord {
    let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
    record["name"] = name as CKRecordValue
    return record
}

// MARK: a. copy-out — mutating a fetched instance never reaches the store

@Test("record(for:) hands back a copy — mutating it does not affect the stored value")
func recordForReturnsIndependentCopy() {
    let store = HouseholdLocalStore()
    let original = recipeRecord(name: "Original")
    store.setRecord(original)

    let fetched = store.record(for: original.recordID)!
    fetched["name"] = "Mutated" as CKRecordValue

    let refetched = store.record(for: original.recordID)!
    #expect(refetched["name"] as? String == "Original")
}

// MARK: b. copy-in — mutating the caller's instance after setRecord/applyRemoteModification
// never reaches the store

@Test("setRecord stores a copy — mutating the caller's instance afterward does not affect the store")
func setRecordStoresIndependentCopy() {
    let store = HouseholdLocalStore()
    let original = recipeRecord(name: "Original")
    store.setRecord(original)

    original["name"] = "MutatedAfterSet" as CKRecordValue

    let fetched = store.record(for: original.recordID)!
    #expect(fetched["name"] as? String == "Original")
}

@Test("applyRemoteModification stores a copy — mutating the caller's instance afterward does not affect the store")
func applyRemoteModificationStoresIndependentCopy() {
    let store = HouseholdLocalStore()
    let original = recipeRecord(name: "Original")
    store.applyRemoteModification(original)

    original["name"] = "MutatedAfterApply" as CKRecordValue

    let fetched = store.record(for: original.recordID)!
    #expect(fetched["name"] as? String == "Original")
}

// MARK: c. changedKeys survive the boundary — guards CKSyncEngine delta-upload semantics
//
// Scope note: only the all-fields-changed state is constructible locally — a record with a
// PARTIAL changed/unchanged split exists only after a real server fetch, and CKRecord exposes
// no API to mint one (encodeSystemFields drops field values; a full NSKeyedArchiver round-trip
// preserves the changed set as-is). `copy()` preserving the exact split was probe-verified
// out-of-band; the partial case is covered end-to-end by the Gate-1 two-device regression
// (bead 6uj: an edit storm with broken delta tracking would drop fields there).

@Test("changedKeys() survive the store boundary unchanged — critical for CKSyncEngine delta uploads")
func changedKeysSurviveStoreBoundary() {
    let store = HouseholdLocalStore()
    let original = recipeRecord(name: "Original")
    original["notes"] = "some notes" as CKRecordValue
    let originalChangedKeys = Set(original.changedKeys())
    #expect(!originalChangedKeys.isEmpty)

    store.setRecord(original)
    let fetched = store.record(for: original.recordID)!

    #expect(Set(fetched.changedKeys()) == originalChangedKeys)
}

// MARK: d. records(ofType:) / allRecords() return independent copies

@Test("records(ofType:) returns instances whose mutation does not affect the store")
func recordsOfTypeReturnsIndependentCopies() {
    let store = HouseholdLocalStore()
    store.setRecord(recipeRecord(name: "Original", recordName: "recipe-1"))

    let fetched = store.records(ofType: "Recipe").first!
    fetched["name"] = "Mutated" as CKRecordValue

    let refetched = store.records(ofType: "Recipe").first!
    #expect(refetched["name"] as? String == "Original")
}

@Test("allRecords() returns instances whose mutation does not affect the store")
func allRecordsReturnsIndependentCopies() {
    let store = HouseholdLocalStore()
    store.setRecord(recipeRecord(name: "Original", recordName: "recipe-1"))

    let fetched = store.allRecords().first!
    fetched["name"] = "Mutated" as CKRecordValue

    let refetched = store.allRecords().first!
    #expect(refetched["name"] as? String == "Original")
}

// MARK: e. merger purity — resolve() must not mutate either argument, and must return a
// fresh instance distinct from both `local` and `remote`.

private func groceryRecord(_ item: GroceryItem) -> CKRecord { GroceryCodec.makeRecord(item, zoneID: zone) }

@Test("GrocerySyncMerger.resolve leaves both arguments unchanged and returns a fresh instance")
func grocerySyncMergerIsPure() {
    let local = GroceryItem(recordName: "G", unit: "cup", normalizedName: "tomato",
                            totalQuantity: 2, quantityOverride: 9,
                            check: CheckState(isChecked: true, at: 5, by: "u"),
                            createdAt: 1, modifiedAt: 5)
    let remote = GroceryItem(recordName: "G", unit: "cup", normalizedName: "tomato",
                             totalQuantity: 3, createdAt: 1, modifiedAt: 6)
    let localRecord = groceryRecord(local)
    let remoteRecord = groceryRecord(remote)
    let localSnapshot = GroceryCodec.decode(localRecord)
    let remoteSnapshot = GroceryCodec.decode(remoteRecord)

    let result = GrocerySyncMerger().resolve(local: localRecord, remote: remoteRecord)

    #expect(GroceryCodec.decode(localRecord) == localSnapshot)
    #expect(GroceryCodec.decode(remoteRecord) == remoteSnapshot)
    #expect(result.record !== localRecord)
    #expect(result.record !== remoteRecord)
}

private func eventGroceryRecord(_ item: EventGroceryItem) -> CKRecord { EventGroceryCodec.makeRecord(item, zoneID: zone) }

@Test("EventGrocerySyncMerger.resolve leaves both arguments unchanged and returns a fresh instance")
func eventGrocerySyncMergerIsPure() {
    let local = EventGroceryItem(recordName: "E", mergedIntoGroceryItemID: "G",
                                 mergedIntoWeekID: "W", eventQuantity: 5, modifiedAt: 5)
    let remote = EventGroceryItem(recordName: "E", mergedIntoGroceryItemID: nil,
                                  mergedIntoWeekID: nil, eventQuantity: 2, modifiedAt: 6)
    let localRecord = eventGroceryRecord(local)
    let remoteRecord = eventGroceryRecord(remote)
    let localSnapshot = EventGroceryCodec.decode(localRecord)
    let remoteSnapshot = EventGroceryCodec.decode(remoteRecord)

    let result = EventGrocerySyncMerger().resolve(local: localRecord, remote: remoteRecord)

    #expect(EventGroceryCodec.decode(localRecord) == localSnapshot)
    #expect(EventGroceryCodec.decode(remoteRecord) == remoteSnapshot)
    #expect(result.record !== localRecord)
    #expect(result.record !== remoteRecord)
}

@Test("EventSyncMerger.resolve leaves both arguments unchanged and returns a fresh instance")
func eventSyncMergerIsPure() {
    func eventRecord(name: String, updatedAt: Double, pin: Bool) -> CKRecord {
        let r = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: "EV", zoneID: zone))
        r["name"] = name
        r["updatedAt"] = Date(timeIntervalSince1970: updatedAt)
        r["manuallyMerged"] = pin ? 1 : 0
        return r
    }
    let localRecord = eventRecord(name: "Party", updatedAt: 5, pin: true)
    let remoteRecord = eventRecord(name: "Big Party", updatedAt: 6, pin: false)
    let localName = localRecord["name"] as? String
    let localPin = localRecord["manuallyMerged"] as? Int
    let remoteName = remoteRecord["name"] as? String
    let remotePin = remoteRecord["manuallyMerged"] as? Int

    let result = EventSyncMerger().resolve(local: localRecord, remote: remoteRecord)

    #expect(localRecord["name"] as? String == localName)
    #expect(localRecord["manuallyMerged"] as? Int == localPin)
    #expect(remoteRecord["name"] as? String == remoteName)
    #expect(remoteRecord["manuallyMerged"] as? Int == remotePin)
    #expect(result.record !== localRecord)
    #expect(result.record !== remoteRecord)
}

@Test("EventSyncMerger.resolve (local-newer branch) copies local keys without mutating either argument")
func eventSyncMergerLocalNewerIsPure() {
    func eventRecord(name: String, updatedAt: Double, pin: Bool) -> CKRecord {
        let r = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: "EV", zoneID: zone))
        r["name"] = name
        r["updatedAt"] = Date(timeIntervalSince1970: updatedAt)
        r["manuallyMerged"] = pin ? 1 : 0
        return r
    }
    // local strictly newer -> exercises the `for key in local.allKeys()` copy loop.
    let localRecord = eventRecord(name: "Renamed Party", updatedAt: 6, pin: true)
    let remoteRecord = eventRecord(name: "Party", updatedAt: 5, pin: false)

    let result = EventSyncMerger().resolve(local: localRecord, remote: remoteRecord)

    #expect(localRecord["name"] as? String == "Renamed Party")
    #expect(localRecord["manuallyMerged"] as? Int == 1)
    #expect(remoteRecord["name"] as? String == "Party")
    #expect(remoteRecord["manuallyMerged"] as? Int == 0)
    #expect(result.record !== localRecord)
    #expect(result.record !== remoteRecord)
    #expect(result.record["name"] as? String == "Renamed Party")   // local's LWW fields won
    #expect(result.record["manuallyMerged"] as? Int == 1)          // sticky pin reasserted
    #expect(result.needsResave == true)
}

// MARK: f. rebaseNonMergerRecord purity — mirrors NonMergerRebaseTests' decision semantics
// while additionally asserting `local`/`server` are untouched and the returned record is a
// fresh instance in the branches that write onto it.

@Test("rebaseNonMergerRecord (local-newer branch): local/server unmutated, returned record is fresh, local wins")
func rebaseLocalNewerIsPureAndFresh() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    let local = recipeRecord(name: "Local Fresh Name")
    local["updatedAt"] = newer
    let server = recipeRecord(name: "Server Stale Name")
    server["updatedAt"] = older
    let localName = local["name"] as? String
    let serverName = server["name"] as? String

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(local["name"] as? String == localName)
    #expect(server["name"] as? String == serverName)
    #expect(decision.record !== server)
    #expect(decision.record !== local)
    #expect(decision.record["name"] as? String == "Local Fresh Name")
    #expect(decision.reEnqueue == true)
}

@Test("rebaseNonMergerRecord (missing-updatedAt fallback branch): local/server unmutated, returned record is fresh, local wins")
func rebaseFallbackIsPureAndFresh() {
    let local = recipeRecord(name: "Local Name")
    let server = recipeRecord(name: "Server Name")
    server["updatedAt"] = Date(timeIntervalSince1970: 200)
    let localName = local["name"] as? String
    let serverName = server["name"] as? String

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(local["name"] as? String == localName)
    #expect(server["name"] as? String == serverName)
    #expect(decision.record !== server)
    #expect(decision.record !== local)
    #expect(decision.record["name"] as? String == "Local Name")
    #expect(decision.reEnqueue == true)
}

// MARK: g. perf cliff-guard — a copy-cost cliff would blow this budget; generous bound, not a benchmark.

@Test("copying 5000 records through the store completes well under a naive cliff bound")
func storeCopyCostDoesNotCliff() {
    let store = HouseholdLocalStore()
    var ids: [CKRecord.ID] = []
    for i in 0..<5000 {
        let id = CKRecord.ID(recordName: "recipe-\(i)", zoneID: zone)
        let record = CKRecord(recordType: "Recipe", recordID: id)
        record["name"] = "Recipe \(i)" as CKRecordValue
        store.setRecord(record)
        ids.append(id)
    }

    let start = Date()
    _ = store.allRecords()
    for id in ids {
        _ = store.record(for: id)
    }
    let elapsed = Date().timeIntervalSince(start)

    #expect(elapsed < 5.0)
}
#endif
