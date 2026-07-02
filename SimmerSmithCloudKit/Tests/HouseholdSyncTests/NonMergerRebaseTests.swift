#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync

// simmersmith-6ce: the `.serverRecordChanged` seam for the ~16 non-merger record types used to
// unconditionally copy every local key onto the server record and re-enqueue the save — a
// field-level lost update whenever the local retry was actually the STALE side (e.g. partner A's
// stale favorite flag clobbering partner B's fresher toggle). `rebaseNonMergerRecord` replaces
// that with honest record-level LWW keyed on the manifest's universal `updatedAt` field.

private let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)

private func recipeRecord(name: String, updatedAt: Date?, extra: String? = nil) -> CKRecord {
    let record = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "recipe-1", zoneID: zone))
    record["name"] = name as CKRecordValue
    if let updatedAt {
        record["updatedAt"] = updatedAt as CKRecordValue
    }
    if let extra {
        record["notes"] = extra as CKRecordValue
    }
    return record
}

@Test("server wins when its updatedAt is newer than the local retry's — server fields kept, no re-save")
func serverWinsOnNewerUpdatedAt() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    let local = recipeRecord(name: "Local Stale Name", updatedAt: older)
    let server = recipeRecord(name: "Server Fresh Name", updatedAt: newer)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "Server Fresh Name")   // server's field kept, NOT clobbered
    #expect(decision.reEnqueue == false)                                  // stale local must not be re-saved
}

@Test("server wins on a tie (equal updatedAt) — ties go to the server record of truth")
func serverWinsOnTie() {
    let same = Date(timeIntervalSince1970: 150)
    let local = recipeRecord(name: "Local Name", updatedAt: same)
    let server = recipeRecord(name: "Server Name", updatedAt: same)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "Server Name")
    #expect(decision.reEnqueue == false)
}

@Test("local wins when strictly newer — local's fields are rebased onto the server-tagged record, re-save requested")
func localWinsOnNewerUpdatedAt() {
    let older = Date(timeIntervalSince1970: 100)
    let newer = Date(timeIntervalSince1970: 200)
    let local = recipeRecord(name: "Local Fresh Name", updatedAt: newer)
    let server = recipeRecord(name: "Server Stale Name", updatedAt: older)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "Local Fresh Name")   // local's newer value applied
    #expect(decision.reEnqueue == true)                                  // push the rebased record back
}

@Test("missing local updatedAt falls back to copy-local-over-server, re-save requested")
func fallsBackWhenLocalUpdatedAtMissing() {
    let local = recipeRecord(name: "Local Name", updatedAt: nil)
    let server = recipeRecord(name: "Server Name", updatedAt: Date(timeIntervalSince1970: 200))

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "Local Name")   // legacy blanket-local-wins fallback
    #expect(decision.reEnqueue == true)
}

@Test("missing server updatedAt falls back to copy-local-over-server, re-save requested")
func fallsBackWhenServerUpdatedAtMissing() {
    let local = recipeRecord(name: "Local Name", updatedAt: Date(timeIntervalSince1970: 100))
    let server = recipeRecord(name: "Server Name", updatedAt: nil)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "Local Name")
    #expect(decision.reEnqueue == true)
}

@Test("both updatedAt missing falls back to copy-local-over-server, re-save requested")
func fallsBackWhenBothUpdatedAtMissing() {
    let local = recipeRecord(name: "Local Name", updatedAt: nil)
    let server = recipeRecord(name: "Server Name", updatedAt: nil)

    let decision = HouseholdSyncEngine.rebaseNonMergerRecord(local: local, server: server)

    #expect(decision.record["name"] as? String == "Local Name")
    #expect(decision.reEnqueue == true)
}
#endif
