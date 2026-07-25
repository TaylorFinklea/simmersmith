#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import Testing
@testable import HouseholdSync

private let analyzerSourceZone = CKRecordZone.ID(
    zoneName: HouseholdZoneRecoveryManifest.reservedSourceZoneName,
    ownerName: CKCurrentUserDefaultName)
private let analyzerTargetZone = CKRecordZone.ID(
    zoneName: "household-production",
    ownerName: CKCurrentUserDefaultName)

private func analyzerScope(zoneID: CKRecordZone.ID, householdID: String) -> MirrorScope {
    MirrorScope(
        accountRecordName: "account-a",
        zoneOwnerName: zoneID.ownerName,
        zoneName: zoneID.zoneName,
        householdID: householdID,
        role: .owner,
        databaseScope: .private)
}

private func analyzerRecord(
    _ type: String,
    _ name: String,
    zoneID: CKRecordZone.ID = analyzerSourceZone,
    title: String? = nil
) -> CKRecord {
    let record = CKRecord(
        recordType: type,
        recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    if let title {
        record["title"] = title as CKRecordValue
    }
    return record
}

private func analyzerReference(
    _ name: String,
    zoneID: CKRecordZone.ID,
    action: CKRecord.ReferenceAction = .none
) -> CKRecord.Reference {
    CKRecord.Reference(
        recordID: CKRecord.ID(recordName: name, zoneID: zoneID),
        action: action)
}

private final class RecordingRecoveryTransport: HouseholdZoneRecoveryTransport {
    var pages: [CKRecordZone.ID: [HouseholdZoneRecoveryRecordPage]] = [:]
    var targetRecords: [CKRecord.ID: CKRecord] = [:]
    var fingerprintValues: [CKRecordZone.ID: [String]] = [:]
    var assetResults: [URL: Result<HouseholdZoneRecoveryAssetPayload, Error>] = [:]

    private(set) var pageCalls: [(CKRecordZone.ID, String?, [String]?)] = []
    private(set) var recordCalls: [CKRecord.ID] = []
    private(set) var assetCalls: [URL] = []
    private(set) var fingerprintCalls: [CKRecordZone.ID] = []

    func fetchRecordPage(
        in zoneID: CKRecordZone.ID,
        after cursor: HouseholdZoneRecoveryPageCursor?,
        desiredKeys: [String]?
    ) async throws -> HouseholdZoneRecoveryRecordPage {
        pageCalls.append((zoneID, cursor?.identifier, desiredKeys))
        let index = cursor.flatMap { Int($0.identifier) } ?? 0
        return pages[zoneID]?[index]
            ?? HouseholdZoneRecoveryRecordPage(zoneID: zoneID, records: [], nextCursor: nil)
    }

    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        recordCalls.append(recordID)
        return targetRecords[recordID]
    }

    func assetPayload(for asset: CKAsset) async throws -> HouseholdZoneRecoveryAssetPayload {
        guard let url = asset.fileURL else {
            throw HouseholdZoneRecoveryTransportError.unreadableAsset
        }
        assetCalls.append(url)
        guard let result = assetResults[url] else {
            throw HouseholdZoneRecoveryTransportError.unreadableAsset
        }
        return try result.get()
    }

    func inputFingerprint(for zoneID: CKRecordZone.ID) async throws -> String {
        fingerprintCalls.append(zoneID)
        guard var values = fingerprintValues[zoneID], !values.isEmpty else {
            return "stable-\(zoneID.zoneName)"
        }
        let value = values.removeFirst()
        fingerprintValues[zoneID] = values
        return value
    }
}

private final class MetadataFingerprintProbe: HouseholdZoneRecoveryTransport {
    private(set) var pageCalls: [(CKRecordZone.ID, [String]?)] = []
    private(set) var recordCallCount = 0
    private(set) var assetCallCount = 0

