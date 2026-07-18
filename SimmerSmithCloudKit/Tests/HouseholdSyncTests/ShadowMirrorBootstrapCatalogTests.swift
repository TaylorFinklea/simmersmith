#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

// e0a P2 spec §3.1–3.2: the read-only bootstrap catalog selects exactly one previously verified
// scope for the CloudKit-proved account identity, treats every on-disk byte as untrusted until
// the full validation ladder holds, and materializes either a cached-resume bootstrap or a
// recovery-only plan — never partial household content.

// A genuine CKSyncEngine.State.Serialization captured by the app-target SDK probe
// (CKSyncEngineStateProbeTests) on Xcode 26.6/iOS 26.5. The package host cannot construct a
// CloudKit container, so the decode proof uses these captured bytes. If an SDK update changes
// the serialization format this constant stops decoding and the probe must be re-run.
private let capturedStateSerializationB64 = """
eyJkYXRhIjoiWW5Cc2FYTjBNRERVQVFJREJBVUdCd3BZSkhabGNuTnBiMjVaSkdGeVkyaHBkbVZ5VkNSMGIzQllKRzlpYW1WamRITVNBQUdHb0Y4UUQwNVRTMlY1WldSQmNtTm9hWFpsY3RFSUNWUnliMjkwZ0FHdkVCMExERFU1UDBGR1NFcFFWbHhkWm1kb2JIQjBlSHg5ZjRHRGg0cVBsRlVrYm5Wc2JOOFFGQTBPRHhBUkVoTVVGUllYR0JrYUd4d2RIaDhnSVNJakpDVWxKeWdwS2lzbEpTVXZNQzh5TXpOZkVCSndaVzVrYVc1bldtOXVaVU5vWVc1blpYTmZFQkZ3Wlc1a2FXNW5RWE56WlhSVGVXNWpjMWw2YjI1bFUzUmhkR1ZmRUJwelpYSjJaWEpEYUdGdVoyVlViMnRsYm5OQ2VWcHZibVZKUkY4UUhHeGhjM1JHWlhSamFFUmhkR0ZpWVhObFEyaGhibWRsYzBSaGRHVmZFQnh6WlhKMlpYSkRhR0Z1WjJWVWIydGxia1p2Y2tSaGRHRmlZWE5sVmlSamJHRnpjMThRRW1sdVJteHBaMmgwUVhOelpYUlRlVzVqYzE4UUhIcHZibVZKUkhOT1pXVmthVzVuVkc5R1pYUmphRU5vWVc1blpYTmZFQnB3Wlc1a2FXNW5VbVZqYjNKa1RXOWthV1pwWTJGMGFXOXVjMXBwWkdWdWRHbG1hV1Z5VzJ4aGMzUkJZMk52ZFc1MFh4QWVaWGhwYzNScGJtZEVZWFJoWW1GelpWTjFZbk5qY21sd2RHbHZia2xFWHhBVmJHRnpkRXR1YjNkdVZYTmxjbEpsWTI5eVpFbEVYeEFiYm1WbFpITlViMFpsZEdOb1JHRjBZV0poYzJWRGFHRnVaMlZ6WHhBVGFXNUdiR2xuYUhSYWIyNWxRMmhoYm1kbGMxOFFIMjVsWldSelZHOVRZWFpsUkdGMFlXSmhjMlZUZFdKelkzSnBjSFJwYjI1ZkVCdHBia1pzYVdkb2RGSmxZMjl5WkUxdlpHbG1hV05oZEdsdmJuTmZFQnRvWVhOSmJrWnNhV2RvZEZWdWRISmhZMnRsWkVOb1lXNW5aWE5mRUJwb1lYTlFaVzVrYVc1blZXNTBjbUZqYTJWa1EyaGhibWRsYzRBR2dCYUFHSUFhZ0FDQUFJQWNnQmVBQklBSWdBS0FBSUFBZ0FBSmdBY0pnQlVJQ05JMkV6YzRYRTVUTG5WMWFXUmllWFJsYzA4UUVMZXZPRlpiczBZM2lWOEJPSXZqSVJTQUE5STZPenc5V2lSamJHRnpjMjVoYldWWUpHTnNZWE56WlhOV1RsTlZWVWxFb2p3K1dFNVRUMkpxWldOMDBSTkFnQVhTT2p0Q1ExOFFFMDVUVFhWMFlXSnNaVTl5WkdWeVpXUlRaWFNqUkVVK1h4QVRUbE5OZFhSaFlteGxUM0prWlhKbFpGTmxkRnhPVTA5eVpHVnlaV1JUWlhUUkUwQ0FCZEVUUUlBRjAwc1RURTFBVDF0T1V5NXZZbXBsWTNRdU1WdE9VeTV2WW1wbFkzUXVNSUFTZ0FXQUNkTlJFMUpUVkZWVWRIbHdaVmh5WldOdmNtUkpSQkFBZ0JHQUN0TVRWMWhaV2x0YVVtVmpiM0prVG1GdFpWWmFiMjVsU1VTQUVJQUxnQXhhY0hKdlltVXRjMkYyWmRWZVgyQmhFMU1sWTJSbFh4QVFaR0YwWVdKaGMyVlRZMjl3WlV0bGVWOFFFV0Z1YjI1NWJXOTFjME5MVlhObGNrbEVXVzkzYm1WeVRtRnRaVmhhYjI1bFRtRnRaWUFBZ0E2QURZQVBXV2h2ZFhObGFHOXNaRjhRRUY5ZlpHVm1ZWFZzZEU5M2JtVnlYMVwvU09qdHBhbDVEUzFKbFkyOXlaRnB2Ym1WSlJLSnJQbDVEUzFKbFkyOXlaRnB2Ym1WSlJOSTZPMjF1V2tOTFVtVmpiM0prU1VTaWJ6NWFRMHRTWldOdmNtUkpSTkk2TzNGeVh4QWpRMHRUZVc1alJXNW5hVzVsVUdWdVpHbHVaMUpsWTI5eVpGcHZibVZEYUdGdVoyV2ljejVmRUNORFMxTjVibU5GYm1kcGJtVlFaVzVrYVc1blVtVmpiM0prV205dVpVTm9ZVzVuWmROUkUxSjFWSGNRQVlBUmdCUFRFMWRZV1hwYmdCQ0FGSUFNWEhCeWIySmxMV1JsYkdWMFpkRVRRSUFGMFJOQWdBWFJFMENBQmRLRUU0V0dXazVUTG05aWFtVmpkSE9nZ0JuU09qdUlpVmRPVTBGeWNtRjVvb2crMDR1RUU0eU5qbGRPVXk1clpYbHpvS0NBRzlJNk81Q1JYeEFUVGxOTmRYUmhZbXhsUkdsamRHbHZibUZ5ZWFPU2t6NWZFQk5PVTAxMWRHRmliR1ZFYVdOMGFXOXVZWEo1WEU1VFJHbGpkR2x2Ym1GeWVkSTZPNVdXWHhBUlEwdFRlVzVqUlc1bmFXNWxVM1JoZEdXaWx6NWZFQkZEUzFONWJtTkZibWRwYm1WVGRHRjBaUUFJQUJFQUdnQWtBQ2tBTWdBM0FFa0FUQUJSQUZNQWN3QjVBS1FBdVFETkFOY0E5QUVUQVRJQk9RRk9BVzBCaWdHVkFhRUJ3Z0hhQWZnQ0RnSXdBazRDYkFLSkFvc0NqUUtQQXBFQ2t3S1ZBcGNDbVFLYkFwMENud0toQXFNQ3BRS21BcWdDcVFLckFxd0NyUUt5QXI4QzBnTFVBdGtDNUFMdEF2UUM5d01BQXdNREJRTUtBeUFESkFNNkEwY0RTZ05NQTA4RFVRTllBMlFEY0FOeUEzUURkZ045QTRJRGl3T05BNDhEa1FPWUE2TURxZ09zQTY0RHNBTzdBOFlEMlFQdEFcL2NFQUFRQ0JBUUVCZ1FJQkJJRUpRUXFCRGtFUEFSTEJGQUVXd1JlQkdrRWJnU1VCSmNFdlFURUJNWUV5QVRLQk5FRTB3VFZCTmNFNUFUbkJPa0U3QVR1QlBFRTh3VDRCUU1GQkFVR0JRc0ZFd1VXQlIwRkpRVW1CU2NGS1FVdUJVUUZTQVZlQldzRmNBV0VCWWNBQUFBQUFBQUNBUUFBQUFBQUFBQ1lBQUFBQUFBQUFBQUFBQUFBQUFBRm13PT0ifQ==
"""

