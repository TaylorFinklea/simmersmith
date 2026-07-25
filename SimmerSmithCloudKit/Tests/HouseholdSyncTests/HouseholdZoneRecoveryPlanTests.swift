#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

private let recoverySourceZoneName = "household-spc-recipe-test"
private let recoveryTargetZoneName = "household-production"

private func recoveryScope(
    zoneName: String,
    role: MirrorRole = .owner,
    databaseScope: MirrorDatabaseScope = .private,
    ownerName: String = CKCurrentUserDefaultName
) -> MirrorScope {
    MirrorScope(
        accountRecordName: "account-a",
        zoneOwnerName: ownerName,
        zoneName: zoneName,
        householdID: zoneName == recoveryTargetZoneName ? "household-a" : "recovery-source",
        role: role,
        databaseScope: databaseScope)
}

private func recoveryIdentity(
    _ recordName: String,
    recordType: String = "Recipe",
    sourceZoneName: String = recoverySourceZoneName,
    targetZoneName: String = recoveryTargetZoneName
) -> HouseholdZoneRecoveryIdentity {
    HouseholdZoneRecoveryIdentity(
        source: MirrorRecordIdentity(
            recordType: recordType,
            recordName: recordName,
            zoneOwnerName: CKCurrentUserDefaultName,
            zoneName: sourceZoneName),
        target: MirrorRecordIdentity(
            recordType: recordType,
            recordName: recordName,
            zoneOwnerName: CKCurrentUserDefaultName,
            zoneName: targetZoneName))
}

private func recoveryEntry(
    _ recordName: String,
    recordType: String = "Recipe",
    action: HouseholdZoneRecoveryAction = .copy,
    decision: HouseholdZoneRecoveryDecision? = nil,
    dependencies: [HouseholdZoneRecoveryIdentity] = [],
    assetDigests: [String: String] = [:]
) -> HouseholdZoneRecoveryEntry {
    HouseholdZoneRecoveryEntry(
        identity: recoveryIdentity(recordName, recordType: recordType),
        action: action,
        decision: decision,
        dependencies: dependencies,
        assetDigests: assetDigests)
}

private func recoveryManifest(
    accountFingerprint: String = "account-fingerprint",
    sourceScope: MirrorScope = recoveryScope(zoneName: recoverySourceZoneName),
    targetScope: MirrorScope = recoveryScope(zoneName: recoveryTargetZoneName),
    sourceInputFingerprint: String = "source-fingerprint",
    targetInputFingerprint: String = "target-fingerprint",
    entries: [HouseholdZoneRecoveryEntry] = [recoveryEntry("recipe-a")],
    exclusions: [HouseholdZoneRecoveryExclusion] = [],
    unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry] = [],
    blockedEntries: [HouseholdZoneRecoveryBlockedEntry] = []
) throws -> HouseholdZoneRecoveryManifest {
    try HouseholdZoneRecoveryManifest(
        accountFingerprint: accountFingerprint,
        sourceScope: sourceScope,
        targetScope: targetScope,
        sourceInputFingerprint: sourceInputFingerprint,
        targetInputFingerprint: targetInputFingerprint,
        entries: entries,
        exclusions: exclusions,
        unresolvedEntries: unresolvedEntries,
        blockedEntries: blockedEntries)
}

@Test("recovery identity preserves exact source owner and zone and projects the target")
func recoveryIdentityProjectsSourceToTarget() {
    let source = MirrorRecordIdentity(
        recordType: "Week",
        recordName: "week-a",
        zoneOwnerName: CKCurrentUserDefaultName,
        zoneName: recoverySourceZoneName)
    let targetScope = recoveryScope(zoneName: recoveryTargetZoneName, ownerName: "target-owner")

    let identity = HouseholdZoneRecoveryIdentity(source: source, targetScope: targetScope)

    #expect(identity.source == source)
    #expect(identity.target == MirrorRecordIdentity(
        recordType: "Week",
        recordName: "week-a",
        zoneOwnerName: "target-owner",
        zoneName: recoveryTargetZoneName))
}