    func fetchRecordPage(
        in zoneID: CKRecordZone.ID,
        after cursor: HouseholdZoneRecoveryPageCursor?,
        desiredKeys: [String]?
    ) async throws -> HouseholdZoneRecoveryRecordPage {
        pageCalls.append((zoneID, desiredKeys))
        return HouseholdZoneRecoveryRecordPage(zoneID: zoneID, records: [], nextCursor: nil)
    }

    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        recordCallCount += 1
        return nil
    }

    func assetPayload(for asset: CKAsset) async throws -> HouseholdZoneRecoveryAssetPayload {
        assetCallCount += 1
        throw HouseholdZoneRecoveryTransportError.unreadableAsset
    }
}

private func configuredTransport(sourceRecords: [CKRecord]) -> RecordingRecoveryTransport {
    let transport = RecordingRecoveryTransport()
    transport.pages[analyzerSourceZone] = [
        HouseholdZoneRecoveryRecordPage(
            zoneID: analyzerSourceZone,
            records: sourceRecords,
            nextCursor: nil),
    ]
    return transport
}

private func analyze(
    transport: RecordingRecoveryTransport,
    provenanceDecisions: [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryProvenanceDecision] = [:],
    conflictDecisions: [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryDecision] = [:]
) async throws -> HouseholdZoneRecoveryAnalysis {
    try await HouseholdZoneRecoveryAnalyzer(transport: transport).analyze(
        accountFingerprint: "account-fingerprint",
        sourceScope: analyzerScope(zoneID: analyzerSourceZone, householdID: "recovery-source"),
        targetScope: analyzerScope(zoneID: analyzerTargetZone, householdID: "production"),
        provenanceDecisions: provenanceDecisions,
        conflictDecisions: conflictDecisions)
}

private func soleCandidateEntry(_ analysis: HouseholdZoneRecoveryAnalysis) throws -> HouseholdZoneRecoveryEntry {
    if let entry = analysis.manifest.entries.first {
        return entry
    }
    return try #require(analysis.manifest.unresolvedEntries.first?.entry)
}

@Test("analyze uses only exact-zone reads and count-only diagnostics")
func analyzerIsExactZoneReadOnlyAndPrivacySafe() async throws {
    let source = analyzerRecord("Recipe", "secret-record", title: "private meal text")
    let transport = configuredTransport(sourceRecords: [source])

    let analysis = try await analyze(transport: transport)

    #expect(transport.pageCalls.map(\.0) == [analyzerSourceZone])
    #expect(transport.recordCalls == [
        CKRecord.ID(recordName: "secret-record", zoneID: analyzerTargetZone),
    ])
    #expect(transport.fingerprintCalls == [
        analyzerSourceZone, analyzerTargetZone, analyzerSourceZone, analyzerTargetZone,
    ])
    #expect(analysis.summary.candidateCount == 1)
    #expect(analysis.summary.excludedCount == 0)
    #expect(!analysis.summary.diagnosticDescription.contains("secret-record"))
    #expect(!analysis.summary.diagnosticDescription.contains("private meal text"))
}

@Test("input fingerprints fetch exact-zone metadata only without assets or record lookups")
func transportFingerprintIsMetadataOnly() async throws {
    let transport = MetadataFingerprintProbe()

    let fingerprint = try await transport.inputFingerprint(for: analyzerSourceZone)

    #expect(!fingerprint.isEmpty)
    #expect(transport.pageCalls.count == 1)
    #expect(transport.pageCalls.first?.0 == analyzerSourceZone)
    #expect(transport.pageCalls.first?.1 == [])
    #expect(transport.recordCallCount == 0)
    #expect(transport.assetCallCount == 0)
}