private var capturedStateSerializationData: Data {
    Data(base64Encoded: capturedStateSerializationB64.replacingOccurrences(of: "\n", with: ""))!
}

private let catalogZone = CKRecordZone.ID(zoneName: "household", ownerName: "user-a")

private func catalogScope(
    account: String = "user-a",
    householdID: String = "household-a"
) -> MirrorScope {
    MirrorScope(
        accountRecordName: account, zoneOwnerName: "user-a", zoneName: "household",
        householdID: householdID, role: .owner, databaseScope: .private)
}

private func participantScope(account: String = "user-b") -> MirrorScope {
    MirrorScope(
        accountRecordName: account, zoneOwnerName: "owner-x", zoneName: "household",
        householdID: "household-x", role: .participant, databaseScope: .shared)
}

private func catalogRecord(
    _ name: String,
    value: String = "v1",
    zone: CKRecordZone.ID = catalogZone
) -> CKRecord {
    let record = CKRecord(
        recordType: "Recipe", recordID: CKRecord.ID(recordName: name, zoneID: zone))
    record["name"] = value as CKRecordValue
    return record
}

private func catalogRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shadow-catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func engineState(revision: UInt64 = 1) -> MirrorEngineState {
    MirrorEngineState(
        serialization: capturedStateSerializationData,
        coverageRevision: revision,
        zoneEnsured: true)
}

