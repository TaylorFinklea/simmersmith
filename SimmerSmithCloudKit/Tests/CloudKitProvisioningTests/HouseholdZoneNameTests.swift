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

// SP-C on-device finding (build 118): repeated early-build minting left 14 `household-*`
// zones, and since EVERY mint writes a `HouseholdProfile`, the old "has a profile" proof
// couldn't tell an empty mint from the zone holding the user's recipes — the lowest-id
// tiebreak orphaned the real data. Discovery now ranks candidates by DATA RICHNESS (record
// count). The CloudKit count fetch needs an iCloud account (verified on-device); the pure
// ranking it feeds — the thing that orphaned the data — is pinned here.

@Test("richest household zone wins over a lower-id empty mint (the orphan-recipes fix)")
func richestHouseholdWins() {
    // The user's recipe zone (many records) has a HIGHER id than two empty profile-only mints.
    let scored = [(id: "zzz-recipes", count: 57), (id: "aaa-empty", count: 1), (id: "bbb-empty", count: 1)]
    let result = HouseholdZoneProvisioner.chooseRichestHousehold(scored)
    #expect(result.householdID == "zzz-recipes")  // data beats alphabet — recipes are not orphaned
    #expect(result.isAmbiguous == false)
    #expect(result.ignoredHouseholdIDs == ["aaa-empty", "bbb-empty"])
}

@Test("every candidate empty/profile-only → ambiguous, never guess into an empty zone")
func allEmptyIsAmbiguous() {
    let scored = [(id: "a", count: 1), (id: "b", count: 1), (id: "c", count: 0)]
    let result = HouseholdZoneProvisioner.chooseRichestHousehold(scored)
    #expect(result.householdID == nil)
    #expect(result.isAmbiguous == true)
    #expect(result.ignoredHouseholdIDs == ["a", "b", "c"])
}

@Test("tie among data-bearing zones → lowest id wins (stable)")
func tieBreaksLowestID() {
    let scored = [(id: "m", count: 40), (id: "d", count: 40), (id: "z", count: 2)]
    let result = HouseholdZoneProvisioner.chooseRichestHousehold(scored)
    #expect(result.householdID == "d")  // lowest id among the richest
    #expect(result.ignoredHouseholdIDs == ["m", "z"])
}

@Test("a single data-bearing candidate is the winner")
func singleRichWins() {
    let result = HouseholdZoneProvisioner.chooseRichestHousehold([(id: "only", count: 12)])
    #expect(result.householdID == "only")
    #expect(result.ignoredHouseholdIDs.isEmpty)
}

// SP-C factory reset (spec §2/§4): `deleteAllHouseholdZones` targets EVERY `household-*`
// zone — no `keeping`, no record-count filter (the difference from
// `deleteEmptyHouseholdZones`). The CloudKit delete needs iCloud auth (verified on-device);
// the pure zone-NAME selection — which zones are targeted, the load-bearing safety contract
// (never touch `_defaultZone` or other non-household zones) — is pinned here.

@Test("delete-all targets only the household zones in a mixed zone list")
func deleteAllTargetsOnlyHouseholdZones() {
    let zoneNames = ["household-a", "household-b", "_defaultZone", "catalog-public"]
    #expect(HouseholdZoneProvisioner.householdZoneIDsToDelete(from: zoneNames) == ["a", "b"])
}

@Test("delete-all account gate accepts only the transaction-bound account")
func deleteAllAccountBindingGate() throws {
    try HouseholdZoneProvisioner.validateDeleteAllAccount(
        expectedAccountRecordName: "bound-account",
        currentAccountRecordName: "bound-account")

    do {
        try HouseholdZoneProvisioner.validateDeleteAllAccount(
            expectedAccountRecordName: "bound-account",
            currentAccountRecordName: "switched-account")
        Issue.record("a switched CloudKit account must fail the delete-all gate")
    } catch let error as HouseholdZoneProvisioner.DeleteAllAccountError {
        #expect(error == .accountMismatch(
            expected: "bound-account",
            current: "switched-account"))
    }
}

