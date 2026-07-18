import CloudKit
import Foundation
import HouseholdSync
import SimmerSmithKit
import Testing
@testable import SimmerSmith

// e0a P2 spec §3.3: real-engine proof of gated resumable construction. The package suite pins
// the pure reconciliation core; these tests prove the wiring against a genuine CKSyncEngine —
// which only the entitled simulator-hosted app can construct (the unsigned package host traps
// in CloudKit; see decisions.md 2026-07-17). No test syncs: engines are non-automatic and any
// send/fetch attempted here is expected to fail without an account — only local engine state,
// the delegate gate, and the on-disk scope are asserted.

private let bootstrapZone = CKRecordZone.ID(
    zoneName: "household-bootstrap-household", ownerName: CKCurrentUserDefaultName)

private func bootstrapScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "bootstrap-probe-account",
        zoneOwnerName: bootstrapZone.ownerName,
        zoneName: bootstrapZone.zoneName,
        householdID: "bootstrap-household",
        role: .owner,
        databaseScope: .private)
}

private func bootstrapExpectedIdentity() -> MirrorBootstrapExpectedIdentity {
    MirrorBootstrapExpectedIdentity(
        accountRecordName: "bootstrap-probe-account",
        role: .owner,
        zone: MirrorZoneReference(
            ownerName: bootstrapZone.ownerName, zoneName: bootstrapZone.zoneName),
        participantMarkerZone: nil)
}

private func bootstrapRecord(_ name: String, value: String = "v1") -> CKRecord {
    let record = CKRecord(
        recordType: "Recipe", recordID: CKRecord.ID(recordName: name, zoneID: bootstrapZone))
    record["name"] = value as CKRecordValue
    return record
}

private func bootstrapRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("engine-bootstrap-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func temporaryStateURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("engine-bootstrap-state-\(UUID().uuidString).json")
}

private final class CaptureDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CKSyncEngine.State.Serialization>.Continuation
    let serializations: AsyncStream<CKSyncEngine.State.Serialization>

    init() {
        (serializations, continuation) = AsyncStream.makeStream(
            of: CKSyncEngine.State.Serialization.self)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .stateUpdate(let update) = event {
            continuation.yield(update.stateSerialization)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}

private func makeDatabase() -> CKDatabase {
    CKContainer(identifier: MirrorScope.currentContainerIdentifier).privateCloudDatabase
}

/// Captures a genuine `State.Serialization` (JSON-encoded) whose restored pending set equals
/// `pending` — the same probe loop CKSyncEngineStateProbeTests proved on this SDK.
private func captureSerialization(
    pending: [CKSyncEngine.PendingRecordZoneChange]
) async throws -> Data {
    let delegate = CaptureDelegate()
    var configuration = CKSyncEngine.Configuration(
        database: makeDatabase(), stateSerialization: nil, delegate: delegate)
    configuration.automaticallySync = false
    let engine = CKSyncEngine(configuration)
    if pending.isEmpty {
        let probe = CKSyncEngine.PendingRecordZoneChange.saveRecord(
            CKRecord.ID(recordName: "serialization-probe", zoneID: bootstrapZone))
        engine.state.add(pendingRecordZoneChanges: [probe])
        engine.state.remove(pendingRecordZoneChanges: [probe])
    } else {
        engine.state.add(pendingRecordZoneChanges: pending)
    }
    let expected = Set(pending)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var captured: Data?
    for await serialization in delegate.serializations {
        let encoded = try JSONEncoder().encode(serialization)
        let decoded = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self, from: encoded)
        var verifyConfiguration = CKSyncEngine.Configuration(
            database: makeDatabase(), stateSerialization: decoded, delegate: CaptureDelegate())
        verifyConfiguration.automaticallySync = false
        let restored = CKSyncEngine(verifyConfiguration)
        if Set(restored.state.pendingRecordZoneChanges) == expected {
            captured = encoded
            break
        }
        guard ContinuousClock.now < deadline else { break }
    }
    withExtendedLifetime(engine) {}
    return try #require(captured, "no captured serialization restored the expected pending set")
}

