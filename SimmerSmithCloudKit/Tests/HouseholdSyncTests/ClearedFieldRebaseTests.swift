#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync

// simmersmith-t6t: `rebaseNonMergerRecord`'s (and `EventSyncMerger`'s) local-wins path used to
// copy only `local.allKeys()` onto the server/remote-tagged copy — a deliberately CLEARED field
// (nil'd, e.g. `WeekRepository.updateMealSide`'s `SidePatch.clear` nils `recipeName`/`recipe`) is
// absent from `allKeys()`, so the stale server/remote value silently survived the rebase.
// `manifestKeys` enumerates `HouseholdRecordType.fields` + `.refs` instead, so an absent manifest
// key rebases as an explicit nil.

private let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)

private func sideRecord(
    recordName: String = "side-1", name: String, recipeName: String?, recipeRef: String?, updatedAt: Date?
) -> CKRecord {
    let record = CKRecord(recordType: "WeekMealSide", recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
    record["name"] = name as CKRecordValue
    if let recipeName {
        record["recipeName"] = recipeName as CKRecordValue
    }
    if let recipeRef {
        record["recipe"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: recipeRef, zoneID: zone), action: .none)
    }
    if let updatedAt {
        record["updatedAt"] = updatedAt as CKRecordValue
    }
    return record
}

// MARK: a. rebaseNonMergerRecord's local-newer branch

@Test("local-wins rebase propagates a cleared scalar field (recipeName) instead of resurrecting the server's stale value")
func localWinsPropagatesScalarClear() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    // Server still has the old link; local cleared recipeName/recipe (SidePatch.clear) and is newer.
    let server = sideRecord(name: "Side", recipeName: "Old Recipe", recipeRef: "recipe-old", updatedAt: older)
    let local = sideRecord(name: "Side", recipeName: nil, recipeRef: nil, updatedAt: newer)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["recipeName"] as? String == nil)   // clear propagated, not resurrected
    #expect(decision.reEnqueue == true)
}

@Test("local-wins rebase propagates a cleared reference field (recipe) instead of resurrecting the server's stale link")
func localWinsPropagatesReferenceClear() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    let server = sideRecord(name: "Side", recipeName: "Old Recipe", recipeRef: "recipe-old", updatedAt: older)
    let local = sideRecord(name: "Side", recipeName: nil, recipeRef: nil, updatedAt: newer)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["recipe"] as? CKRecord.Reference == nil)   // reference clear propagated
}

@Test("local-wins rebase still carries forward a field local legitimately kept")
func localWinsKeepsUnclearedField() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    let server = sideRecord(name: "Old Side Name", recipeName: "Old Recipe", recipeRef: "recipe-old", updatedAt: older)
    let local = sideRecord(name: "New Side Name", recipeName: "Old Recipe", recipeRef: "recipe-old", updatedAt: newer)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "New Side Name")
    #expect(decision.record["recipeName"] as? String == "Old Recipe")
}

// MARK: b. rebaseNonMergerRecord's missing-updatedAt fallback branch

@Test("missing-updatedAt fallback branch also propagates a cleared field instead of resurrecting it")
func fallbackBranchPropagatesClear() {
    let server = sideRecord(
        name: "Side", recipeName: "Old Recipe", recipeRef: "recipe-old",
        updatedAt: Date(timeIntervalSince1970: 100))
    let local = sideRecord(name: "Side", recipeName: nil, recipeRef: nil, updatedAt: nil)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["recipeName"] as? String == nil)
    #expect(decision.reEnqueue == true)
}

// MARK: c. fieldKeys — the key set the clear-propagating copy writes

@Test("fieldKeys includes both scalar fields and reference fields for a known manifest type")
func fieldKeysIncludesFieldsAndRefs() {
    let blank = CKRecord(recordType: "WeekMealSide", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
    let keys = HouseholdSyncEngine.fieldKeys(source: blank, destination: blank)

    #expect(keys.contains("recipeName"))   // scalar field
    #expect(keys.contains("recipe"))       // reference field (SET-NULL)
    #expect(keys.contains("weekMeal"))     // reference field (cascade parent)
}

@Test("fieldKeys unions BOTH records' keys for a type outside the manifest, so the destination's extra key is still written (= cleared)")
func fieldKeysUnionsForNonManifestType() {
    // RecipeImage is manifest-external by design. The source has dropped `mimeType`; the
    // destination still carries it. The union must include it so the copy writes nil over it —
    // `source.allKeys()` alone would leave the destination's stale value in place.
    let source = CKRecord(recordType: "RecipeImage", recordID: CKRecord.ID(recordName: "rimg:1", zoneID: zone))
    source["recipeID"] = "recipe-1" as CKRecordValue
    let destination = CKRecord(recordType: "RecipeImage", recordID: CKRecord.ID(recordName: "rimg:1", zoneID: zone))
    destination["recipeID"] = "recipe-1" as CKRecordValue
    destination["mimeType"] = "image/png" as CKRecordValue

    let keys = Set(HouseholdSyncEngine.fieldKeys(source: source, destination: destination))

    #expect(keys.contains("mimeType"))
    #expect(keys.contains("recipeID"))
}

// MARK: d. EventSyncMerger's local-newer branch (same allKeys() pattern, same fix)

private func eventRecord(notes: String?, updatedAt: Double) -> CKRecord {
    let r = CKRecord(recordType: "Event", recordID: CKRecord.ID(recordName: "EV", zoneID: zone))
    if let notes {
        r["notes"] = notes as CKRecordValue
    }
    r["updatedAt"] = Date(timeIntervalSince1970: updatedAt)
    return r
}

@Test("EventSyncMerger local-newer branch propagates a cleared Event field instead of resurrecting the remote's stale value")
func eventMergerPropagatesClear() {
    // remote still carries old notes; local cleared notes and is the later write.
    let remote = eventRecord(notes: "Old notes", updatedAt: 5)
    let local = eventRecord(notes: nil, updatedAt: 6)

    let result = EventSyncMerger().resolve(local: local, remote: remote)

    #expect(result.record["notes"] as? String == nil)   // clear propagated, not resurrected
    #expect(result.needsResave == true)
}
#endif
