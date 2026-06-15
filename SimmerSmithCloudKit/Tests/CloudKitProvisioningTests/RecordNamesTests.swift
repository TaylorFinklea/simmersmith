import Testing
@testable import CloudKitProvisioning

// The recordName policy (Phase 0 §A) is irreversible, so its deterministic builders
// are pinned with tests. The CloudKit provisioner itself needs iCloud auth and is
// verified on-device (Phase 0 Verify), not here.

@Test("deterministic KV keys collapse concurrent creates")
func deterministicKVKeys() {
    #expect(RecordNames.householdSetting(key: "Week Start Day") == "hset:week start day")
    #expect(RecordNames.profileSetting(key: "image_provider") == "pset:image_provider")
    // same logical key from two devices → identical recordName → one record
    #expect(RecordNames.householdSetting(key: "  Timezone ") == RecordNames.householdSetting(key: "timezone"))
}

@Test("alias key normalizes the term")
func aliasKey() {
    #expect(RecordNames.termAlias(term: "  Costco Run ") == "alias:costco run")
}

@Test("junction keys are deterministic and order-fixed")
func junctionKeys() {
    #expect(RecordNames.eventAttendee(eventID: "E1", guestID: "G1") == "E1_G1")
    #expect(RecordNames.eventPantrySupplement(eventID: "E1", stapleID: "S2") == "E1_S2")
}

@Test("1:1 and singleton keys")
func oneToOneAndSingleton() {
    #expect(RecordNames.recipeImage(recipeID: "R7") == "rimg:R7")
    #expect(RecordNames.dietaryGoal == "dietary_goal")
    #expect(RecordNames.migrationReceipt(id: "H9") == "migrated:H9")
}