/// Seeds an anchored scope with a published generation containing recipe-1(v1)/recipe-2, an
/// acknowledged pre-checkpoint edit, and a post-checkpoint sent edit recipe-1(v2).
private func seedCachedScope(root: URL, scope: MirrorScope, zone: CKRecordZone.ID) async throws {
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let first = try await writer.appendSave(
        catalogRecord("recipe-1", zone: zone), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: first, mutationGeneration: 1)
    try await writer.publish(
        records: [catalogRecord("recipe-1", zone: zone), catalogRecord("recipe-2", zone: zone)],
        engineState: engineState())
    _ = try await writer.acknowledge(sequence: first, mutationGeneration: 1)
    let second = try await writer.appendSave(
        catalogRecord("recipe-1", value: "v2", zone: zone), mutationGeneration: 2,
        changedFields: ["name"])
    _ = try await writer.markSent(sequence: second, mutationGeneration: 2)
    await writer.fenceAndPark()
}

@Test("owner cached resume overlays the outbox onto checkpoint records")
func ownerCachedResumeMaterializesOverlaidBootstrap() async throws {
    let root = try catalogRoot()
    try await seedCachedScope(root: root, scope: catalogScope(), zone: catalogZone)

    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)

    guard case .cached(let bootstrap, let writer) = result.outcome else {
        Issue.record("expected cached bootstrap, got \(result.outcome)")
        return
    }
    #expect(result.diagnostics.isEmpty)
    #expect(bootstrap.scope == catalogScope())
    let byName = Dictionary(uniqueKeysWithValues: bootstrap.records.map {
        ($0.recordID.recordName, $0)
    })
    #expect(byName.count == 2)
    #expect(byName["recipe-1"]?["name"] as? String == "v2")
    #expect(byName["recipe-2"]?["name"] as? String == "v1")
    #expect(bootstrap.zoneEnsured)
    #expect(bootstrap.pendingChanges.map(\.operation) == [.save])
    #expect(bootstrap.pendingChanges.first?.identity.recordName == "recipe-1")
    #expect(bootstrap.removalProofs.contains { $0.reason == .acknowledged })
    #expect(bootstrap.maxMutationGenerationByIdentity.values.max() == 2)
    #expect(bootstrap.interventionCount == 0)
    #expect(bootstrap.journalHighWater > 0)
    // The continuing runtime is usable for later transitions.
    _ = try writer.recoveredCheckpointSynchronously()
}