/// Seeds an anchored scope whose recovered durable plan is exactly `plan` after restart
/// normalization: pending save r1 (a sent v2 edit returned to pending), pending delete r2,
/// checkpoint records r1(v1)/r2, and one acknowledged pre-checkpoint proof.
private func seedScope(
    root: URL,
    serialization: Data,
    includeDelete: Bool
) async throws {
    let writer = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    let first = try await writer.appendSave(
        bootstrapRecord("r1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: first, mutationGeneration: 1)
    try await writer.publish(
        records: [bootstrapRecord("r1"), bootstrapRecord("r2")],
        engineState: MirrorEngineState(
            serialization: serialization, coverageRevision: 1, zoneEnsured: true))
    _ = try await writer.acknowledge(sequence: first, mutationGeneration: 1)
    let second = try await writer.appendSave(
        bootstrapRecord("r1", value: "v2"), mutationGeneration: 2, changedFields: ["name"])
    _ = try await writer.markSent(sequence: second, mutationGeneration: 2)
    if includeDelete {
        try await writer.appendDelete(
            MirrorRecordIdentity(bootstrapRecord("r2")), mutationGeneration: 3)
    }
    await writer.fenceAndPark()
}

private func openCachedBootstrap(
    root: URL
) throws -> (bootstrap: MirrorBootstrap, writer: ShadowMirrorCheckpointWriter) {
    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "bootstrap-probe-account"), rootDirectory: root)
    guard case .cached(let bootstrap, let writer) = result.outcome else {
        throw MirrorCheckpointError.notCacheReady("expected cached bootstrap")
    }
    return (bootstrap, writer)
}

@Test("a verified bootstrap resumes a real engine whose reconciled state equals the plan")
func bootstrapResumeMatchesDurablePlan() async throws {
    let serialization = try await captureSerialization(pending: [
        .saveRecord(bootstrapRecord("r1").recordID),
        .deleteRecord(bootstrapRecord("r2").recordID),
    ])
    let root = try bootstrapRoot()
    try await seedScope(root: root, serialization: serialization, includeDelete: true)
    let (bootstrap, writer) = try openCachedBootstrap(root: root)

    let store = HouseholdLocalStore()
    let engine = try HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: writer,
            expectedIdentity: bootstrapExpectedIdentity()))

    // Store, generations, and runtime are ready before activation; the gate stays closed.
    #expect(engine.bootstrapGateOutcome == nil)
    #expect(store.allRecords().count == 1)
    #expect(store.record(for: bootstrapRecord("r1").recordID)?["name"] as? String == "v2")

    try engine.activateBootstrapCandidate()

    #expect(engine.bootstrapGateOutcome == .open)
    #expect(engine.hasPendingRecordChanges)
    let snapshot = Set(engine.canonicalPendingChangesSnapshot())
    #expect(snapshot == Set(bootstrap.pendingChanges.map(MirrorEnginePendingChange.init)))

    // Activation is one-shot: the gate has resolved and cannot be re-run.
    #expect(throws: MirrorBootstrapEngineError.activationUnavailable) {
        try engine.activateBootstrapCandidate()
    }
}

@Test("activation adds a durable-plan operation the serialized state is missing")
func bootstrapActivationAddsMissingTarget() async throws {
    // The serialization predates the delete of r2; the durable plan carries it.
    let serialization = try await captureSerialization(pending: [
        .saveRecord(bootstrapRecord("r1").recordID)
    ])
    let root = try bootstrapRoot()
    try await seedScope(root: root, serialization: serialization, includeDelete: true)
    let (bootstrap, writer) = try openCachedBootstrap(root: root)
    #expect(bootstrap.pendingChanges.count == 2)

    let engine = try HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: HouseholdLocalStore(),
        stateURL: temporaryStateURL(),
        automaticSync: false,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: writer,
            expectedIdentity: bootstrapExpectedIdentity()))
    try engine.activateBootstrapCandidate()

    #expect(engine.bootstrapGateOutcome == .open)
    let snapshot = Set(engine.canonicalPendingChangesSnapshot())
    #expect(snapshot == Set(bootstrap.pendingChanges.map(MirrorEnginePendingChange.init)))
    #expect(snapshot.contains(MirrorEnginePendingChange(
        recordID: bootstrapRecord("r2").recordID, operation: .delete)))
}