// simmersmith-auc — AUTOMATIC leftover cleanup. Discovery picks the richest zone and lists
// the rest in `ignoredHouseholdIDs`; cleanup deletes the ones it can PROVE are empty. The
// census feeding it is `Int?`, and the `nil` (couldn't read the zone) case is the whole
// point: ranking may treat an unreadable zone as 0 (fail-OPEN — it must never outrank a
// readable data zone), but DELETION must not (fail-CLOSED — 0 is indistinguishable from
// "provably empty", so a transient CloudKit failure would delete the user's recipes).
// `classifyLeftovers` is the pure decision; the CloudKit delete itself is verified on-device.

@Test("a leftover zone we could not read is NEVER deleted (fail-closed census)")
func unreadableLeftoverIsNeverDeleted() {
    // `mystery` censused nil — a transient fetch failure, NOT proof of emptiness. Under the
    // old `Int` census it scored 0, satisfied `<= 1`, and would have been deleted.
    let censused: [(id: String, count: Int?)] = [(id: "mystery", count: nil), (id: "empty", count: 1)]
    let outcome = HouseholdZoneProvisioner.classifyLeftovers(censused, keeping: "mine")
    #expect(outcome.deletedHouseholdIDs == ["empty"])       // provably empty → goes
    #expect(outcome.unreadableHouseholdIDs == ["mystery"])  // unproven → stays, retried next launch
    #expect(outcome.dataBearingHouseholdIDs.isEmpty)        // not a fork — don't nag about it
}

@Test("the resolved household is never touched, even when it censuses empty or unreadable")
func keepingIsNeverDeleted() {
    let censused: [(id: String, count: Int?)] = [(id: "mine", count: 0), (id: "stale", count: 1)]
    let outcome = HouseholdZoneProvisioner.classifyLeftovers(censused, keeping: "mine")
    #expect(outcome.deletedHouseholdIDs == ["stale"])
    #expect(!outcome.unreadableHouseholdIDs.contains("mine"))
    #expect(!outcome.dataBearingHouseholdIDs.contains("mine"))
}

@Test("a leftover holding real data is kept and reported as a fork, never deleted")
func dataBearingLeftoverIsKeptAndReported() {
    let censused: [(id: String, count: Int?)] = [(id: "fork", count: 40), (id: "empty", count: 1)]
    let outcome = HouseholdZoneProvisioner.classifyLeftovers(censused, keeping: "mine")
    #expect(outcome.deletedHouseholdIDs == ["empty"])
    #expect(outcome.dataBearingHouseholdIDs == ["fork"])
}

// Regression guard bolted to `tieBreaksLowestID` above: discovery scored `m:40, d:40, z:2`,
// picked `d`, and put BOTH `m` (40 records!) and `z` into `ignoredHouseholdIDs`. "Ignored"
// means "not chosen", NOT "empty" — so cleanup must re-census and spare them, never trust
// that list. Deleting `ignoredHouseholdIDs` wholesale would destroy 42 records here.
@Test("the tie-break loser holding 40 records survives cleanup (ignored != empty)")
func tieBreakLoserSurvivesCleanup() {
    let censused: [(id: String, count: Int?)] = [(id: "m", count: 40), (id: "z", count: 2)]
    let outcome = HouseholdZoneProvisioner.classifyLeftovers(censused, keeping: "d")
    #expect(outcome.deletedHouseholdIDs.isEmpty)
    #expect(outcome.dataBearingHouseholdIDs == ["m", "z"])
}

@Test("an empty leftover set is a clean no-op")
func noLeftoversIsANoOp() {
    let outcome = HouseholdZoneProvisioner.classifyLeftovers([], keeping: "mine")
    #expect(outcome.deletedHouseholdIDs.isEmpty)
    #expect(outcome.dataBearingHouseholdIDs.isEmpty)
    #expect(outcome.unreadableHouseholdIDs.isEmpty)
    #expect(outcome.isEmpty)
}
