import Foundation
import Testing
import CloudKit
@testable import HouseholdSync
import GroceryMerge

// SP-A Phase 4 — the field-merge seam (GroceryCodec + GrocerySyncMerger). CloudKit is
// headless on macOS, so the codec + merger run in `swift test`; the live two-engine
// convergence is the on-sim DEBUG check.

private let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)

@Test func groceryCodecRoundTrips() {
    let item = GroceryItem(
        recordName: "G1", baseIngredientID: "b1", resolutionStatus: "locked", unit: "cup",
        quantityText: "2", normalizedName: "tomato", totalQuantity: 3, notes: "n",
        sourceMeals: "meal:mon", isUserAdded: true, isUserRemoved: false,
        quantityOverride: 9, unitOverride: "g", notesOverride: "no",
        check: CheckState(isChecked: true, at: 42, by: "savanne"),
        eventQuantity: 1.5, createdAt: 7, modifiedAt: 11)
    let record = GroceryCodec.makeRecord(item, zoneID: zoneID)
    #expect(record.recordType == "GroceryItem")
    #expect(record["isUserAdded"] as? Int == 1)         // Bool → INT64
    #expect(record["checkedAtClock"] as? Int == 42)
    #expect(GroceryCodec.decode(record) == item)
}

private func record(_ item: GroceryItem) -> CKRecord { GroceryCodec.makeRecord(item, zoneID: zoneID) }

@Test func mergerPreservesLocalCheckOverLaterRemoteAuto() {
    // Local user CHECKED + set an override at clock 5; remote is a later regen (clock 6)
    // with a bigger auto quantity and NO check. Blanket LWW would drop the check.
    let local = GroceryItem(recordName: "G", unit: "cup", normalizedName: "tomato",
                            totalQuantity: 2, quantityOverride: 9,
                            check: CheckState(isChecked: true, at: 5, by: "u"),
                            createdAt: 1, modifiedAt: 5)
    let remote = GroceryItem(recordName: "G", unit: "cup", normalizedName: "tomato",
                             totalQuantity: 3, createdAt: 1, modifiedAt: 6)
    let result = GrocerySyncMerger().resolve(local: record(local), remote: record(remote))
    let merged = GroceryCodec.decode(result.record)
    #expect(merged.totalQuantity == 3)          // later auto wins the base
    #expect(merged.check.isChecked == true)     // sticky check preserved
    #expect(merged.quantityOverride == 9)       // sticky override preserved
    #expect(result.needsResave == true)         // we hold state the server lacks → push back
}

@Test func mergerTombstoneIsMonotonic() {
    // Local removed; remote is a later regen that does NOT know about the removal.
    let local = GroceryItem(recordName: "G", normalizedName: "x", isUserRemoved: true, modifiedAt: 5)
    let remote = GroceryItem(recordName: "G", normalizedName: "x", isUserRemoved: false, modifiedAt: 9)
    let merged = GroceryCodec.decode(GrocerySyncMerger().resolve(local: record(local), remote: record(remote)).record)
    #expect(merged.isUserRemoved == true)   // never resurrected
}

@Test func mergerConvergesWithNoResaveWhenServerAlreadyMerged() {
    // Server already carries our sticky state → merge equals remote → no re-save (no ping-pong).
    let value = GroceryItem(recordName: "G", normalizedName: "x", totalQuantity: 3,
                            check: CheckState(isChecked: true, at: 5), createdAt: 1, modifiedAt: 6)
    let result = GrocerySyncMerger().resolve(local: record(value), remote: record(value))
    #expect(result.needsResave == false)
}

@Test func mergerEventQuantityNotDroppedByStaleRegen() {
    let local = GroceryItem(recordName: "G", normalizedName: "x", eventQuantity: 4, modifiedAt: 5)
    let remote = GroceryItem(recordName: "G", normalizedName: "x", eventQuantity: nil, modifiedAt: 9)
    let merged = GroceryCodec.decode(GrocerySyncMerger().resolve(local: record(local), remote: record(remote)).record)
    #expect(merged.eventQuantity == 4)   // writer-ownership: a nil regen never drops a contribution
}