@Test("wrong-zone records and partial pages fail closed")
func analyzerRejectsWrongZoneAndPartialPages() async {
    let foreign = analyzerRecord(
        "Recipe", "foreign", zoneID: CKRecordZone.ID(zoneName: "other", ownerName: CKCurrentUserDefaultName))
    let wrongZone = configuredTransport(sourceRecords: [foreign])
    await #expect(throws: HouseholdZoneRecoveryAnalyzerError.mismatchedZone) {
        _ = try await analyze(transport: wrongZone)
    }

    let wrongTarget = configuredTransport(sourceRecords: [analyzerRecord("Recipe", "candidate")])
    let requestedID = CKRecord.ID(recordName: "candidate", zoneID: analyzerTargetZone)
    wrongTarget.targetRecords[requestedID] = analyzerRecord(
        "Recipe", "candidate",
        zoneID: CKRecordZone.ID(zoneName: "other", ownerName: CKCurrentUserDefaultName))
    await #expect(throws: HouseholdZoneRecoveryAnalyzerError.mismatchedZone) {
        _ = try await analyze(transport: wrongTarget)
    }

    let partial = configuredTransport(sourceRecords: [analyzerRecord("Recipe", "candidate")])
    partial.pages[analyzerSourceZone] = [
        HouseholdZoneRecoveryRecordPage(
            zoneID: analyzerSourceZone,
            records: [analyzerRecord("Recipe", "candidate")],
            nextCursor: nil,
            partialFailureCount: 1),
    ]
    await #expect(throws: HouseholdZoneRecoveryAnalyzerError.partialPageFailure) {
        _ = try await analyze(transport: partial)
    }
}

@Test("target absence produces copy")
func analyzerCopiesAbsentTarget() async throws {
    let transport = configuredTransport(sourceRecords: [analyzerRecord("Recipe", "recipe", title: "Soup")])

    let analysis = try await analyze(transport: transport)

    #expect(try soleCandidateEntry(analysis).action == .copy)
    #expect(analysis.summary.copyCount == 1)
}

@Test("canonical equality ignores system identity and non-manifest fields")
func analyzerSkipsCanonicalIdenticalTarget() async throws {
    let source = analyzerRecord("Recipe", "recipe", title: "source-only unknown field")
    source["name"] = "Soup" as CKRecordValue
    let target = analyzerRecord(
        "Recipe", "recipe", zoneID: analyzerTargetZone, title: "different unknown field")
    target["name"] = "Soup" as CKRecordValue
    let transport = configuredTransport(sourceRecords: [source])
    transport.targetRecords[target.recordID] = target

    let analysis = try await analyze(transport: transport)

    #expect(try soleCandidateEntry(analysis).action == .skipIdentical)
    #expect(analysis.summary.skipIdenticalCount == 1)
}

@Test("canonical application difference produces an unresolved conflict without implicit LWW")
func analyzerFindsConflict() async throws {
    let source = analyzerRecord("Recipe", "recipe")
    source["name"] = "Source title" as CKRecordValue
    let target = analyzerRecord("Recipe", "recipe", zoneID: analyzerTargetZone)
    target["name"] = "Target title" as CKRecordValue
    let transport = configuredTransport(sourceRecords: [source])
    transport.targetRecords[target.recordID] = target

    let analysis = try await analyze(transport: transport)
    let entry = try soleCandidateEntry(analysis)

    #expect(entry.action == .conflict)
    #expect(entry.decision == nil)
    #expect(analysis.summary.conflictCount == 1)
}

@Test("source or target fingerprint changes invalidate analysis", arguments: [
    analyzerSourceZone,
    analyzerTargetZone,
])
func analyzerRejectsChangedInputs(changedZone: CKRecordZone.ID) async {
    let transport = configuredTransport(sourceRecords: [analyzerRecord("Recipe", "recipe")])
    transport.fingerprintValues[analyzerSourceZone] = ["source-a", "source-a"]
    transport.fingerprintValues[analyzerTargetZone] = ["target-a", "target-a"]
    transport.fingerprintValues[changedZone] = ["before", "after"]

    await #expect(throws: HouseholdZoneRecoveryAnalyzerError.inputChanged) {
        _ = try await analyze(transport: transport)
    }
}

@Test("unreadable required assets fail analysis")
func analyzerRejectsUnreadableAsset() async throws {
    let assetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("image".utf8).write(to: assetURL)
    defer { try? FileManager.default.removeItem(at: assetURL) }

    let recipe = analyzerRecord("Recipe", "recipe")
    let image = analyzerRecord("RecipeImage", "rimg:recipe")
    image["recipe"] = analyzerReference("recipe", zoneID: analyzerSourceZone, action: .deleteSelf)
    image["imageAsset"] = CKAsset(fileURL: assetURL)
    let transport = configuredTransport(sourceRecords: [recipe, image])
    transport.assetResults[assetURL] = .failure(HouseholdZoneRecoveryTransportError.unreadableAsset)

    await #expect(throws: HouseholdZoneRecoveryTransportError.unreadableAsset) {
        _ = try await analyze(transport: transport)
    }
}

