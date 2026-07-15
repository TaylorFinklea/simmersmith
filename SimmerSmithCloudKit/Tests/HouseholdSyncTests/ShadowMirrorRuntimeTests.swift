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
