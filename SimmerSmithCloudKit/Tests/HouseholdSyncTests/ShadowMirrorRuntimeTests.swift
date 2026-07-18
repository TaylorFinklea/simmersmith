#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

@Test("shadow scope stays disabled without an account identity")
func shadowScopeRequiresAccountIdentity() {
    let zoneID = CKRecordZone.ID(zoneName: "household-test", ownerName: "owner")

    #expect(ShadowMirrorScopeFactory.make(
        accountRecordName: nil,
        zoneID: zoneID,
        householdID: "household-test",
        role: .owner) == nil)
    #expect(ShadowMirrorScopeFactory.make(
        accountRecordName: "",
        zoneID: zoneID,
        householdID: "household-test",
        role: .owner) == nil)
}

@Test("owner and participant identity resolve to distinct shadow scopes")
func shadowScopeSeparatesRolesAndDatabases() throws {
    let zoneID = CKRecordZone.ID(zoneName: "household-test", ownerName: "owner")
    let owner = try #require(ShadowMirrorScopeFactory.make(
        accountRecordName: "account-test",
        zoneID: zoneID,
        householdID: "household-test",
        role: .owner))
    let participant = try #require(ShadowMirrorScopeFactory.make(
        accountRecordName: "account-test",
        zoneID: zoneID,
        householdID: "household-test",
        role: .participant))

    #expect(owner.databaseScope == .private)
    #expect(participant.databaseScope == .shared)
    #expect(owner.cacheKey != participant.cacheKey)
}

@Test("P1 active engine never selects a persisted shadow or legacy state token")
func p1ColdStartStateIsAlwaysNil() {
    #expect(HouseholdSyncEngine.coldStartStateSerialization() == nil)
}

@Test("shadow runtime never publishes state newer than its completed fetch snapshot")
func shadowRuntimeRejectsStateNewerThanSnapshot() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord()

    runtime.beginFetchEpoch()
    let fetchPublication = try runtime.completeFetchEpoch(
        records: [record], coverageRevision: 1, zoneEnsured: true)
    #expect(fetchPublication == nil)
    let leadingState = try runtime.observeStateUpdate(
        Data([2]), coverageRevision: 2, zoneEnsured: true)
    #expect(leadingState == nil)
    #expect(try await writer.loadCurrent() == nil)

    let candidate = try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: true)
    let publication = try #require(candidate)
    try await runtime.publish(publication)
    let checkpoint = try #require(await writer.loadCurrent())
    #expect(checkpoint.manifest.mirrorCoverageRevision == 1)
    #expect(checkpoint.records.count == 1)
}

@Test("a leading state update cannot hide the newest safe state behind it")
func leadingStateRetainsLatestEligibleBoundary() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)

    runtime.beginFetchEpoch()
    #expect(try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: true) == nil)
    #expect(try runtime.observeStateUpdate(
        Data([3]), coverageRevision: 3, zoneEnsured: true) == nil)
    let publication = try #require(try runtime.completeFetchEpoch(
        records: [runtimeRecord()], coverageRevision: 2, zoneEnsured: true))

    #expect(publication.engineState.serialization == Data([1]))
    #expect(publication.engineState.coverageRevision == 1)
}

@Test("typed participant fetch proof is bound into a pre-zone-event runtime state before publication")
func participantProofPersistsWhenStatePrecedesZoneEvent() async throws {
    let root = try runtimeDirectory()
    let scope = MirrorScope(
        accountRecordName: "participant-account",
        zoneOwnerName: "owner-test",
        zoneName: "household-test",
        householdID: "household-test",
        role: .participant,
        databaseScope: .shared)
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)

    runtime.beginFetchEpoch()
    #expect(try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: false) == nil)
    try runtime.bindParticipantFetchProof(
        MirrorParticipantFetchCheckpointProof(fetch: .verified),
        coverageRevision: 1)
    let publication = try #require(try runtime.completeFetchEpoch(
        records: [runtimeRecord()], coverageRevision: 1, zoneEnsured: true))
    try await runtime.publish(publication)

    let checkpoint = try #require(await writer.loadCurrent())
    #expect(checkpoint.engineState.participantFetchProof?.isVerified == true)
}