@Test("manifest canonicalizes entries dependencies and exclusions independent of input order")
func manifestCanonicalOrderingIsStable() throws {
    let recipe = recoveryIdentity("recipe-a")
    let ingredient = recoveryIdentity("ingredient-z", recordType: "RecipeIngredient")
    let firstEntries = [
        recoveryEntry("recipe-b", dependencies: [recipe, ingredient], assetDigests: ["thumbnail": "bb", "image": "aa"]),
        recoveryEntry("ingredient-z", recordType: "RecipeIngredient"),
        recoveryEntry("recipe-a"),
    ]
    let secondEntries = [
        recoveryEntry("recipe-a"),
        recoveryEntry("recipe-b", dependencies: [ingredient, recipe], assetDigests: ["image": "aa", "thumbnail": "bb"]),
        recoveryEntry("ingredient-z", recordType: "RecipeIngredient"),
    ]
    let first = try recoveryManifest(
        entries: firstEntries,
        exclusions: [.init(reason: "unknown-type", count: 2), .init(reason: "fixture", count: 1)])
    let second = try recoveryManifest(
        entries: secondEntries,
        exclusions: [.init(reason: "fixture", count: 1), .init(reason: "unknown-type", count: 2)])

    #expect(first.entries.map(\.identity.source.recordName) == ["recipe-a", "recipe-b", "ingredient-z"])
    #expect(first.entries[1].dependencies == [recipe, ingredient])
    #expect(first.exclusions.map(\.reason) == ["fixture", "unknown-type"])
    #expect(try first.canonicalJSONBytes() == second.canonicalJSONBytes())
    #expect(try first.digest() == second.digest())
}

@Test("manifest JSON is canonical for storage while digest uses the canonical writer")
func manifestCanonicalBytesAndDigestUseSeparateConventions() throws {
    let baseline = try recoveryManifest()
    let canonicalString = try #require(String(data: baseline.canonicalJSONBytes(), encoding: .utf8))

    #expect(canonicalString.hasPrefix("{\"accountFingerprint\":"))
    #expect(!canonicalString.contains("\n"))
    #expect(try baseline.digest() == ShadowMirrorCanonicalDigest.recoveryManifest(baseline))
    #expect(try baseline.digest() != ShadowMirrorDigest.sha256(baseline.canonicalJSONBytes()))
}

@Test("manifest digest covers scopes inputs entries actions decisions dependencies assets exclusions unresolved blocked and totals")
func manifestDigestCoversEveryRecoveryInput() throws {
    let dependency = recoveryIdentity("recipe-a")
    let missing = recoveryIdentity("missing")
    let unresolvedIdentity = recoveryIdentity("recipe-unresolved")
    let blockedIdentity = recoveryIdentity("recipe-blocked")
    let baseline = try recoveryManifest(
        entries: [
            recoveryEntry("recipe-a"),
            recoveryEntry(
                "recipe-b",
                action: .conflict,
                decision: .source,
                dependencies: [dependency],
                assetDigests: ["image": "asset-sha"]),
        ],
        exclusions: [.init(reason: "fixture", count: 3)],
        unresolvedEntries: [.init(identity: unresolvedIdentity, decision: .include)],
        blockedEntries: [.init(
            identity: blockedIdentity,
            reason: "schema-block",
            missingDependencies: [missing])])
    let baselineDigest = try baseline.digest()
    let emptyBaseline = try recoveryManifest(entries: [])
    let alternateSourceScope = MirrorScope(
        accountRecordName: "account-a",
        zoneOwnerName: CKCurrentUserDefaultName,
        zoneName: recoverySourceZoneName,
        householdID: "different-source-scope",
        role: .owner,
        databaseScope: .private)
    #expect(try emptyBaseline.digest() != recoveryManifest(
        sourceScope: alternateSourceScope,
        entries: []).digest())
    #expect(try emptyBaseline.digest() != recoveryManifest(
        targetScope: recoveryScope(zoneName: "household-production-b"),
        entries: []).digest())

    #expect(baselineDigest != (try recoveryManifest(
        accountFingerprint: "other-account",
        entries: baseline.entries,
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        sourceInputFingerprint: "changed-source",
        entries: baseline.entries,
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        targetInputFingerprint: "changed-target",
        entries: baseline.entries,
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: [recoveryEntry("recipe-a"), recoveryEntry("recipe-b", action: .skipIdentical)],
        exclusions: baseline.exclusions).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: [
            recoveryEntry("recipe-a"),
            recoveryEntry("recipe-b", action: .conflict, decision: .target, dependencies: [dependency], assetDigests: ["image": "asset-sha"]),
        ],
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: [
            recoveryEntry("recipe-a"),
            recoveryEntry("recipe-b", action: .conflict, decision: .source, assetDigests: ["image": "asset-sha"]),
        ],
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: [
            recoveryEntry("recipe-a"),
            recoveryEntry("recipe-b", action: .conflict, decision: .source, dependencies: [dependency], assetDigests: ["image": "changed-asset"]),
        ],
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: baseline.entries,
        exclusions: [.init(reason: "fixture", count: 4)],
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: baseline.entries,
        exclusions: baseline.exclusions,
        unresolvedEntries: [.init(identity: unresolvedIdentity, decision: .exclude)],
        blockedEntries: baseline.blockedEntries).digest()))
    #expect(baselineDigest != (try recoveryManifest(
        entries: baseline.entries,
        exclusions: baseline.exclusions,
        unresolvedEntries: baseline.unresolvedEntries,
        blockedEntries: [.init(
            identity: blockedIdentity,
            reason: "different-block",
            missingDependencies: [missing])]).digest()))
}

