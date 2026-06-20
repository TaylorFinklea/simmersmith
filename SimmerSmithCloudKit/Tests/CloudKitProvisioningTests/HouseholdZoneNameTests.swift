import Testing
@testable import CloudKitProvisioning

// SP-C identity slice (spec §5 headless verify): the `household-<id>` zone-name
// convention is the authority for discovery — `zoneName(householdID:)` and its inverse
// `householdID(fromZoneName:)` must round-trip, or discovery would parse the wrong id
// (or none) and the discover-before-create guard (spec §7) would mint an orphaning zone.
// The CloudKit ops (`discoverHouseholdID`) need iCloud auth and are verified on-device;
// only the pure name parse is pinned here.

@Test("household zone name round-trips a UUID id with hyphens")
func zoneNameRoundTripUUID() {
    let id = "9F1C2A3B-4D5E-6F70-8190-A1B2C3D4E5F6"
    let name = HouseholdZoneProvisioner.zoneName(householdID: id)
    #expect(name == "household-9F1C2A3B-4D5E-6F70-8190-A1B2C3D4E5F6")
    // The id (which itself contains hyphens) survives — only the leading prefix is stripped.
    #expect(HouseholdZoneProvisioner.householdID(fromZoneName: name) == id)
}

@Test("household zone name round-trips a plain (Fly) id")
func zoneNameRoundTripPlain() {
    let id = "household123"
    let name = HouseholdZoneProvisioner.zoneName(householdID: id)
    #expect(HouseholdZoneProvisioner.householdID(fromZoneName: name) == id)
}

@Test("non-household zone names parse to nil")
func nonHouseholdZoneIsNil() {
    #expect(HouseholdZoneProvisioner.householdID(fromZoneName: "_defaultZone") == nil)
    #expect(HouseholdZoneProvisioner.householdID(fromZoneName: "catalog-public") == nil)
    // Empty remainder (`household-`) is not a valid id.
    #expect(HouseholdZoneProvisioner.householdID(fromZoneName: "household-") == nil)
}