@Test("a valid P1 shadow checkpoint never hydrates the active store")
func validShadowDoesNotHydrateLiveStore() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let activeStore = HouseholdLocalStore()

    try await publishBoundary(runtime: runtime, records: [runtimeRecord()])

    #expect(try await writer.loadCurrent() != nil)
    #expect(activeStore.count() == 0)
}

@Test("a bad checkpoint quarantines for full-fetch fallback without hydrating the active store")
func badCheckpointFallsBackWithoutHydration() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    try await writer.publish(
        records: [runtimeRecord(recordName: "stale")],
        engineState: MirrorEngineState(
            serialization: Data([1]), coverageRevision: 1, zoneEnsured: true))

    let scopeDirectory = root.appendingPathComponent(runtimeScope().cacheKey)
    let generationID = try String(
        contentsOf: scopeDirectory.appendingPathComponent("current"), encoding: .utf8)
    try FileManager.default.removeItem(
        at: scopeDirectory.appendingPathComponent("generations")
            .appendingPathComponent(generationID)
            .appendingPathComponent("records.json"))

    let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    #expect(try await recoveredWriter.loadCurrent() == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
    #expect(HouseholdSyncEngine.coldStartStateSerialization() == nil)

    let runtime = ShadowMirrorRuntime(writer: recoveredWriter)
    let activeStore = HouseholdLocalStore()
    let freshRecord = runtimeRecord(recordName: "fresh")
    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(
        records: [freshRecord], coverageRevision: 2, zoneEnsured: true)
    let publication = try #require(try runtime.observeStateUpdate(
        Data([2]), coverageRevision: 2, zoneEnsured: true))
    try await runtime.publish(publication)

    #expect(runtime.isCacheReady)
    #expect(activeStore.count() == 0)
    let checkpoint = try #require(await recoveredWriter.loadCurrent())
    #expect(try checkpoint.records.first?.decode().recordID.recordName == "fresh")
}

@Test("shadow WAL derives changed and explicitly cleared fields from the CKRecord")
func shadowRuntimeCapturesClearedFields() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord()
    record["notes"] = "remove me" as CKRecordValue
    record["notes"] = nil

    #expect(runtime.appendSaveBeforeMutation(record, mutationGeneration: 1))
    let intent = try #require(await writer.recoveryState().outbox.first)

    #expect(intent.changedFields.contains("name"))
    #expect(intent.clearedFields.contains("notes"))
    #expect(!intent.changedFields.contains("notes"))
}

@Test("delete delivery is stamped and acknowledged by its exact generation")
func shadowRuntimeTracksDeleteDelivery() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord()

    #expect(runtime.appendDeleteBeforeMutation(
        MirrorRecordIdentity(record), mutationGeneration: 1))
    #expect(runtime.markSent(recordID: record.recordID, mutationGeneration: 1))
    #expect(await writer.recoveryState().outbox.first?.delivery.state == .sent)
    #expect(runtime.acknowledge(recordID: record.recordID, mutationGeneration: 1))
    #expect(await writer.recoveryState().outbox.isEmpty)
    #expect(await writer.recoveryState().tombstones.isEmpty)
}

@Test("normal acknowledgement removes its sent intent without requiring a rebase")
func shadowRuntimeAcknowledgesUnchangedSave() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord()

    #expect(runtime.appendSaveBeforeMutation(record, mutationGeneration: 1))
    #expect(runtime.markSent(recordID: record.recordID, mutationGeneration: 1))
    #expect(runtime.acknowledge(recordID: record.recordID, mutationGeneration: 1))

    #expect(runtime.isCacheReady)
    #expect(await writer.recoveryState().outbox.isEmpty)
}

@Test("checkpoint publication retains WAL transitions newer than its captured high-water")
func publicationDoesNotCompactLaterMutation() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)

    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(
        records: [runtimeRecord()], coverageRevision: 1, zoneEnsured: true)
    let candidate = try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: true)
    let publication = try #require(candidate)
    let later = runtimeRecord(recordName: "recipe-later")
    #expect(runtime.appendSaveBeforeMutation(later, mutationGeneration: 1))

    try await runtime.publish(publication)

    let installed = try #require(await writer.loadCurrent())
    #expect(installed.outbox.isEmpty)
    #expect(installed.manifest.lastIntentSequence == 0)
    let recovered = await writer.recoveryState()
    #expect(recovered.outbox.map(\.record?.identity.recordName) == ["recipe-later"])
    #expect(recovered.lastIntentSequence == 1)
}

