#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync

// simmersmith-dkj: `sentRecordZoneChanges` used to unconditionally `store.setRecord(saved)` for
// every acked record — a `save(B)` on the SAME record landing while `save(A)`'s send was still
// in flight got silently clobbered by A's ack, and the resave `save(B)` already enqueued then
// just RESENT the now-stale acked payload (the next batch pulls whatever the store currently
// holds).
//
// TWO parts, tested separately because only one of them is a pure function:
//
// 1. THE DECISION — "did the store change between the send and the ack?" — is a per-record
//    MUTATION GENERATION inside the engine (`save()` bumps it, `nextRecordZoneChangeBatch`
//    stamps what went out, the ack compares). It deliberately does NOT read `updatedAt`:
//    GroceryItem/EventGroceryItem have no such field (they carry Int logical clocks), and the
//    grocery check/uncheck double-tap is the app's highest-frequency edit. The generation lives
//    on the engine, and a `CKSyncEngine` cannot be constructed in this package's headless test
//    sandbox (see MergerWiringOrderTests' note), so it is covered by the device gate, not here.
//
// 2. THE REBASE — `rebaseAckedRecord` — IS pure and is what these tests pin: keep the store's
//    newer fields, lift only the ack's system fields/change tag onto them, and — the trap the
//    first implementation fell into — PROPAGATE CLEARS rather than resurrecting the acked value.

private let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)

/// A `.weekMealSide`-shaped record: a MANIFEST type whose `recipeName` scalar and `recipe`
/// reference are BOTH user-clearable (`WeekRepository.updateMealSide`'s `SidePatch.clear`).
private func sideRecord(
    recipeName: String?,
    recipeRef: String?,
    sortOrder: Int = 0,
    recordName: String = "side-1"
) -> CKRecord {
    let record = CKRecord(
        recordType: "WeekMealSide", recordID: CKRecord.ID(recordName: recordName, zoneID: zone))
    record["name"] = "Garlic bread" as CKRecordValue
    record["sortOrder"] = sortOrder as CKRecordValue
    record["updatedAt"] = Date() as CKRecordValue
    if let recipeName { record["recipeName"] = recipeName as CKRecordValue }
    if let recipeRef {
        record["recipe"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: recipeRef, zoneID: zone), action: .none)
    }
    return record
}

/// A GroceryItem-shaped record: MANIFEST-EXTERNAL (its own codec) and carrying NO `updatedAt` —
/// the type the previous `updatedAt`-gated implementation silently did nothing for.
private func groceryRecord(isChecked: Bool, quantityOverride: String?) -> CKRecord {
    let record = CKRecord(
        recordType: "GroceryItem", recordID: CKRecord.ID(recordName: "grocery-1", zoneID: zone))
    record["ingredientName"] = "Milk" as CKRecordValue
    record["isChecked"] = (isChecked ? 1 : 0) as CKRecordValue
    record["modifiedAtClock"] = 7 as CKRecordValue
    if let quantityOverride { record["quantityOverride"] = quantityOverride as CKRecordValue }
    return record
}

// MARK: The rebase keeps the store's newer fields

@Test("stale ack: the store's newer field wins over the acked payload")
func currentFieldsWinOverAck() {
    let acked = sideRecord(recipeName: "Old Recipe", recipeRef: "recipe-old")
    let current = sideRecord(recipeName: "New Recipe", recipeRef: "recipe-new")

    let result = HouseholdSyncEngine.rebaseAckedRecord(acked: acked, current: current)

    #expect(result["recipeName"] as? String == "New Recipe")
    #expect((result["recipe"] as? CKRecord.Reference)?.recordID.recordName == "recipe-new")
    #expect(result.recordID == acked.recordID)
}

// MARK: Clears must PROPAGATE, not resurrect (the regression the first fix introduced)

@Test("stale ack: a field the user CLEARED locally does not resurrect from the acked payload")
func clearedScalarDoesNotResurrectThroughAck() {
    // In flight: the side still linked to a recipe. Meanwhile the user unlinks it.
    let acked = sideRecord(recipeName: "Old Recipe", recipeRef: "recipe-old")
    let current = sideRecord(recipeName: nil, recipeRef: nil)   // SidePatch.clear -> keys ABSENT

    let result = HouseholdSyncEngine.rebaseAckedRecord(acked: acked, current: current)

    // A `for key in current.allKeys()` copy would never visit these keys and would leave the
    // acked values in place — silently undoing the user's unlink.
    #expect(result["recipeName"] == nil)
    #expect(result["recipe"] == nil)
    // Untouched fields still come across.
    #expect(result["name"] as? String == "Garlic bread")
}

@Test("stale ack on a manifest-EXTERNAL type (GroceryItem): the newer value wins and a cleared override clears")
func groceryAckIsRebasedDespiteHavingNoUpdatedAt() {
    // The classic double-tap: check (in flight), then uncheck (local), plus an override removed.
    let acked = groceryRecord(isChecked: true, quantityOverride: "2 gal")
    let current = groceryRecord(isChecked: false, quantityOverride: nil)

    let result = HouseholdSyncEngine.rebaseAckedRecord(acked: acked, current: current)

    #expect(result["isChecked"] as? Int == 0)          // the uncheck survives
    #expect(result["quantityOverride"] == nil)          // the cleared override stays cleared
}

// MARK: The shared copy primitive

@Test("applyFields writes every manifest key from the source, so an absent key clears the destination")
func applyFieldsPropagatesClearsOnManifestTypes() {
    let source = sideRecord(recipeName: nil, recipeRef: nil)
    let destination = sideRecord(recipeName: "Stale", recipeRef: "recipe-stale")

    HouseholdSyncEngine.applyFields(from: source, onto: destination)

    #expect(destination["recipeName"] == nil)
    #expect(destination["recipe"] == nil)
}

@Test("applyFields on a manifest-external type unions both key sets, so a cleared key still clears")
func applyFieldsPropagatesClearsOnExternalTypes() {
    let source = groceryRecord(isChecked: false, quantityOverride: nil)
    let destination = groceryRecord(isChecked: true, quantityOverride: "2 gal")

    HouseholdSyncEngine.applyFields(from: source, onto: destination)

    #expect(destination["quantityOverride"] == nil)
    #expect(destination["isChecked"] as? Int == 0)
}
#endif