@Test("participant selection requires the marker's exact owner zone")
func participantExactZoneSelection() async throws {
    let root = try catalogRoot()
    let zone = CKRecordZone.ID(zoneName: "household", ownerName: "owner-x")
    try await seedCachedScope(root: root, scope: participantScope(), zone: zone)

    let matched = ShadowMirrorBootstrapCatalog.open(
        request: .participant(
            accountRecordName: "user-b",
            markerZone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household")),
        rootDirectory: root)
    // A legacy participant checkpoint carries only the old Boolean zone proof. It must
    // retain its durable intent as recovery-only and take a safe full fetch; it must never
    // render from the legacy Boolean or be quarantined merely for lacking the typed proof.
    guard case .recoveryOnly(let plan, _) = matched.outcome else {
        Issue.record("expected recovery-only legacy participant bootstrap, got \(matched.outcome)")
        return
    }
    #expect(plan.scope == participantScope())
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))

    let wrongZone = ShadowMirrorBootstrapCatalog.open(
        request: .participant(
            accountRecordName: "user-b",
            markerZone: MirrorZoneReference(ownerName: "owner-y", zoneName: "household")),
        rootDirectory: root)
    guard case .none = wrongZone.outcome else {
        Issue.record("wrong zone must not select a candidate")
        return
    }

    let unavailableMarker = ShadowMirrorBootstrapCatalog.open(
        request: .participant(accountRecordName: "user-b", markerZone: nil),
        rootDirectory: root)
    guard case .none = unavailableMarker.outcome else {
        Issue.record("an unavailable participant marker must yield no cached bootstrap")
        return
    }
}

@Test("zero candidates and unknown accounts yield nothing; multiple owner scopes are anomalous")
func selectionFailsClosed() async throws {
    let empty = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: try catalogRoot())
    guard case .none = empty.outcome else {
        Issue.record("empty root must yield no bootstrap")
        return
    }
    #expect(empty.diagnostics.isEmpty)

    let root = try catalogRoot()
    for household in ["household-a", "household-b"] {
        let writer = try ShadowMirrorCheckpointWriter(
            scope: catalogScope(householdID: household), rootDirectory: root)
        _ = try await writer.appendSave(
            catalogRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
        await writer.fenceAndPark()
    }
    let ambiguous = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)
    guard case .none = ambiguous.outcome else {
        Issue.record("multiple owner candidates must not select")
        return
    }
    #expect(ambiguous.diagnostics == [.multipleOwnerCandidates(count: 2)])

    let unknownAccount = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-z"), rootDirectory: root)
    guard case .none = unknownAccount.outcome else {
        Issue.record("an unknown account identity must yield no bootstrap")
        return
    }
    #expect(unknownAccount.diagnostics.isEmpty)
}

@Test("an anchored WAL without a generation yields a recovery-only plan, never partial content")
func recoveryOnlyPlanFromAnchoredWal() async throws {
    let root = try catalogRoot()
    let writer = try ShadowMirrorCheckpointWriter(scope: catalogScope(), rootDirectory: root)
    let sequence = try await writer.appendSave(
        catalogRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    await writer.fenceAndPark()

    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)

    guard case .recoveryOnly(let plan, _) = result.outcome else {
        Issue.record("expected recovery-only plan, got \(result.outcome)")
        return
    }
    #expect(plan.scope == catalogScope())
    #expect(plan.pendingChanges.map(\.operation) == [.save])
    #expect(plan.outbox.first?.delivery == .pending)
    #expect(plan.journalHighWater == 3)
    #expect(plan.interventionCount == 0)
}

@Test("a pre-P2 anchorless directory with a valid generation backfills its anchor when cataloged")
func preP2AnchorlessCurrentBackfillsAnchor() async throws {
    let root = try catalogRoot()
    let writer = try ShadowMirrorCheckpointWriter(scope: catalogScope(), rootDirectory: root)
    try await writer.publish(
        records: [catalogRecord("recipe-1")], engineState: engineState())
    await writer.fenceAndPark()
    let anchorURL = root.appendingPathComponent(catalogScope().cacheKey)
        .appendingPathComponent("scope.anchor")
    try? FileManager.default.removeItem(at: anchorURL)
    #expect(!FileManager.default.fileExists(atPath: anchorURL.path))

    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)

    guard case .cached(let bootstrap, _) = result.outcome else {
        Issue.record("expected cached bootstrap after backfill, got \(result.outcome)")
        return
    }
    #expect(bootstrap.records.count == 1)
    #expect(FileManager.default.fileExists(atPath: anchorURL.path))
}