@Test("manifest rejects duplicate CloudKit record identities")
func manifestRejectsDuplicateIdentity() {
    #expect(throws: HouseholdZoneRecoveryPlanError.duplicateIdentity) {
        try recoveryManifest(entries: [recoveryEntry("recipe-a"), recoveryEntry("recipe-a", recordType: "Week")])
    }
}

@Test("manifest rejects equal source and target zones")
func manifestRejectsEqualSourceAndTarget() {
    let source = recoveryScope(zoneName: recoverySourceZoneName)
    #expect(throws: HouseholdZoneRecoveryPlanError.sourceEqualsTarget) {
        try recoveryManifest(sourceScope: source, targetScope: source, entries: [])
    }
}

@Test("manifest rejects source or target scopes without owner private authority", arguments: [
    (MirrorRole.participant, MirrorDatabaseScope.shared),
    (MirrorRole.owner, MirrorDatabaseScope.shared),
])
func manifestRejectsInvalidAuthority(role: MirrorRole, databaseScope: MirrorDatabaseScope) {
    #expect(throws: HouseholdZoneRecoveryPlanError.invalidScope) {
        try recoveryManifest(
            sourceScope: recoveryScope(
                zoneName: recoverySourceZoneName,
                role: role,
                databaseScope: databaseScope),
            entries: [])
    }
    #expect(throws: HouseholdZoneRecoveryPlanError.invalidScope) {
        try recoveryManifest(
            targetScope: recoveryScope(
                zoneName: recoveryTargetZoneName,
                role: role,
                databaseScope: databaseScope),
            entries: [])
    }
}

@Test("manifest rejects a candidate outside the exact source zone")
func manifestRejectsCrossZoneCandidate() {
    let entry = HouseholdZoneRecoveryEntry(
        identity: recoveryIdentity("recipe-a", sourceZoneName: "some-other-zone"),
        action: .copy)

    #expect(throws: HouseholdZoneRecoveryPlanError.crossZoneIdentity) {
        try recoveryManifest(entries: [entry])
    }
}

@Test("manifest rejects a projected identity outside the exact target zone")
func manifestRejectsCrossZoneTarget() {
    let entry = HouseholdZoneRecoveryEntry(
        identity: recoveryIdentity("recipe-a", targetZoneName: "wrong-target-zone"),
        action: .copy)

    #expect(throws: HouseholdZoneRecoveryPlanError.crossZoneIdentity) {
        try recoveryManifest(entries: [entry])
    }
}

@Test("manifest rejects unresolved conflicts")
func manifestRejectsUnresolvedConflict() {
    #expect(throws: HouseholdZoneRecoveryPlanError.unresolvedConflict) {
        try recoveryManifest(entries: [recoveryEntry("recipe-a", action: .conflict)])
    }
}