@Test("a newer fetch boundary coalesces behind publication and cannot regress current")
func coalescedPublicationsCannotRegressCurrent() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)

    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(
        records: [runtimeRecord(recordName: "first")], coverageRevision: 1, zoneEnsured: true)
    let firstCandidate = try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: true)
    let first = try #require(firstCandidate)

    runtime.beginFetchEpoch()
    let secondCandidate = try runtime.completeFetchEpoch(
        records: [runtimeRecord(recordName: "second")], coverageRevision: 2, zoneEnsured: true)
    #expect(secondCandidate == nil)

    try await runtime.publish(first)

    let installed = try #require(await writer.loadCurrent())
    #expect(try installed.records.first?.decode().recordID.recordName == "second")
}

@Test("a sent transition WAL failure fences but preserves durable intents for restart retry")
func sentTransitionFailureIsObservable() throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let firstRecord = runtimeRecord(recordName: "sent-before-failure")
    let failedRecord = runtimeRecord(recordName: "sent-failure")

    #expect(runtime.appendSaveBeforeMutation(firstRecord, mutationGeneration: 1))
    #expect(runtime.appendSaveBeforeMutation(failedRecord, mutationGeneration: 1))
    #expect(runtime.markSent(recordID: firstRecord.recordID, mutationGeneration: 1))
    let lease = writer.acquireGenerationLeaseSynchronously(
        generationID: nil,
        pinnedJournalAssetSequences: [])
    defer { writer.releaseGenerationLeaseSynchronously(lease.id) }
    let sentinel = root
        .appendingPathComponent(runtimeScope().cacheKey, isDirectory: true)
        .appendingPathComponent("leased-asset")
    try Data("asset".utf8).write(to: sentinel)
    writer.fenceSynchronously()

    #expect(!runtime.markSent(recordID: failedRecord.recordID, mutationGeneration: 1))
    #expect(FileManager.default.fileExists(atPath: sentinel.path))

    writer.releaseGenerationLeaseSynchronously(lease.id)
    #expect(FileManager.default.fileExists(atPath: sentinel.path))
    let states = try writer.recoveryStateSynchronously().outbox.map(\.delivery.state)
    #expect(states == [.sent, .pending])
}

@Test("quarantine defers moving an asset root until its active generation lease releases")
func quarantineDefersForGenerationLease() throws {
    let root = try runtimeDirectory()
    let scope = runtimeScope()
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let lease = writer.acquireGenerationLeaseSynchronously(
        generationID: nil,
        pinnedJournalAssetSequences: [])
    defer { writer.releaseGenerationLeaseSynchronously(lease.id) }
    let sentinel = root
        .appendingPathComponent(scope.cacheKey, isDirectory: true)
        .appendingPathComponent("leased-asset")
    try Data("asset".utf8).write(to: sentinel)

    #expect(!runtime.markSent(
        recordID: runtimeRecord(recordName: "missing-intent").recordID,
        mutationGeneration: 1))
    #expect(FileManager.default.fileExists(atPath: sentinel.path))

    writer.releaseGenerationLeaseSynchronously(lease.id)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test("same-process rebootstrap rejects a durably deferred quarantine without moving leased assets")
func deferredQuarantineRejectsConcurrentWriter() throws {
    let root = try runtimeDirectory()
    let scope = runtimeScope()
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let lease = writer.acquireGenerationLeaseSynchronously(
        generationID: nil,
        pinnedJournalAssetSequences: [])
    defer { writer.releaseGenerationLeaseSynchronously(lease.id) }
    let scopeDirectory = root.appendingPathComponent(scope.cacheKey, isDirectory: true)
    let sentinel = scopeDirectory.appendingPathComponent("leased-asset")
    try Data("asset".utf8).write(to: sentinel)

    #expect(!runtime.markSent(
        recordID: runtimeRecord(recordName: "missing-intent-restart").recordID,
        mutationGeneration: 1))
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".\(scope.cacheKey).deferred-quarantine").path))
    do {
        _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        Issue.record("a concurrent writer opened a scope awaiting leased quarantine")
    } catch {}
    #expect(FileManager.default.fileExists(atPath: sentinel.path))

    writer.releaseGenerationLeaseSynchronously(lease.id)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test("clear requests persist a marker and reject rebootstrap until the asset lease releases")