@Test("an unproven serialized pending rejects the candidate, quarantines, and falls back")
func bootstrapUnprovenPendingRejectsAndQuarantines() async throws {
    // The serialization carries a stray pending save no durable intent or proof covers.
    let serialization = try await captureSerialization(pending: [
        .saveRecord(bootstrapRecord("r1").recordID),
        .saveRecord(bootstrapRecord("stray").recordID),
    ])
    let root = try bootstrapRoot()
    try await seedScope(root: root, serialization: serialization, includeDelete: false)
    let (bootstrap, writer) = try openCachedBootstrap(root: root)

    let store = HouseholdLocalStore()
    let engine = try HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: writer,
            expectedIdentity: bootstrapExpectedIdentity()))
    #expect(!store.allRecords().isEmpty)

    #expect(throws: MirrorBootstrapReconciliationError.unprovenSerializedPending(
        MirrorEnginePendingChange(
            recordID: bootstrapRecord("stray").recordID, operation: .save))
    ) {
        try engine.activateBootstrapCandidate()
    }

    // Rejection cleared the store before content could render and quarantined the exact scope.
    #expect(engine.bootstrapGateOutcome == .rejected)
    #expect(store.allRecords().isEmpty)
    #expect(writer.activeGenerationLeaseCount == 0)
    let reopened = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "bootstrap-probe-account"), rootDirectory: root)
    guard case .none = reopened.outcome else {
        Issue.record("a rejected candidate's scope must not be selectable again")
        return
    }
    let quarantined = try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("quarantine").path)
    #expect(quarantined.contains { $0.hasPrefix(bootstrapScope().cacheKey) })

    // The fallback control remains the exact P1 nil-state engine.
    let fallback = HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false)
    #expect(!fallback.hasPendingRecordChanges)
    #expect(store.allRecords().isEmpty)
}

@Test("recovery overlay rejects every invalid intent before mutating the fetched store")
func recoveryOverlayIsFailClosedAndAtomic() throws {
    let root = try bootstrapRoot()
    let writer = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    let valid = try ShadowMirrorRecordEnvelope.archive(
        bootstrapRecord("valid"), in: root.appendingPathComponent("assets", isDirectory: true))
    let validIntent = MirrorOutboxIntent(
        sequence: 1, mutationGeneration: 1, operation: .save, record: valid,
        changedFields: ["name"])
    // This malformed save used to be skipped by `try? envelope.decode()` while the valid save
    // was still applied and recovery was marked complete.
    let invalidIntent = MirrorOutboxIntent(
        sequence: 2, mutationGeneration: 2, operation: .save, record: nil,
        changedFields: ["name"])
    let plan = MirrorRecoveryPlan(
        scope: bootstrapScope(),
        outbox: [validIntent, invalidIntent],
        pendingChanges: [],
        removalProofs: [],
        maxMutationGenerationByIdentity: [:],
        journalHighWater: 2,
        interventionCount: 0,
        lease: writer.acquireGenerationLeaseSynchronously(
            generationID: nil, pinnedJournalAssetSequences: []))
    let store = HouseholdLocalStore()
    let engine = HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false)

    #expect(throws: MirrorCheckpointError.self) {
        try engine.applyRecoveryPlan(plan, writer: writer)
    }
    #expect(store.allRecords().isEmpty)
    #expect(!engine.hasPendingRecordChanges)
}

