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

// SP-C review finding A: the multi-zone scorer now ranks by a direct profile fetch and,
// when no zone proves a profile, returns an AMBIGUOUS result (id nil) instead of
// alphabetical-guessing. The profile-fetch ranking itself needs an iCloud account (verified
// on-device), but the DiscoveryResult contract — the value the caller branches on — is
// pinned here so the ambiguity signal can't silently regress to a default of `false`.

@Test("DiscoveryResult defaults isAmbiguous to false for the common cases")
func discoveryResultDefaultsUnambiguous() {
    let zero = HouseholdZoneProvisioner.DiscoveryResult(householdID: nil, ignoredHouseholdIDs: [])
    #expect(zero.isAmbiguous == false)
    let one = HouseholdZoneProvisioner.DiscoveryResult(householdID: "abc", ignoredHouseholdIDs: [])
    #expect(one.isAmbiguous == false)
    #expect(one.householdID == "abc")
}

@Test("DiscoveryResult carries the ambiguous signal with no chosen id")
func discoveryResultAmbiguousCarriesNoID() {
    let ambiguous = HouseholdZoneProvisioner.DiscoveryResult(
        householdID: nil,
        ignoredHouseholdIDs: ["a", "b"],
        isAmbiguous: true
    )
    #expect(ambiguous.isAmbiguous == true)
    // Ambiguous must NOT carry a chosen id — the caller must not act on a guess.
    #expect(ambiguous.householdID == nil)
    #expect(ambiguous.ignoredHouseholdIDs == ["a", "b"])
}