func deferredClearRejectsConcurrentWriter() throws {
    let root = try runtimeDirectory()
    let scope = runtimeScope()
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let lease = writer.acquireGenerationLeaseSynchronously(
        generationID: nil,
        pinnedJournalAssetSequences: [])
    defer { writer.releaseGenerationLeaseSynchronously(lease.id) }
    let scopeDirectory = root.appendingPathComponent(scope.cacheKey, isDirectory: true)
    let sentinel = scopeDirectory.appendingPathComponent("leased-asset")
    try Data("asset".utf8).write(to: sentinel)

    try runtime.requestClear()
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".\(scope.cacheKey).deferred-clear").path))
    do {
        _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        Issue.record("a concurrent writer opened a scope awaiting leased clear")
    } catch {}
    #expect(FileManager.default.fileExists(atPath: sentinel.path))

    writer.releaseGenerationLeaseSynchronously(lease.id)
    #expect(!FileManager.default.fileExists(atPath: sentinel.path))
}

@Test("account root retirement blocks sibling writers until all cached assets are released")
func accountRootRetirementIsRaceFree() throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let lease = writer.acquireGenerationLeaseSynchronously(
        generationID: nil,
        pinnedJournalAssetSequences: [])
    defer { writer.releaseGenerationLeaseSynchronously(lease.id) }
    let siblingScope = MirrorScope(
        accountRecordName: "account-test",
        zoneOwnerName: "owner-test",
        zoneName: "household-sibling",
        householdID: "household-sibling",
        role: .owner,
        databaseScope: .private)
    let siblingWriter = try ShadowMirrorCheckpointWriter(
        scope: siblingScope,
        rootDirectory: root)
    let siblingLease = siblingWriter.acquireGenerationLeaseSynchronously(
        generationID: nil,
        pinnedJournalAssetSequences: [])
    defer { siblingWriter.releaseGenerationLeaseSynchronously(siblingLease.id) }
    let siblingSentinel = root
        .appendingPathComponent(siblingScope.cacheKey, isDirectory: true)
        .appendingPathComponent("sibling-data")
    try Data("sibling".utf8).write(to: siblingSentinel)

    try ShadowMirrorCheckpointWriter.requestRootClearSynchronously(root)
    do {
        _ = try ShadowMirrorCheckpointWriter(scope: siblingScope, rootDirectory: root)
        Issue.record("a sibling writer opened while account root retirement was blocked")
    } catch {}
    #expect(FileManager.default.fileExists(atPath: siblingSentinel.path))

    writer.releaseGenerationLeaseSynchronously(lease.id)
    #expect(FileManager.default.fileExists(atPath: siblingSentinel.path))
    siblingWriter.releaseGenerationLeaseSynchronously(siblingLease.id)
    try ShadowMirrorCheckpointWriter.completeRootClearSynchronously(root)
    #expect(!FileManager.default.fileExists(atPath: siblingSentinel.path))
    _ = try ShadowMirrorCheckpointWriter(scope: siblingScope, rootDirectory: root)
}

@Test("a fetched remote delete durably supersedes a pending cached save")
func remoteDeleteSupersedesPendingSave() throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord(recordName: "remote-delete")

    #expect(runtime.appendSaveBeforeMutation(record, mutationGeneration: 1))
    #expect(runtime.markSent(recordID: record.recordID, mutationGeneration: 1))
    record["name"] = "Newer local edit" as CKRecordValue
    #expect(runtime.appendSaveBeforeMutation(record, mutationGeneration: 2))

    #expect(runtime.resolveRemoteDelete(recordID: record.recordID))
    let states = try writer.recoveryStateSynchronously().outbox.map(\.delivery.state)
    #expect(states == [.supersededByRemoteDelete, .supersededByRemoteDelete])
}

