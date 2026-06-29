#if canImport(CloudKit)
import CloudKit
import Testing
@testable import HouseholdSync

// Share-T2, unit (c): the zone-wide CKShare record loops back through the owner engine's
// fetched changes — `isShareRecord` must catch it so it's never ingested as household data.
//
// The other T2 behaviours — the `ownsZone` gating of `.saveZone`/zone-recreation (b) and
// the participant zone-revocation purge (g) — require a live CKSyncEngine (CloudKit
// runtime), so they are compile-verified + exercised by the two-real-device human gate,
// not unit-tested here. This pure filter is the headless-testable slice.

@Test("isShareRecord catches the zone-wide CKShare (by type and by reserved record name)")
func shareRecordIsFiltered() {
    let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)

    // A real zone-wide share: recordType == "cloudkit.share" AND recordName == the reserved sentinel.
    let share = CKShare(recordZoneID: zone)
    #expect(HouseholdSyncEngine.isShareRecord(share))
    #expect(share.recordID.recordName == CKRecordNameZoneWideShare)
    #expect(share.recordType == "cloudkit.share")
}

@Test("isShareRecord matches either the share type OR the reserved zone-wide-share name")
func shareRecordEitherClause() {
    let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)

    // Matches by reserved record name even if the type were read differently.
    let byName = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone))
    #expect(HouseholdSyncEngine.isShareRecord(byName))
}

@Test("a normal household record is NOT filtered")
func householdRecordNotFiltered() {
    let zone = CKRecordZone.ID(zoneName: "household-x", ownerName: CKCurrentUserDefaultName)
    let recipe = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "recipe-1", zoneID: zone))
    #expect(!HouseholdSyncEngine.isShareRecord(recipe))

    let week = CKRecord(recordType: "Week", recordID: CKRecord.ID(recordName: "week-1", zoneID: zone))
    #expect(!HouseholdSyncEngine.isShareRecord(week))
}
#endif