@Test("asset payload digest must match its bytes")
func analyzerRejectsInvalidAssetDigest() async throws {
    let assetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bytes = Data("image".utf8)
    try bytes.write(to: assetURL)
    defer { try? FileManager.default.removeItem(at: assetURL) }

    let recipe = analyzerRecord("Recipe", "recipe")
    let image = analyzerRecord("RecipeImage", "rimg:recipe")
    image["recipe"] = analyzerReference("recipe", zoneID: analyzerSourceZone, action: .deleteSelf)
    image["imageAsset"] = CKAsset(fileURL: assetURL)
    let transport = configuredTransport(sourceRecords: [recipe, image])
    transport.assetResults[assetURL] = .success(.init(bytes: bytes, digest: "not-the-byte-digest"))

    await #expect(throws: HouseholdZoneRecoveryAnalyzerError.invalidAssetDigest) {
        _ = try await analyze(transport: transport)
    }
}

@Test("asset digests are byte-stable and projected references compare equal")
func analyzerUsesStableAssetDigests() async throws {
    let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bytes = Data("same-image-payload".utf8)
    try bytes.write(to: sourceURL)
    try bytes.write(to: targetURL)
    defer {
        try? FileManager.default.removeItem(at: sourceURL)
        try? FileManager.default.removeItem(at: targetURL)
    }

    let sourceRecipe = analyzerRecord("Recipe", "recipe")
    let sourceImage = analyzerRecord("RecipeImage", "rimg:recipe")
    sourceImage["recipe"] = analyzerReference("recipe", zoneID: analyzerSourceZone, action: .deleteSelf)
    sourceImage["imageAsset"] = CKAsset(fileURL: sourceURL)

    let targetRecipe = analyzerRecord("Recipe", "recipe", zoneID: analyzerTargetZone)
    let targetImage = analyzerRecord("RecipeImage", "rimg:recipe", zoneID: analyzerTargetZone)
    targetImage["recipe"] = analyzerReference("recipe", zoneID: analyzerTargetZone, action: .deleteSelf)
    targetImage["imageAsset"] = CKAsset(fileURL: targetURL)

    let transport = configuredTransport(sourceRecords: [sourceImage, sourceRecipe])
    transport.targetRecords[targetRecipe.recordID] = targetRecipe
    transport.targetRecords[targetImage.recordID] = targetImage
    let digest = ShadowMirrorDigest.sha256(bytes)
    transport.assetResults[sourceURL] = .success(.init(bytes: bytes, digest: digest))
    transport.assetResults[targetURL] = .success(.init(bytes: bytes, digest: digest))

    let analysis = try await analyze(transport: transport)
    let imageEntry = try #require(
        analysis.manifest.unresolvedEntries.map(\.entry).first {
            $0.identity.source.recordName == "rimg:recipe"
        })

    #expect(imageEntry.action == .skipIdentical)
    #expect(imageEntry.assetDigests == ["imageAsset": digest])
}

@Test("manifest and digest are deterministic across page and record ordering")
func analyzerManifestIsDeterministic() async throws {
    let recipeA = analyzerRecord("Recipe", "a", title: "A")
    let recipeB = analyzerRecord("Recipe", "b", title: "B")
    let unknown = analyzerRecord("UnknownType", "excluded-secret")

    let first = configuredTransport(sourceRecords: [recipeB, unknown, recipeA])
    let second = configuredTransport(sourceRecords: [])
    second.pages[analyzerSourceZone] = [
        HouseholdZoneRecoveryRecordPage(
            zoneID: analyzerSourceZone,
            records: [recipeA],
            nextCursor: HouseholdZoneRecoveryPageCursor(identifier: "1")),
        HouseholdZoneRecoveryRecordPage(
            zoneID: analyzerSourceZone,
            records: [unknown, recipeB],
            nextCursor: nil),
    ]

    let left = try await analyze(transport: first)
    let right = try await analyze(transport: second)

    #expect(left.manifest == right.manifest)
    #expect(try left.manifest.digest() == right.manifest.digest())
    #expect(left.manifest.exclusions == [
        HouseholdZoneRecoveryExclusion(reason: "unknown-type", count: 1),
    ])
    #expect(left.manifest.totals == right.manifest.totals)
}