@Test("manifest surfaces missing dependencies as deterministic blocked entries")
func manifestSurfacesMissingDependency() throws {
    let missing = recoveryIdentity("missing")
    let manifest = try recoveryManifest(entries: [
        recoveryEntry("recipe-a", dependencies: [missing]),
    ])
    #expect(manifest.entries.isEmpty)

    #expect(manifest.blockedEntries == [
        .init(
            identity: recoveryIdentity("recipe-a"),
            reason: HouseholdZoneRecoveryBlockedEntry.missingDependencyReason,
            missingDependencies: [missing]),
    ])
}

@Test("manifest retains unresolved provenance decisions blocked reasons and deterministic totals")
func manifestCanonicalizesReviewStateAndTotals() throws {
    let unresolvedA = recoveryIdentity("unresolved-a")
    let unresolvedB = recoveryIdentity("unresolved-b")
    let blockedA = recoveryIdentity("blocked-a")
    let blockedB = recoveryIdentity("blocked-b")
    let manifest = try recoveryManifest(
        entries: [
            recoveryEntry("week-a", recordType: "Week"),
            recoveryEntry("recipe-b", action: .skipIdentical),
            recoveryEntry("recipe-a"),
        ],
        unresolvedEntries: [
            .init(identity: unresolvedB, decision: .exclude),
            .init(identity: unresolvedA, decision: .include),
        ],
        blockedEntries: [
            .init(identity: blockedB, reason: "z-reason"),
            .init(identity: blockedA, reason: "a-reason"),
        ])

    #expect(manifest.unresolvedEntries.map(\.identity) == [unresolvedA, unresolvedB])
    #expect(manifest.blockedEntries.map(\.identity) == [blockedA, blockedB])
    #expect(manifest.totals == [
        .init(recordType: "Recipe", action: .copy, count: 1),
        .init(recordType: "Recipe", action: .skipIdentical, count: 1),
        .init(recordType: "Week", action: .copy, count: 1),
    ])
}

@Test("manifest Codable round-trip preserves canonical bytes and tampering fails closed")
func manifestCodableRoundTripAndTamperValidation() throws {
    let manifest = try recoveryManifest(
        entries: [recoveryEntry("recipe-a", assetDigests: ["image": "sha"])],
        unresolvedEntries: [.init(identity: recoveryIdentity("unresolved-a"), decision: .include)])
    let bytes = try manifest.canonicalJSONBytes()
    let decoded = try JSONDecoder().decode(HouseholdZoneRecoveryManifest.self, from: bytes)

    #expect(decoded == manifest)
    #expect(try decoded.canonicalJSONBytes() == bytes)

    var crossZoneObject = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var entries = try #require(crossZoneObject["entries"] as? [[String: Any]])
    var identity = try #require(entries[0]["identity"] as? [String: Any])
    var target = try #require(identity["target"] as? [String: Any])
    target["zoneName"] = "tampered-zone"
    identity["target"] = target
    entries[0]["identity"] = identity
    crossZoneObject["entries"] = entries
    let crossZoneBytes = try JSONSerialization.data(withJSONObject: crossZoneObject)
    #expect(throws: HouseholdZoneRecoveryPlanError.crossZoneIdentity) {
        try JSONDecoder().decode(HouseholdZoneRecoveryManifest.self, from: crossZoneBytes)
    }

    var overlapObject = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let overlapEntries = try #require(overlapObject["entries"] as? [[String: Any]])
    var unresolved = try #require(overlapObject["unresolvedEntries"] as? [[String: Any]])
    unresolved[0]["identity"] = overlapEntries[0]["identity"]
    overlapObject["unresolvedEntries"] = unresolved
    let overlapBytes = try JSONSerialization.data(withJSONObject: overlapObject)
    #expect(throws: HouseholdZoneRecoveryPlanError.duplicateIdentity) {
        try JSONDecoder().decode(HouseholdZoneRecoveryManifest.self, from: overlapBytes)
    }

    var totalObject = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var totals = try #require(totalObject["totals"] as? [[String: Any]])
    totals[0]["count"] = 99
    totalObject["totals"] = totals
    let totalBytes = try JSONSerialization.data(withJSONObject: totalObject)
    #expect(throws: HouseholdZoneRecoveryPlanError.invalidTotals) {
        try JSONDecoder().decode(HouseholdZoneRecoveryManifest.self, from: totalBytes)
    }
}