@Test("a journal-only anchorless directory is refused cold but recovers after exact discovery")
func journalOnlyAnchorlessDirectoryIsRefusedCold() async throws {
    let root = try catalogRoot()
    let writer = try ShadowMirrorCheckpointWriter(scope: catalogScope(), rootDirectory: root)
    _ = try await writer.appendSave(
        catalogRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    await writer.fenceAndPark()
    let scopeDirectory = root.appendingPathComponent(catalogScope().cacheKey)
    try FileManager.default.removeItem(at: scopeDirectory.appendingPathComponent("scope.anchor"))

    let cold = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)
    guard case .none = cold.outcome else {
        Issue.record("a journal must never invent its scope from the directory name")
        return
    }
    // The journal was left untouched for a later independently discovered open.
    #expect(FileManager.default.fileExists(
        atPath: scopeDirectory.appendingPathComponent("journal.wal").path))

    // Independent CloudKit discovery re-establishes the exact scope; writer recovery replays it.
    let rediscovered = try ShadowMirrorCheckpointWriter(
        scope: catalogScope(), rootDirectory: root)
    let normalized = try rediscovered.normalizeForBootstrapSynchronously()
    #expect(normalized.snapshot.isRecoveryOnly)
    #expect(normalized.snapshot.recoveryState.outbox.count == 1)
}

@Test("a corrupt selected candidate quarantines only its exact scope")
func corruptSelectedCandidateQuarantinesOnlyThatScope() async throws {
    let root = try catalogRoot()
    let ownerWriter = try ShadowMirrorCheckpointWriter(scope: catalogScope(), rootDirectory: root)
    _ = try await ownerWriter.appendSave(
        catalogRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    await ownerWriter.fenceAndPark()
    let participantZone = CKRecordZone.ID(zoneName: "household", ownerName: "owner-x")
    let participantWriter = try ShadowMirrorCheckpointWriter(
        scope: participantScope(account: "user-a"), rootDirectory: root)
    _ = try await participantWriter.appendSave(
        catalogRecord("recipe-9", zone: participantZone),
        mutationGeneration: 1, changedFields: ["name"])
    await participantWriter.fenceAndPark()

    // Corrupt the owner journal after its checksummed frame boundary is unreadable garbage.
    let ownerJournal = root.appendingPathComponent(catalogScope().cacheKey)
        .appendingPathComponent("journal.wal")
    try Data(repeating: 0xFF, count: 64).write(to: ownerJournal)

    let ownerResult = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)
    guard case .none = ownerResult.outcome else {
        Issue.record("a corrupt candidate must not produce a bootstrap")
        return
    }
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent("quarantine").path))

    // The healthy sibling scope is untouched and still selectable.
    let participantResult = ShadowMirrorBootstrapCatalog.open(
        request: .participant(
            accountRecordName: "user-a",
            markerZone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household")),
        rootDirectory: root)
    guard case .recoveryOnly = participantResult.outcome else {
        Issue.record("healthy sibling must remain selectable, got \(participantResult.outcome)")
        return
    }
}

@Test("a generation lease keeps recovered outbox assets readable across a later publish")
func leasePinsJournalAssetsAcrossPublish() async throws {
    let root = try catalogRoot()
    let assetSource = try catalogRoot().appendingPathComponent("asset.bin")
    try Data("asset-bytes".utf8).write(to: assetSource)
    let seedWriter = try ShadowMirrorCheckpointWriter(scope: catalogScope(), rootDirectory: root)
    let record = catalogRecord("recipe-1")
    record["imageAsset"] = CKAsset(fileURL: assetSource)
    let sequence = try await seedWriter.appendSave(
        record, mutationGeneration: 1, changedFields: ["name", "imageAsset"])
    _ = try await seedWriter.markSent(sequence: sequence, mutationGeneration: 1)
    await seedWriter.fenceAndPark()

    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)
    guard case .recoveryOnly(let plan, let writer) = result.outcome else {
        Issue.record("expected recovery-only plan, got \(result.outcome)")
        return
    }
    let envelope = try #require(plan.outbox.first?.record)
    #expect(plan.lease.pinnedJournalAssetSequences.contains(sequence))

    // A later publish compacts the journal, but the leased asset root must stay readable.
    try await writer.publish(
        records: [try envelope.decode()], engineState: engineState())
    #expect(try envelope.decode()["name"] as? String == "v1")

    writer.releaseGenerationLeaseSynchronously(plan.lease.id)
    try await writer.publish(
        records: [catalogRecord("recipe-1", value: "v3")], engineState: engineState(revision: 2))
    let journalAssetDirectory = root.appendingPathComponent(catalogScope().cacheKey)
        .appendingPathComponent("journal-assets").appendingPathComponent("\(sequence)")
    #expect(!FileManager.default.fileExists(atPath: journalAssetDirectory.path))
}