@Test("validated manifest preserves unresolved blocked exclusion total and digest accounting")
func analyzerPreservesManifestAccounting() async throws {
    let eligible = analyzerRecord("Recipe", "eligible")
    let blocked = analyzerRecord("RecipeStep", "blocked-missing-parent")
    let excluded = analyzerRecord("UnknownType", "excluded")
    let transport = configuredTransport(sourceRecords: [blocked, excluded, eligible])

    let analysis = try await analyze(transport: transport)

    #expect(analysis.manifest.entries.isEmpty)
    #expect(analysis.manifest.unresolvedEntries.count == 1)
    #expect(analysis.manifest.unresolvedEntries.first?.entry.action == .copy)
    #expect(analysis.manifest.blockedEntries.map(\.identity.source.recordName) == [
        "blocked-missing-parent",
    ])
    #expect(analysis.manifest.exclusions == [
        HouseholdZoneRecoveryExclusion(reason: "unknown-type", count: 1),
    ])
    #expect(analysis.manifest.totals.isEmpty)
    let eligibleIdentity = HouseholdZoneRecoveryIdentity(
        source: MirrorRecordIdentity(eligible),
        targetScope: analyzerScope(zoneID: analyzerTargetZone, householdID: "production"))
    let included = try await analyze(
        transport: transport,
        provenanceDecisions: [eligibleIdentity: .include])
    #expect(included.manifest.totals == [
        HouseholdZoneRecoveryTotal(recordType: "Recipe", action: .copy, count: 1),
    ])
    #expect(try included.manifest.digest() != analysis.manifest.digest())
    #expect(!(try analysis.manifest.digest()).isEmpty)
    #expect(analysis.summary.candidateCount == 2)
    #expect(analysis.summary.blockedCount == 1)
}

@Test("manifest preserves optional dependencies and approval does not require excluded optional targets")
func analyzerPreservesOptionalDependencySemantics() async throws {
    let week = analyzerRecord("Week", "week")
    let recipe = analyzerRecord("Recipe", "recipe")
    let meal = analyzerRecord("WeekMeal", "meal")
    meal["week"] = analyzerReference("week", zoneID: analyzerSourceZone, action: .deleteSelf)
    meal["recipe"] = analyzerReference("recipe", zoneID: analyzerSourceZone)
    let targetScope = analyzerScope(zoneID: analyzerTargetZone, householdID: "production")
    let weekIdentity = HouseholdZoneRecoveryIdentity(
        source: MirrorRecordIdentity(week), targetScope: targetScope)
    let recipeIdentity = HouseholdZoneRecoveryIdentity(
        source: MirrorRecordIdentity(recipe), targetScope: targetScope)
    let mealIdentity = HouseholdZoneRecoveryIdentity(
        source: MirrorRecordIdentity(meal), targetScope: targetScope)
    let transport = configuredTransport(sourceRecords: [meal, recipe, week])

    let analysis = try await analyze(
        transport: transport,
        provenanceDecisions: [
            weekIdentity: .include,
            recipeIdentity: .exclude,
            mealIdentity: .include,
        ])
    let mealEntry = try #require(
        analysis.manifest.unresolvedEntries.first { $0.identity == mealIdentity }?.entry)
    let dependencies = Dictionary(uniqueKeysWithValues: mealEntry.dependencies.map {
        ($0.identity.source.recordName, $0.requirement)
    })

    #expect(dependencies == ["recipe": .optional, "week": .required])
    try analysis.manifest.verify(
        HouseholdZoneRecoveryApproval(manifestDigest: analysis.manifest.digest()))
}
#endif