@Test("recovery overlay installs every normalized save and delete exactly once after the fetch barrier")
func recoveryOverlayInstallsDurablePlanOnce() throws {
    let root = try bootstrapRoot()
    let writer = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    let savedRecord = bootstrapRecord("recovered-save", value: "durable")
    let savedIdentity = MirrorRecordIdentity(savedRecord)
    let deletedIdentity = MirrorRecordIdentity(bootstrapRecord("recovered-delete"))
    let envelope = try ShadowMirrorRecordEnvelope.archive(
        savedRecord, in: root.appendingPathComponent("assets", isDirectory: true))
    let plan = MirrorRecoveryPlan(
        scope: bootstrapScope(),
        outbox: [
            MirrorOutboxIntent(
                sequence: 1, mutationGeneration: 1, operation: .save, record: envelope,
                changedFields: ["name"]),
            MirrorOutboxIntent(
                sequence: 2, mutationGeneration: 1, operation: .delete, tombstone: deletedIdentity),
        ],
        pendingChanges: [
            MirrorNormalizedPendingChange(identity: savedIdentity, operation: .save),
            MirrorNormalizedPendingChange(identity: deletedIdentity, operation: .delete),
        ],
        removalProofs: [],
        maxMutationGenerationByIdentity: [savedIdentity: 1, deletedIdentity: 1],
        journalHighWater: 2,
        interventionCount: 0,
        lease: writer.acquireGenerationLeaseSynchronously(
            generationID: nil, pinnedJournalAssetSequences: []))
    let store = HouseholdLocalStore()
    let engine = HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false)

    try engine.applyRecoveryPlan(plan, writer: writer)
    #expect(store.record(for: savedRecord.recordID)?["name"] as? String == "durable")
    #expect(store.record(for: CKRecord.ID(recordName: "recovered-delete", zoneID: bootstrapZone)) == nil)
    #expect(Set(engine.canonicalPendingChangesSnapshot()) == Set(plan.pendingChanges.map(MirrorEnginePendingChange.init)))
    #expect(throws: MirrorBootstrapEngineError.activationUnavailable) {
        try engine.applyRecoveryPlan(plan, writer: writer)
    }
}

@Test("the closed gate holds real delegate callbacks until activation opens it")
func bootstrapGateHoldsDelegateCallbacksUntilOpen() async throws {
    let serialization = try await captureSerialization(pending: [
        .saveRecord(bootstrapRecord("r1").recordID)
    ])
    let root = try bootstrapRoot()
    try await seedScope(root: root, serialization: serialization, includeDelete: false)
    let (bootstrap, writer) = try openCachedBootstrap(root: root)

    let engine = try HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: HouseholdLocalStore(),
        stateURL: temporaryStateURL(),
        automaticSync: false,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: writer,
            expectedIdentity: bootstrapExpectedIdentity()))

    // Drive the engine's own delegate machinery while the gate is closed. The operations
    // themselves are expected to fail without an iCloud account — the assertion is only that
    // every delegate entry point queued behind the gate instead of running.
    let sendTask = Task { try? await engine.sendChanges() }
    let fetchTask = Task { try? await engine.fetchChanges() }

    let queueDeadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < queueDeadline {
        if engine.eventTrace.contains(where: { $0.hasPrefix("bootstrap gate queued") }) { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let trace = engine.eventTrace
    #expect(
        trace.contains { $0.hasPrefix("bootstrap gate queued") },
        "no delegate callback reached the gate: \(trace)")
    // Nothing may pass the closed gate: no event processing, no batch, no state persistence.
    #expect(!trace.contains { $0.hasPrefix("saved ") || $0.hasPrefix("fetched ") })
    #expect(engine.bootstrapGateOutcome == nil)

    try engine.activateBootstrapCandidate()
    #expect(engine.bootstrapGateOutcome == .open)

    // Queued delegate work drains after open — the held operations complete (even by failing).
    _ = await sendTask.value
    _ = await fetchTask.value
    let drained = engine.eventTrace
    let queuedIndex = try #require(
        drained.firstIndex { $0.hasPrefix("bootstrap gate queued") })
    let openIndex = try #require(drained.firstIndex { $0 == "bootstrap gate open" })
    #expect(queuedIndex < openIndex)
}