// MARK: - Materializer fail-closed unit coverage

private func emptySnapshot(
    scope: MirrorScope,
    bundle: MirrorCheckpointBundle?,
    outbox: [MirrorOutboxIntent] = [],
    tombstones: [MirrorRecordIdentity] = [],
    highWater: UInt64 = 0
) -> ShadowMirrorNormalizedBootstrapState {
    ShadowMirrorNormalizedBootstrapState(
        snapshot: ShadowMirrorCheckpointRecoveredSnapshot(
            scope: scope,
            current: bundle,
            recoveryState: ShadowMirrorCheckpointRecoveryState(
                outbox: outbox, tombstones: tombstones, lastIntentSequence: highWater),
            hasValidatedAnchor: true),
        removalProofs: [])
}

private func placeholderLease() -> MirrorGenerationLease {
    MirrorGenerationLease(id: UUID(), generationID: nil, pinnedJournalAssetSequences: [])
}

@Test("overlay refuses to resurrect a tombstoned identity")
func overlayAssertsTombstonesAbsent() throws {
    let scope = catalogScope()
    let directory = try catalogRoot()
    let saveEnvelope = try ShadowMirrorRecordEnvelope.archive(
        catalogRecord("recipe-9"), in: directory)
    let tombstone = MirrorRecordIdentity(
        recordType: "Recipe", recordName: "recipe-9",
        zoneOwnerName: "user-a", zoneName: "household")
    let intent = MirrorOutboxIntent(
        sequence: 1, mutationGeneration: 1, operation: .save, record: saveEnvelope,
        changedFields: ["name"])
    let bundle = try MirrorCheckpointBundle(
        scope: scope, generationID: "generation-1", records: [],
        tombstones: [tombstone], outbox: [intent],
        engineState: engineState(), lastIncludedIntentSequence: 1)

    #expect(throws: MirrorCheckpointError.self) {
        _ = try ShadowMirrorBootstrapMaterializer.materializeCached(
            bundle: bundle,
            normalized: emptySnapshot(
                scope: scope, bundle: bundle, outbox: [intent],
                tombstones: [tombstone], highWater: 1),
            scopeDirectory: directory,
            lease: placeholderLease())
    }
}

@Test("every record, tombstone, and outbox identity must belong to the manifest's exact zone")
func foreignZoneIdentitiesAreRejected() throws {
    let scope = catalogScope()
    let directory = try catalogRoot()
    let foreignZone = CKRecordZone.ID(zoneName: "household", ownerName: "someone-else")
    let envelope = try ShadowMirrorRecordEnvelope.archive(
        catalogRecord("recipe-1", zone: foreignZone), in: directory)
    let bundle = try MirrorCheckpointBundle(
        scope: scope, generationID: "generation-1", records: [envelope],
        engineState: engineState(), lastIncludedIntentSequence: 0)

    #expect(throws: MirrorCheckpointError.self) {
        _ = try ShadowMirrorBootstrapMaterializer.materializeCached(
            bundle: bundle,
            normalized: emptySnapshot(scope: scope, bundle: bundle),
            scopeDirectory: directory,
            lease: placeholderLease())
    }
}