@Test("manifest rejects malformed identities decisions and asset digests")
func manifestRejectsMalformedEntryInputs() {
    let mismatchedIdentity = HouseholdZoneRecoveryIdentity(
        source: recoveryIdentity("recipe-a").source,
        target: recoveryIdentity("recipe-b").target)
    #expect(throws: HouseholdZoneRecoveryPlanError.invalidIdentity) {
        try recoveryManifest(entries: [.init(identity: mismatchedIdentity, action: .copy)])
    }
    #expect(throws: HouseholdZoneRecoveryPlanError.invalidDecision) {
        try recoveryManifest(entries: [recoveryEntry("recipe-a", decision: .source)])
    }
    #expect(throws: HouseholdZoneRecoveryPlanError.invalidInput) {
        try recoveryManifest(entries: [recoveryEntry("recipe-a", assetDigests: ["image": ""])])
    }
}

@Test("manifest rejects inputs with duplicate ordering keys")
func manifestRejectsUnstableOrderingInputs() {
    let dependency = recoveryIdentity("recipe-a")
    #expect(throws: HouseholdZoneRecoveryPlanError.unstableOrdering) {
        try recoveryManifest(entries: [
            recoveryEntry("recipe-a"),
            recoveryEntry("recipe-b", dependencies: [dependency, dependency]),
        ])
    }
    #expect(throws: HouseholdZoneRecoveryPlanError.unstableOrdering) {
        try recoveryManifest(
            entries: [],
            exclusions: [.init(reason: "fixture", count: 1), .init(reason: "fixture", count: 2)])
    }
}

@Test("manifest rejects identities repeated across entries unresolved and blocked buckets")
func manifestRejectsCrossBucketIdentityOverlap() {
    let identity = recoveryIdentity("recipe-a")
    #expect(throws: HouseholdZoneRecoveryPlanError.duplicateIdentity) {
        try recoveryManifest(
            entries: [recoveryEntry("recipe-a")],
            unresolvedEntries: [.init(identity: identity)])
    }
    #expect(throws: HouseholdZoneRecoveryPlanError.duplicateIdentity) {
        try recoveryManifest(
            entries: [recoveryEntry("recipe-a")],
            blockedEntries: [.init(identity: identity, reason: "schema-block")])
    }
    #expect(throws: HouseholdZoneRecoveryPlanError.duplicateIdentity) {
        try recoveryManifest(
            entries: [],
            unresolvedEntries: [.init(identity: identity)],
            blockedEntries: [.init(identity: identity, reason: "schema-block")])
    }
}

@Test("approval verifies the exact manifest digest")
func approvalRequiresExactManifestDigest() throws {
    let manifest = try recoveryManifest()
    let approval = HouseholdZoneRecoveryApproval(manifestDigest: try manifest.digest())

    try manifest.verify(approval)
    #expect(throws: HouseholdZoneRecoveryPlanError.approvalMismatch) {
        try manifest.verify(.init(manifestDigest: (try manifest.digest()).uppercased()))
    }
}

@Test("approval rejects undecided provenance and blocked entries after digest verification")
func approvalRequiresResolvedAndUnblockedManifest() throws {
    let unresolved = try recoveryManifest(
        entries: [],
        unresolvedEntries: [.init(identity: recoveryIdentity("recipe-a"))])
    #expect(throws: HouseholdZoneRecoveryPlanError.unresolvedProvenance) {
        try unresolved.verify(.init(manifestDigest: try unresolved.digest()))
    }

    let included = try recoveryManifest(
        entries: [],
        unresolvedEntries: [.init(identity: recoveryIdentity("recipe-a"), decision: .include)])
    try included.verify(.init(manifestDigest: try included.digest()))

    let blocked = try recoveryManifest(
        entries: [],
        blockedEntries: [.init(identity: recoveryIdentity("recipe-a"), reason: "schema-block")])
    #expect(throws: HouseholdZoneRecoveryPlanError.blockedEntriesPresent) {
        try blocked.verify(.init(manifestDigest: try blocked.digest()))
    }
}
#endif