@MainActor
@Test("cached bootstrap rejects a failed WAL append before mutating store or pending state while P1 remains diagnostic-only")
func cachedWALFailureFailsClosedBeforeMutation() async throws {
    let serialization = try await captureSerialization(pending: [])
    let root = try bootstrapRoot()
    let sourceWriter = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    try await sourceWriter.publish(
        records: [bootstrapRecord("cached-base")],
        engineState: MirrorEngineState(
            serialization: serialization, coverageRevision: 1, zoneEnsured: true))
    let failingWriter = try ShadowMirrorCheckpointWriter(
        scope: bootstrapScope(),
        rootDirectory: root,
        failurePoint: .beforeJournalAppend)
    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "bootstrap-probe-account"), rootDirectory: root)
    guard case .cached(let bootstrap, let sourceLeaseWriter) = result.outcome else {
        Issue.record("expected a materialized cached bootstrap")
        return
    }
    defer { sourceLeaseWriter.releaseGenerationLeaseSynchronously(bootstrap.lease.id) }
    let session = HouseholdSession(
        householdID: bootstrap.scope.householdID,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: failingWriter,
            expectedIdentity: bootstrapExpectedIdentity()))
    defer { session.detach() }
    #expect(session.isCachedBootstrap)
    let cached = session.engine
    let rejectedRecord = bootstrapRecord("must-not-mutate")
    let pendingBefore = cached.canonicalPendingChangesSnapshot()

    #expect(!cached.save(rejectedRecord))
    #expect(session.store.record(for: rejectedRecord.recordID) == nil)
    #expect(cached.canonicalPendingChangesSnapshot() == pendingBefore)

    // The engine→session handoff must retain this automatic callback until AppState installs
    // its dispatcher; otherwise the rejected mutation has no retry/intervention signal.
    await Task.yield()
    var authorityEvents: [HouseholdAuthorityEvent] = []
    session.onAuthorityEvent = { authorityEvents.append($0) }
    await Task.yield()
    #expect(authorityEvents == [
        .intervention("Couldn't save this cached change safely. Retry when storage is available.")
    ])

    let p1Store = HouseholdLocalStore()
    let p1 = HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: p1Store,
        stateURL: temporaryStateURL(),
        automaticSync: false)
    let p1Record = bootstrapRecord("p1-still-saves")
    #expect(p1.save(p1Record))
    #expect(p1Store.record(for: p1Record.recordID) != nil)
    #expect(p1.hasPendingRecordChanges)
}

@Test("recovery overlay also rejects a failed WAL append before local mutation")
func recoveryWALFailureFailsClosedBeforeMutation() throws {
    let root = try bootstrapRoot()
    let writer = try ShadowMirrorCheckpointWriter(
        scope: bootstrapScope(),
        rootDirectory: root,
        failurePoint: .beforeJournalAppend)
    let plan = MirrorRecoveryPlan(
        scope: bootstrapScope(),
        outbox: [],
        pendingChanges: [],
        removalProofs: [],
        maxMutationGenerationByIdentity: [:],
        journalHighWater: 0,
        interventionCount: 0,
        lease: writer.acquireGenerationLeaseSynchronously(
            generationID: nil,
            pinnedJournalAssetSequences: []))
    let store = HouseholdLocalStore()
    let engine = HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false)
    try engine.applyRecoveryPlan(plan, writer: writer)
    let record = bootstrapRecord("recovery-must-not-mutate")

    #expect(!engine.save(record))
    #expect(store.record(for: record.recordID) == nil)
    #expect(!engine.hasPendingRecordChanges)
}

@Test("recovery delete rejects a failed WAL append before local mutation")
func recoveryDeleteWALFailureFailsClosedBeforeMutation() throws {
    let root = try bootstrapRoot()
    let writer = try ShadowMirrorCheckpointWriter(
        scope: bootstrapScope(),
        rootDirectory: root,
        failurePoint: .beforeJournalAppend)
    let plan = MirrorRecoveryPlan(
        scope: bootstrapScope(),
        outbox: [],
        pendingChanges: [],
        removalProofs: [],
        maxMutationGenerationByIdentity: [:],
        journalHighWater: 0,
        interventionCount: 0,
        lease: writer.acquireGenerationLeaseSynchronously(
            generationID: nil,
            pinnedJournalAssetSequences: []))
    let store = HouseholdLocalStore()
    let fetchedRecord = bootstrapRecord("recovery-delete-must-not-mutate")
    store.setRecord(fetchedRecord)
    let engine = HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: store,
        stateURL: temporaryStateURL(),
        automaticSync: false)
    try engine.applyRecoveryPlan(plan, writer: writer)

    engine.delete(fetchedRecord.recordID)

    #expect(store.record(for: fetchedRecord.recordID) != nil)
    #expect(!engine.hasPendingRecordChanges)
}