@Test("two envelopes may never share a CKRecord.ID even under different record types")
func duplicateRecordIDAcrossTypesIsRejected() throws {
    let scope = catalogScope()
    let directory = try catalogRoot()
    let recipe = try ShadowMirrorRecordEnvelope.archive(catalogRecord("shared-name"), in: directory)
    let impostor = CKRecord(
        recordType: "GroceryList",
        recordID: CKRecord.ID(recordName: "shared-name", zoneID: catalogZone))
    impostor["name"] = "impostor" as CKRecordValue
    let impostorEnvelope = try ShadowMirrorRecordEnvelope.archive(impostor, in: directory)
    let bundle = try MirrorCheckpointBundle(
        scope: scope, generationID: "generation-1", records: [recipe, impostorEnvelope],
        engineState: engineState(), lastIncludedIntentSequence: 0)

    #expect(throws: MirrorCheckpointError.self) {
        _ = try ShadowMirrorBootstrapMaterializer.materializeCached(
            bundle: bundle,
            normalized: emptySnapshot(scope: scope, bundle: bundle),
            scopeDirectory: directory,
            lease: placeholderLease())
    }
}

@Test("an asset root escaping the scope directory fails closed")
func escapedAssetRootIsRejected() throws {
    let scope = catalogScope()
    let scopeDirectory = try catalogRoot()
    let outsideDirectory = try catalogRoot()
    let assetSource = outsideDirectory.appendingPathComponent("asset.bin")
    try Data("escaped".utf8).write(to: assetSource)
    let record = catalogRecord("recipe-1")
    record["imageAsset"] = CKAsset(fileURL: assetSource)
    let envelope = try ShadowMirrorRecordEnvelope.archive(record, in: outsideDirectory)
    let bundle = try MirrorCheckpointBundle(
        scope: scope, generationID: "generation-1", records: [envelope],
        engineState: engineState(), lastIncludedIntentSequence: 0)

    #expect(throws: MirrorCheckpointError.self) {
        _ = try ShadowMirrorBootstrapMaterializer.materializeCached(
            bundle: bundle,
            normalized: emptySnapshot(scope: scope, bundle: bundle),
            scopeDirectory: scopeDirectory,
            lease: placeholderLease())
    }
}

@Test("engine state bytes that do not decode as a CKSyncEngine serialization fail closed")
func undecodableEngineStateFailsClosed() throws {
    let scope = catalogScope()
    let directory = try catalogRoot()
    let bundle = try MirrorCheckpointBundle(
        scope: scope, generationID: "generation-1", records: [],
        engineState: MirrorEngineState(
            serialization: Data("not-a-serialization".utf8),
            coverageRevision: 1,
            zoneEnsured: true),
        lastIncludedIntentSequence: 0)

    #expect(throws: (any Error).self) {
        _ = try ShadowMirrorBootstrapMaterializer.materializeCached(
            bundle: bundle,
            normalized: emptySnapshot(scope: scope, bundle: bundle),
            scopeDirectory: directory,
            lease: placeholderLease())
    }
}

@Test("terminal rows contribute to intervention and never to pending changes")
func terminalRowsBecomeIntervention() async throws {
    let root = try catalogRoot()
    let writer = try ShadowMirrorCheckpointWriter(scope: catalogScope(), rootDirectory: root)
    let blocked = try await writer.appendSave(
        catalogRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: blocked, mutationGeneration: 1)
    _ = try await writer.markBlockedPermanent(sequence: blocked, mutationGeneration: 1)
    let superseded = try await writer.appendSave(
        catalogRecord("recipe-2"), mutationGeneration: 2, changedFields: ["name"])
    _ = try await writer.markSupersededByRemoteDelete(
        sequence: superseded, mutationGeneration: 2)
    _ = try await writer.appendDelete(
        MirrorRecordIdentity(
            recordType: "Recipe", recordName: "recipe-3",
            zoneOwnerName: "user-a", zoneName: "household"),
        mutationGeneration: 3)
    await writer.fenceAndPark()

    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "user-a"), rootDirectory: root)
    guard case .recoveryOnly(let plan, _) = result.outcome else {
        Issue.record("expected recovery-only plan, got \(result.outcome)")
        return
    }
    #expect(plan.interventionCount == 2)
    #expect(plan.pendingChanges.count == 1)
    #expect(plan.pendingChanges.first?.operation == .delete)
    #expect(plan.maxMutationGenerationByIdentity.values.max() == 3)
}
#endif