@Test("a fetched remote delete acknowledges a pending cached delete")
func remoteDeleteAcknowledgesPendingDelete() throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord(recordName: "remote-delete-pending-delete")

    #expect(runtime.appendDeleteBeforeMutation(
        MirrorRecordIdentity(record), mutationGeneration: 1))
    #expect(runtime.resolveRemoteDelete(recordID: record.recordID))
    #expect(try writer.recoveryStateSynchronously().outbox.isEmpty)
}

@Test("a delivery transition reports WAL failure so cache-first callers can stop before rebasing")
func deliveryTransitionFailureIsObservable() throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    let record = runtimeRecord(recordName: "delivery-failure")

    #expect(runtime.appendSaveBeforeMutation(record, mutationGeneration: 1))
    #expect(runtime.markSent(recordID: record.recordID, mutationGeneration: 1))
    writer.fenceSynchronously()

    #expect(!runtime.markDeliveryFailure(
        recordID: record.recordID,
        mutationGeneration: 1,
        permanent: false,
        rebasedRecord: record))
}

@Test("a WAL failure stays not-cache-ready across later full fetch epochs")
func shadowFailureIsSticky() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    await writer.fenceAndPark()

    #expect(!runtime.appendSaveBeforeMutation(runtimeRecord(), mutationGeneration: 1))
    #expect(!runtime.isCacheReady)
    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(
        records: [runtimeRecord()], coverageRevision: 1, zoneEnsured: true)
    let publication = try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: true)

    #expect(publication == nil)
    #expect(try await writer.loadCurrent() == nil)
}

@Test("clearing a shadow scope fences stale callbacks and removes the whole checkpoint")
func clearingShadowRuntimeFencesStaleCallbacks() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    try await publishBoundary(runtime: runtime, records: [runtimeRecord()])
    #expect(try await writer.loadCurrent() != nil)

    try runtime.clear()
    _ = try runtime.observeStateUpdate(Data([2]), coverageRevision: 2, zoneEnsured: true)
    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(
        records: [runtimeRecord()], coverageRevision: 2, zoneEnsured: true)

    #expect(try await writer.loadCurrent() == nil)
}

@Test("parking a shadow scope fences callbacks without deleting its checkpoint")
func parkingShadowRuntimePreservesCheckpoint() async throws {
    let root = try runtimeDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: runtimeScope(), rootDirectory: root)
    let runtime = ShadowMirrorRuntime(writer: writer)
    try await publishBoundary(runtime: runtime, records: [runtimeRecord()])
    let parkedGeneration = try #require(await writer.loadCurrent()).manifest.generationID

    runtime.park()
    _ = try runtime.observeStateUpdate(Data([2]), coverageRevision: 2, zoneEnsured: true)
    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(
        records: [runtimeRecord()], coverageRevision: 2, zoneEnsured: true)

    #expect(try await writer.loadCurrent()?.manifest.generationID == parkedGeneration)
}

private func publishBoundary(runtime: ShadowMirrorRuntime, records: [CKRecord]) async throws {
    runtime.beginFetchEpoch()
    _ = try runtime.completeFetchEpoch(records: records, coverageRevision: 1, zoneEnsured: true)
    let candidate = try runtime.observeStateUpdate(
        Data([1]), coverageRevision: 1, zoneEnsured: true)
    let publication = try #require(candidate)
    try await runtime.publish(publication)
}

private func runtimeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("simmersmith-e0a-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func runtimeScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "account-test",
        zoneOwnerName: "owner-test",
        zoneName: "household-test",
        householdID: "household-test",
        role: .owner,
        databaseScope: .private)
}

private func runtimeRecord(recordName: String = "recipe-test") -> CKRecord {
    let record = CKRecord(
        recordType: "Recipe",
        recordID: CKRecord.ID(
            recordName: recordName,
            zoneID: CKRecordZone.ID(zoneName: "household-test", ownerName: "owner-test")))
    record["name"] = "Runtime soup" as CKRecordValue
    return record
}
#endif