@MainActor
@Test("owner and participant recovery use the production AppState direct-pending-intervention publication path")
func ownerAndParticipantRecoveryAuthorityProductionPath() throws {
    let participantZone = CKRecordZone.ID(
        zoneName: "household-participant-recovery",
        ownerName: "participant-owner")
    let cases: [(HouseholdSessionRole, MirrorScope)] = [
        (
            .owner,
            MirrorScope(
                accountRecordName: "owner-account",
                zoneOwnerName: CKCurrentUserDefaultName,
                zoneName: "household-owner-recovery",
                householdID: "owner-recovery",
                role: .owner,
                databaseScope: .private)),
        (
            .participant(sharedZoneID: participantZone),
            MirrorScope(
                accountRecordName: "participant-account",
                zoneOwnerName: participantZone.ownerName,
                zoneName: participantZone.zoneName,
                householdID: "participant-recovery",
                role: .participant,
                databaseScope: .shared)),
    ]

    for (role, scope) in cases {
        let root = try bootstrapRoot()
        let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
        let lease = writer.acquireGenerationLeaseSynchronously(
            generationID: nil,
            pinnedJournalAssetSequences: [])
        let plan = MirrorRecoveryPlan(
            scope: scope,
            outbox: [],
            pendingChanges: [],
            removalProofs: [],
            maxMutationGenerationByIdentity: [:],
            journalHighWater: 0,
            interventionCount: 1,
            lease: lease)
        let session = HouseholdSession(
            householdID: scope.householdID,
            role: role,
            recoveryCandidate: MirrorRecoveryCandidate(plan: plan, writer: writer))
        let first = CKRecord(
            recordType: "Recipe",
            recordID: CKRecord.ID(recordName: "pending-1", zoneID: session.zoneID))
        let second = CKRecord(
            recordType: "Recipe",
            recordID: CKRecord.ID(recordName: "pending-2", zoneID: session.zoneID))
        #expect(session.engine.save(first))
        #expect(session.engine.save(second))
        session.syncPhase = .synced(Date(timeIntervalSince1970: 200))

        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false)
        state.householdSession = session
        state.publishDirectHouseholdAuthority(session: session, epoch: state.sessionBootEpoch)

        #expect(session.engine.pendingRecordChangeCount == 2)
        #expect(state.householdAuthority == .intervention(
            message: "1 durable change needs attention."))
        session.detach()
        writer.releaseGenerationLeaseSynchronously(lease.id)
    }
}

@Test("successful cached leases stay pinned through park and release only when the engine owner is disposed")
func cachedLeaseReleasesAtTeardownOnly() async throws {
    let serialization = try await captureSerialization(pending: [])
    let root = try bootstrapRoot()
    let sourceWriter = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    try await sourceWriter.publish(
        records: [bootstrapRecord("cached-base")],
        engineState: MirrorEngineState(
            serialization: serialization, coverageRevision: 1, zoneEnsured: true))
    let result = ShadowMirrorBootstrapCatalog.open(
        request: .owner(accountRecordName: "bootstrap-probe-account"), rootDirectory: root)
    guard case .cached(let bootstrap, let writer) = result.outcome else {
        Issue.record("expected a materialized cached bootstrap")
        return
    }
    #expect(writer.activeGenerationLeaseCount == 1)
    var engine: HouseholdSyncEngine? = try HouseholdSyncEngine(
        database: makeDatabase(),
        zoneID: bootstrapZone,
        store: HouseholdLocalStore(),
        stateURL: temporaryStateURL(),
        automaticSync: false,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: writer,
            expectedIdentity: bootstrapExpectedIdentity()))
    try engine?.activateBootstrapCandidate()
    #expect(writer.activeGenerationLeaseCount == 1)

    engine?.parkShadowMirror()
    #expect(writer.activeGenerationLeaseCount == 1)
    engine?.parkShadowMirror()
    #expect(writer.activeGenerationLeaseCount == 1)
    engine = nil
    #expect(writer.activeGenerationLeaseCount == 0)
}
