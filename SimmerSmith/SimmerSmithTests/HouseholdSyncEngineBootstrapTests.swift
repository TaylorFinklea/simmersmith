import CloudKit
import Foundation
import GroceryMerge
import HouseholdRecords
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

private final class RecipeMigrationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body) = Self.responses[path] ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func recipeMigrationClient() -> SimmerSmithAPIClient {
    let suite = "RecipeMigrationBootstrapTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set("http://recipe-migration.test", forKey: ConnectionSettingsStore.Keys.serverURL)
    let settings = ConnectionSettingsStore(
        defaults: defaults,
        keychain: KeychainStore(service: suite)
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecipeMigrationURLProtocol.self]
    return SimmerSmithAPIClient(
        settingsStore: settings,
        session: URLSession(configuration: configuration)
    )
}

private func requiredRecipeMigrationResponses() -> [String: (Int, Data)] {
    let recipes = """
    [{
      "recipe_id": "required-save-recipe",
      "name": "Required Save Soup",
      "updated_at": "2026-07-18T00:00:00Z",
      "ingredients": [{
        "ingredient_id": "required-save-ingredient",
        "ingredient_name": "Carrot"
      }],
      "steps": [{
        "step_id": "required-save-step",
        "sort_order": 0,
        "instruction": "Simmer"
      }]
    }]
    """
    let metadata = """
    {
      "cuisines": [{
        "item_id": "required-save-cuisine",
        "kind": "cuisine",
        "name": "Home",
        "normalized_name": "home",
        "updated_at": "2026-07-18T00:00:00Z"
      }]
    }
    """
    let memories = """
    [{
      "id": "required-save-memory",
      "body": "Keep the lid on",
      "created_at": "2026-07-18T00:00:00Z",
      "photo_url": null
    }]
    """
    return [
        "/api/recipes": (200, Data(recipes.utf8)),
        "/api/recipes/metadata": (200, Data(metadata.utf8)),
        "/api/recipes/required-save-recipe/memories": (200, Data(memories.utf8)),
    ]
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

@MainActor
private func openJournalRejectedCachedSession() async throws -> HouseholdSession {
    let serialization = try await captureSerialization(pending: [])
    let root = try bootstrapRoot()
    let sourceWriter = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    try await sourceWriter.publish(
        records: [bootstrapRecord("core-fix5-base")],
        engineState: MirrorEngineState(
            serialization: serialization, coverageRevision: 1, zoneEnsured: true)
    )
    let (bootstrap, sourceLeaseWriter) = try openCachedBootstrap(root: root)
    sourceLeaseWriter.releaseGenerationLeaseSynchronously(bootstrap.lease.id)
    let failingWriter = try ShadowMirrorCheckpointWriter(
        scope: bootstrap.scope,
        rootDirectory: root,
        failurePoint: .beforeJournalAppend
    )
    let session = HouseholdSession(
        householdID: bootstrap.scope.householdID,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: failingWriter,
            expectedIdentity: bootstrapExpectedIdentity())
    )
    guard session.promoteCachedAuthority() else {
        throw MirrorCheckpointError.notCacheReady("failed to promote cached journal-rejection fixture")
    }
    return session
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

    if case .durabilityFailure = engine.delete(fetchedRecord.recordID) {
        // Expected: recovery's durable writer rejects the delete before store mutation.
    } else {
        Issue.record("recovery delete did not surface its WAL failure")
    }

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

@Suite("P2f final core propagation integration")
@MainActor
struct P2fFinalCorePropagationIntegrationTests {
    @Test("an unpromoted cached engine stops unmerge before its success writes")
    func cachedUnpromotedEngineRejectsAdapterUnmergeWithoutSuccessTail() async throws {
        let serialization = try await captureSerialization(pending: [])
        let root = try bootstrapRoot()
        try await seedScope(root: root, serialization: serialization, includeDelete: false)
        let (bootstrap, writer) = try openCachedBootstrap(root: root)
        let session = HouseholdSession(
            householdID: bootstrap.scope.householdID,
            bootstrapCandidate: MirrorBootstrapCandidate(
                bootstrap: bootstrap,
                writer: writer,
                expectedIdentity: bootstrapExpectedIdentity()))
        defer { session.detach() }
        #expect(session.isCachedBootstrap)
        #expect(!session.hasCurrentAuthority)

        let weekID = "cached-unmerge-week"
        let eventOnlyID = "cached-unmerge-event-only"
        let eventOnlyRecordID = CKRecord.ID(recordName: eventOnlyID, zoneID: session.zoneID)
        session.store.setRecord(GroceryCodec.makeRecord(
            GroceryMerge.GroceryItem(
                recordName: eventOnlyID,
                weekID: weekID,
                unit: "cup",
                normalizedName: "tomato",
                sourceMeals: "event:Dinner",
                eventQuantity: 1),
            zoneID: session.zoneID))
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()
        #expect(session.engine.delete(eventOnlyRecordID) == .notAuthoritative)
        #expect(session.engine.deleteCascading(eventOnlyRecordID) == .notAuthoritative)

        let adapter = EventMergeAdapter(engine: session.engine, zoneID: session.zoneID)
        let event = GroceryMerge.Event(
            recordName: "cached-unmerge-event",
            name: "Dinner",
            linkedWeekID: weekID)
        let eventRows = [GroceryMerge.EventGroceryItem(
            recordName: "cached-unmerge-row",
            mergedIntoGroceryItemID: eventOnlyID,
            mergedIntoWeekID: weekID,
            eventQuantity: 1)]

        do {
            _ = try adapter.unmerge(event: event, eventRows: eventRows, fromWeek: weekID)
            Issue.record("an unpromoted cached engine reported a successful unmerge")
        } catch let result as HouseholdDataPlaneResult {
            #expect(result == .notAuthoritative)
        }

        #expect(session.store.record(for: eventOnlyRecordID) != nil)
        #expect(session.store.record(for: CKRecord.ID(recordName: "cached-unmerge-row", zoneID: session.zoneID)) == nil)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
    }

    @Test("a denied repair prune stops before cascading the first audit batch")
    func deniedRepairPruneLeavesStoreAndPendingChangesUntouched() throws {
        let store = HouseholdLocalStore()
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: false)
        let engine = HouseholdSyncEngine(
            database: makeDatabase(),
            zoneID: bootstrapZone,
            store: store,
            stateURL: temporaryStateURL(),
            automaticSync: false,
            authority: authority
        )
        let weekID = "repair-denied-week"
        let batchID = CKRecord.ID(recordName: "repair-denied-batch", zoneID: bootstrapZone)
        let batch = CKRecord(
            recordType: HouseholdRecordType.weekChangeBatch.recordTypeName,
            recordID: batchID
        )
        batch["week"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: weekID, zoneID: bootstrapZone),
            action: .deleteSelf
        )
        batch["createdAt"] = Date() as CKRecordValue
        store.setRecord(batch)
        let pendingBefore = engine.canonicalPendingChangesSnapshot()
        let adapter = WeekRepairAdapter(engine: engine, zoneID: bootstrapZone)

        do {
            _ = try adapter.pruneAudit(weekID: weekID, keep: 0)
            Issue.record("a denied repair prune reported success")
        } catch let result as HouseholdDataPlaneResult {
            #expect(result == .notAuthoritative)
        }

        #expect(store.record(for: batchID) != nil)
        #expect(engine.canonicalPendingChangesSnapshot() == pendingBefore)
    }

    @Test("a denied week collapse stops before reparenting a loser subtree")
    func deniedWeekCollapseLeavesWeeksAndChildrenUntouched() async throws {
        let store = HouseholdLocalStore()
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: false)
        let engine = HouseholdSyncEngine(
            database: makeDatabase(),
            zoneID: bootstrapZone,
            store: store,
            stateURL: temporaryStateURL(),
            automaticSync: false,
            authority: authority
        )
        let keeperID = CKRecord.ID(recordName: "collapse-a", zoneID: bootstrapZone)
        let loserID = CKRecord.ID(recordName: "collapse-b", zoneID: bootstrapZone)
        for id in [keeperID, loserID] {
            let week = CKRecord(recordType: HouseholdRecordType.week.recordTypeName, recordID: id)
            week["weekStart"] = Date(timeIntervalSince1970: 0) as CKRecordValue
            store.setRecord(week)
        }
        let mealID = CKRecord.ID(recordName: "collapse-meal", zoneID: bootstrapZone)
        let meal = CKRecord(recordType: HouseholdRecordType.weekMeal.recordTypeName, recordID: mealID)
        meal["week"] = CKRecord.Reference(recordID: loserID, action: .deleteSelf)
        store.setRecord(meal)
        let pendingBefore = engine.canonicalPendingChangesSnapshot()
        let adapter = WeekRepairAdapter(engine: engine, zoneID: bootstrapZone)

        do {
            _ = try await adapter.collapseWeeks()
            Issue.record("a denied week collapse reported success")
        } catch let result as HouseholdDataPlaneResult {
            #expect(result == .notAuthoritative)
        }

        #expect(store.record(for: keeperID) != nil)
        #expect(store.record(for: loserID) != nil)
        #expect((store.record(for: mealID)?["week"] as? CKRecord.Reference)?.recordID == loserID)
        #expect(engine.canonicalPendingChangesSnapshot() == pendingBefore)
    }

    @Test("owner adoption parking retries the retained writer only after durable parking succeeds")
    func ownerAdoptionParkingRetryIsFailClosedThenMakesScopeNonselectable() async throws {
        let serialization = try await captureSerialization(pending: [])
        let root = try bootstrapRoot()
        try await seedScope(root: root, serialization: serialization, includeDelete: false)
        let opened = ShadowMirrorBootstrapCatalog.open(
            request: .owner(accountRecordName: "bootstrap-probe-account"),
            rootDirectory: root
        )
        guard case .cached(let bootstrap, let sourceLeaseWriter) = opened.outcome else {
            Issue.record("expected a cached owner bootstrap")
            return
        }
        // This fixture substitutes an injected writer for the catalog writer. Transfer is not
        // supported, so release the catalog lease before constructing that substitute; otherwise
        // a later catalog open is blocked by a lease the test's session never owns.
        sourceLeaseWriter.releaseGenerationLeaseSynchronously(bootstrap.lease.id)

        let retryWriter = try ShadowMirrorCheckpointWriter(
            scope: bootstrap.scope,
            rootDirectory: root,
            failurePoint: .beforeParkingPersistence
        )
        let session = HouseholdSession(
            householdID: bootstrap.scope.householdID,
            bootstrapCandidate: MirrorBootstrapCandidate(
                bootstrap: bootstrap,
                writer: retryWriter,
                expectedIdentity: bootstrapExpectedIdentity())
        )
        defer { session.detach() }
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false
        )
        state.clearParticipantMarker()
        defer { state.clearParticipantMarker() }
        state.householdSession = session
        state.householdLaunchPhase = .ready
        state.publishDirectHouseholdAuthority(session: session, epoch: state.sessionBootEpoch)

        #expect(!state.teardownHouseholdSession(
            clearShadowRoot: false,
            parkOwnerScopeForAdoption: true
        ))
        #expect(state.householdSession == nil)
        #expect(state.householdLaunchPhase == .resolving)
        #expect(state.pendingAdoptionParkingSession === session)
        #expect(state.loadParticipantMarker() == nil)

        let selectable = ShadowMirrorBootstrapCatalog.open(
            request: .owner(accountRecordName: "bootstrap-probe-account"),
            rootDirectory: root
        )
        guard case .cached(let cached, let selectableWriter) = selectable.outcome else {
            Issue.record("failed parking must not create a durable parked marker")
            return
        }
        selectableWriter.releaseGenerationLeaseSynchronously(cached.lease.id)

        #expect(state.completePendingShadowRootRetirementIfNeeded())
        #expect(state.pendingAdoptionParkingSession == nil)
        #expect(state.loadParticipantMarker() == nil)
        let parked = ShadowMirrorBootstrapCatalog.open(
            request: .owner(accountRecordName: "bootstrap-probe-account"),
            rootDirectory: root
        )
        guard case .none = parked.outcome else {
            Issue.record("successful retained-writer retry did not make the owner scope nonselectable")
            return
        }
    }

    @Test("a cached owner cannot prepare a share before current-session authority")
    func cachedOwnerSharePreparationFailsBeforeCloudKitPresentation() async throws {
        let serialization = try await captureSerialization(pending: [])
        let root = try bootstrapRoot()
        try await seedScope(root: root, serialization: serialization, includeDelete: false)
        let (bootstrap, writer) = try openCachedBootstrap(root: root)
        let session = HouseholdSession(
            householdID: bootstrap.scope.householdID,
            bootstrapCandidate: MirrorBootstrapCandidate(
                bootstrap: bootstrap,
                writer: writer,
                expectedIdentity: bootstrapExpectedIdentity())
        )
        defer { session.detach() }
        #expect(session.role.isOwner)
        #expect(!session.hasCurrentAuthority)

        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false
        )
        state.householdSession = session
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()

        do {
            _ = try await state.prepareOwnerShare(title: "No cached share")
            Issue.record("a cached owner prepared a share before reconciliation")
        } catch let result as CachedHouseholdSystemOperationResult {
            #expect(result == .retryableNotAuthoritative)
        } catch {
            Issue.record("unexpected cached owner share result: \(error)")
        }

        #expect(state.householdSession === session)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
    }
}

@Suite("P2f core correction 5 cached WAL paths", .serialized)
@MainActor
struct P2fCoreFix5CachedWALTests {
    @Test("unmerge stops before hard delete or link work when its replacement save rejects the WAL")
    func unmergeStopsBeforeLaterWorkAfterReplacementSaveWALFailure() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let weekID = "core-fix5-unmerge-week"
        let replacement = GroceryMerge.GroceryItem(
            recordName: "core-fix5-unmerge-replacement",
            weekID: weekID,
            unit: "cup",
            normalizedName: "rice",
            totalQuantity: 2,
            sourceMeals: "meal:Monday",
            eventQuantity: 2
        )
        let hardDelete = GroceryMerge.GroceryItem(
            recordName: "core-fix5-unmerge-hard-delete",
            weekID: weekID,
            unit: "cup",
            normalizedName: "tomato",
            sourceMeals: "event:Dinner",
            eventQuantity: 1
        )
        session.store.setRecord(GroceryCodec.makeRecord(replacement, zoneID: session.zoneID))
        session.store.setRecord(GroceryCodec.makeRecord(hardDelete, zoneID: session.zoneID))
        let eventID = CKRecord.ID(recordName: "core-fix5-unmerge-event", zoneID: session.zoneID)
        let eventRecord = CKRecord(recordType: HouseholdRecordType.event.recordTypeName, recordID: eventID)
        eventRecord["linkedWeekID"] = weekID as CKRecordValue
        session.store.setRecord(eventRecord)
        let event = GroceryMerge.Event(
            recordName: eventID.recordName,
            name: "Dinner",
            linkedWeekID: weekID
        )
        let eventRows = [
            GroceryMerge.EventGroceryItem(
                recordName: "core-fix5-unmerge-replacement-link",
                mergedIntoGroceryItemID: replacement.recordName,
                mergedIntoWeekID: weekID,
                eventQuantity: 1
            ),
            GroceryMerge.EventGroceryItem(
                recordName: "core-fix5-unmerge-hard-delete-link",
                mergedIntoGroceryItemID: hardDelete.recordName,
                mergedIntoWeekID: weekID,
                eventQuantity: 1
            ),
        ]
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()

        do {
            _ = try EventMergeAdapter(engine: session.engine, zoneID: session.zoneID).unmerge(
                event: event,
                eventRows: eventRows,
                fromWeek: weekID
            )
            Issue.record("unmerge reported success after its replacement save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected: the failed prerequisite save is surfaced by the adapter.
            } else {
                Issue.record("unmerge surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("unmerge surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: hardDeleteRecordID(hardDelete, zoneID: session.zoneID)) != nil)
        #expect((session.store.record(for: eventID)?["linkedWeekID"] as? String) == weekID)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }

    @Test("duplicate-week collapse stops before drain or loser delete when reparent save rejects the WAL")
    func collapseStopsBeforeLaterWorkAfterReparentSaveWALFailure() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let keeperID = CKRecord.ID(recordName: "core-fix5-collapse-keeper", zoneID: session.zoneID)
        let loserID = CKRecord.ID(recordName: "core-fix5-collapse-loser", zoneID: session.zoneID)
        for id in [keeperID, loserID] {
            let week = CKRecord(recordType: HouseholdRecordType.week.recordTypeName, recordID: id)
            week["weekStart"] = Date(timeIntervalSince1970: 0) as CKRecordValue
            session.store.setRecord(week)
        }
        let meal = CKRecord(
            recordType: HouseholdRecordType.weekMeal.recordTypeName,
            recordID: CKRecord.ID(recordName: "core-fix5-collapse-meal", zoneID: session.zoneID)
        )
        meal["week"] = CKRecord.Reference(recordID: loserID, action: .deleteSelf)
        session.store.setRecord(meal)
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()

        do {
            _ = try await WeekRepairAdapter(engine: session.engine, zoneID: session.zoneID).collapseWeeks()
            Issue.record("duplicate-week collapse reported success after a reparent save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected: collapse must surface the rejected prerequisite save.
            } else {
                Issue.record("duplicate-week collapse surfaced \(result) instead of durability failure")
            }
        } catch {
            Issue.record("duplicate-week collapse surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: loserID) != nil)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }

    @Test("backup restore throws durability failure without a second drain or synced tail after required save rejection")
    func backupRestoreStopsAfterRequiredSaveWALFailure() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false
        )
        state.householdSession = session
        var drainCalls = 0
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: live.saveCurrentWeekCarryOver,
            fetchChanges: { _ in },
            drainChanges: { _, _ in drainCalls += 1 },
            prepareZoneWideShare: live.prepareZoneWideShare
        )
        let restoredRecordName = "core-fix5-restored-recipe"
        let backup = HouseholdBackup(
            capturedAt: .now,
            appBuild: "P2f",
            role: "owner",
            records: [HouseholdRecordValue(
                type: .recipe,
                recordName: restoredRecordName,
                scalars: ["name": .string("Rejected restore")]
            )]
        )

        do {
            try await state.restoreHousehold(from: backup)
            Issue.record("backup restore reported success after a required save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected: a failed restore save is a typed durability failure.
            } else {
                Issue.record("backup restore surfaced \(result) instead of durability failure")
            }
        } catch {
            Issue.record("backup restore surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: CKRecord.ID(
            recordName: restoredRecordName,
            zoneID: session.zoneID
        )) == nil)
        #expect(session.engine.canonicalPendingChangesSnapshot().isEmpty)
        #expect(drainCalls == 1)
        #expect(state.syncPhase == .loading)
    }
}

@Suite("P2f core correction 6 promoted cached WAL path", .serialized)
@MainActor
struct P2fCoreFix6CachedWALTests {
    @Test("auto-merge policy stops before delete or link work when its first week-row save rejects the WAL")
    func promotedCachedAutoMergePolicyStopsAfterWeekRowSaveWALFailure() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let weekID = "core-fix6-auto-merge-week"
        let retained = GroceryMerge.GroceryItem(
            recordName: "core-fix6-auto-merge-retained",
            weekID: weekID,
            unit: "cup",
            normalizedName: "rice",
            totalQuantity: 2,
            sourceMeals: "meal:Monday",
            eventQuantity: 2
        )
        let hardDelete = GroceryMerge.GroceryItem(
            recordName: "core-fix6-auto-merge-hard-delete",
            weekID: weekID,
            unit: "cup",
            normalizedName: "tomato",
            sourceMeals: "event:Dinner",
            eventQuantity: 1
        )
        session.store.setRecord(GroceryCodec.makeRecord(retained, zoneID: session.zoneID))
        session.store.setRecord(GroceryCodec.makeRecord(hardDelete, zoneID: session.zoneID))

        let weekRecord = CKRecord(
            recordType: HouseholdRecordType.week.recordTypeName,
            recordID: CKRecord.ID(recordName: weekID, zoneID: session.zoneID)
        )
        weekRecord["weekStart"] = Date(timeIntervalSince1970: 0) as CKRecordValue
        weekRecord["weekEnd"] = Date(timeIntervalSince1970: 7 * 24 * 60 * 60) as CKRecordValue
        session.store.setRecord(weekRecord)

        let eventID = "core-fix6-auto-merge-event"
        let eventRecord = CKRecord(
            recordType: HouseholdRecordType.event.recordTypeName,
            recordID: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)
        )
        eventRecord["name"] = "Dinner" as CKRecordValue
        eventRecord["linkedWeekID"] = weekID as CKRecordValue
        eventRecord["autoMergeGrocery"] = 0 as CKRecordValue
        eventRecord["manuallyMerged"] = 0 as CKRecordValue
        session.store.setRecord(eventRecord)

        let eventRows = [
            GroceryMerge.EventGroceryItem(
                recordName: "\(eventID)_eg_retained",
                mergedIntoGroceryItemID: retained.recordName,
                mergedIntoWeekID: weekID,
                eventQuantity: 1
            ),
            GroceryMerge.EventGroceryItem(
                recordName: "\(eventID)_eg_hard-delete",
                mergedIntoGroceryItemID: hardDelete.recordName,
                mergedIntoWeekID: weekID,
                eventQuantity: 1
            ),
        ]
        for row in eventRows {
            session.store.setRecord(EventGroceryCodec.makeRecord(row, zoneID: session.zoneID))
        }
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()
        let repository = EventRepository(session: session, guests: GuestRepository(session: session))

        do {
            try repository.applyAutoMergePolicy(eventID: eventID)
            Issue.record("auto-merge policy reported success after its first week-row save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected: the rejected prerequisite save is surfaced before delete/link work.
            } else {
                Issue.record("auto-merge policy surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("auto-merge policy surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: hardDeleteRecordID(hardDelete, zoneID: session.zoneID)) != nil)
        let retainedAfterFailure = try #require(session.store.record(for: CKRecord.ID(
            recordName: retained.recordName,
            zoneID: session.zoneID
        )))
        #expect(GroceryCodec.decode(retainedAfterFailure).eventQuantity == retained.eventQuantity)
        #expect((session.store.record(for: eventRecord.recordID)?["linkedWeekID"] as? String) == weekID)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }
}

@Suite("P2f core correction 7 direct authority and WAL propagation", .serialized)
@MainActor
struct P2fCoreFix7WALPropagationTests {
    @Test("a production-style direct session begins without destructive authority")
    func directSessionStartsDeniedUntilItsInitialFetchSucceeds() {
        let session = HouseholdSession(householdID: "core-fix7-direct-\(UUID().uuidString)")
        defer { session.detach() }

        #expect(!session.hasCurrentAuthority)
        #expect(session.engine.dataPlaneResult(for: .delete) == .notAuthoritative)
        #expect(session.engine.dataPlaneResult(for: .deleteCascading) == .notAuthoritative)
        #expect(session.engine.dataPlaneResult(for: .zoneRecreation) == .notAuthoritative)
    }

    @Test("grocery regeneration stops before tombstone delete when its first prerequisite upsert rejects the WAL")
    func groceryRegenerationStopsAfterRejectedPrerequisiteUpsert() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let weekID = "core-fix7-grocery-week"
        let preserved = GroceryMerge.GroceryItem(
            recordName: "core-fix7-grocery-upsert",
            weekID: weekID,
            unit: "cup",
            normalizedName: "preserved",
            totalQuantity: 1,
            sourceMeals: "old meal",
            check: GroceryMerge.CheckState(isChecked: true)
        )
        let tombstone = GroceryMerge.GroceryItem(
            recordName: "core-fix7-grocery-tombstone",
            weekID: weekID,
            unit: "cup",
            normalizedName: "discard",
            totalQuantity: 1,
            sourceMeals: "old meal"
        )
        session.store.setRecord(GroceryCodec.makeRecord(preserved, zoneID: session.zoneID))
        session.store.setRecord(GroceryCodec.makeRecord(tombstone, zoneID: session.zoneID))
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()

        let result = GroceryRepository(session: session).regenerate(weekID: weekID)

        if case .durabilityFailure = result {
            // Expected: no delete/reload/drain success tail after the first rejected upsert.
        } else {
            Issue.record("grocery regeneration returned \(result) after its prerequisite save rejected the WAL")
        }
        #expect(session.store.record(for: hardDeleteRecordID(tombstone, zoneID: session.zoneID)) != nil)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }

    @Test("week meal replacement stops before cascading delete when its first upsert rejects the WAL")
    func weekSaveStopsAfterRejectedPrerequisiteUpsert() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let weekID = "core-fix7-week"
        let weekRecord = CKRecord(
            recordType: HouseholdRecordType.week.recordTypeName,
            recordID: CKRecord.ID(recordName: weekID, zoneID: session.zoneID)
        )
        weekRecord["weekStart"] = Date(timeIntervalSince1970: 0) as CKRecordValue
        weekRecord["weekEnd"] = Date(timeIntervalSince1970: 7 * 24 * 60 * 60) as CKRecordValue
        session.store.setRecord(weekRecord)
        let staleMealID = CKRecord.ID(recordName: "core-fix7-stale-week-meal", zoneID: session.zoneID)
        let staleMeal = CKRecord(recordType: HouseholdRecordType.weekMeal.recordTypeName, recordID: staleMealID)
        staleMeal["week"] = CKRecord.Reference(recordID: weekRecord.recordID, action: .deleteSelf)
        staleMeal["dayName"] = "Monday" as CKRecordValue
        staleMeal["slot"] = "dinner" as CKRecordValue
        session.store.setRecord(staleMeal)
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()

        do {
            _ = try WeekRepository(session: session).saveWeekMeals(
                weekID: weekID,
                meals: [MealUpdateRequest(
                    dayName: "Tuesday",
                    mealDate: Date(timeIntervalSince1970: 24 * 60 * 60),
                    slot: "dinner",
                    recipeName: "Replacement"
                )],
                knownMealIDs: [staleMealID.recordName]
            )
            Issue.record("week save reported success after its first meal upsert rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected.
            } else {
                Issue.record("week save surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("week save surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: staleMealID) != nil)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }

    @Test("recipe child diff stops before stale-child delete when its first public save rejects the WAL")
    func recipeChildDiffStopsAfterRejectedPublicSave() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let recipeID = "core-fix7-recipe"
        let recipeRecord = CKRecord(
            recordType: HouseholdRecordType.recipe.recordTypeName,
            recordID: CKRecord.ID(recordName: recipeID, zoneID: session.zoneID)
        )
        recipeRecord["name"] = "Existing recipe" as CKRecordValue
        session.store.setRecord(recipeRecord)
        let staleChildID = CKRecord.ID(recordName: "core-fix7-stale-ingredient", zoneID: session.zoneID)
        let staleChild = CKRecord(
            recordType: HouseholdRecordType.recipeIngredient.recordTypeName,
            recordID: staleChildID
        )
        staleChild["recipe"] = CKRecord.Reference(recordID: recipeRecord.recordID, action: .deleteSelf)
        staleChild["ingredientName"] = "Old ingredient" as CKRecordValue
        session.store.setRecord(staleChild)
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()

        do {
            _ = try RecipeRepository(session: session).save(RecipeDraft(
                recipeId: recipeID,
                name: "Existing recipe",
                ingredients: [RecipeIngredient(ingredientName: "New ingredient")]
            ))
            Issue.record("recipe child diff reported success after its prerequisite save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected.
            } else {
                Issue.record("recipe child diff surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("recipe child diff surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: staleChildID) != nil)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }

    @Test("event attendee sync stops before stale-attendee delete when its first public save rejects the WAL")
    func eventAttendeeSyncStopsAfterRejectedPublicSave() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let eventID = "core-fix7-event"
        let eventRecord = CKRecord(
            recordType: HouseholdRecordType.event.recordTypeName,
            recordID: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)
        )
        eventRecord["name"] = "Dinner" as CKRecordValue
        eventRecord["occasion"] = "other" as CKRecordValue
        eventRecord["status"] = "planning" as CKRecordValue
        session.store.setRecord(eventRecord)
        let staleAttendeeID = CKRecord.ID(recordName: "\(eventID)_stale", zoneID: session.zoneID)
        let staleAttendee = CKRecord(
            recordType: HouseholdRecordType.eventAttendee.recordTypeName,
            recordID: staleAttendeeID
        )
        staleAttendee["event"] = CKRecord.Reference(recordID: eventRecord.recordID, action: .deleteSelf)
        staleAttendee["guest"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: "stale", zoneID: session.zoneID),
            action: .none
        )
        session.store.setRecord(staleAttendee)
        let pendingBefore = session.engine.canonicalPendingChangesSnapshot()
        let repository = EventRepository(session: session, guests: GuestRepository(session: session))

        do {
            _ = try repository.updateEvent(
                eventID: eventID,
                name: "Dinner",
                eventDate: nil,
                occasion: "other",
                attendeeCount: 1,
                notes: "",
                status: "planning",
                attendees: [(guestID: "new", plusOnes: 0)],
                knownGuestIDs: ["stale"]
            )
            Issue.record("event attendee sync reported success after its prerequisite save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected.
            } else {
                Issue.record("event attendee sync surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("event attendee sync surfaced an unexpected error: \(error)")
        }

        #expect(session.store.record(for: staleAttendeeID) != nil)
        #expect(session.engine.canonicalPendingChangesSnapshot() == pendingBefore)
        #expect(!session.engine.eventTrace.contains("cached delete denied: WAL append failed"))
    }

    @Test("event merge stops before row and link writes when its first save rejects the WAL")
    func eventMergeStopsAfterRejectedPrerequisiteSave() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let eventID = "core-fix7-merge-event"
        let weekID = "core-fix7-merge-week"
        let eventRecord = CKRecord(
            recordType: HouseholdRecordType.event.recordTypeName,
            recordID: CKRecord.ID(recordName: eventID, zoneID: session.zoneID)
        )
        eventRecord["name"] = "Dinner" as CKRecordValue
        session.store.setRecord(eventRecord)
        let eventRow = GroceryMerge.EventGroceryItem(
            recordName: "core-fix7-merge-row",
            eventQuantity: 1,
            normalizedName: "rice",
            unit: "cup"
        )
        let eventRowID = CKRecord.ID(recordName: eventRow.recordName, zoneID: session.zoneID)
        session.store.setRecord(EventGroceryCodec.makeRecord(eventRow, zoneID: session.zoneID))

        do {
            _ = try EventMergeAdapter(engine: session.engine, zoneID: session.zoneID).merge(
                event: GroceryMerge.Event(recordName: eventID, name: "Dinner"),
                eventRows: [eventRow],
                intoWeek: weekID
            )
            Issue.record("event merge reported success after its first save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected.
            } else {
                Issue.record("event merge surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("event merge surfaced an unexpected error: \(error)")
        }

        let rowAfterFailure = try #require(session.store.record(for: eventRowID))
        #expect(EventGroceryCodec.decode(rowAfterFailure).mergedIntoWeekID == nil)
        #expect(session.store.record(for: eventRecord.recordID)?["linkedWeekID"] == nil)
    }

    @Test("grocery dedupe stops before later tombstone and link writes when its first save rejects the WAL")
    func groceryDedupeStopsAfterRejectedPrerequisiteSave() async throws {
        let session = try await openJournalRejectedCachedSession()
        defer { session.detach() }
        let weekID = "core-fix7-dedupe-week"
        let keeper = GroceryMerge.GroceryItem(
            recordName: "core-fix7-dedupe-keeper",
            weekID: weekID,
            unit: "cup",
            normalizedName: "rice",
            totalQuantity: 1,
            sourceMeals: "meal:Monday",
            modifiedAt: 1
        )
        let loser = GroceryMerge.GroceryItem(
            recordName: "core-fix7-dedupe-loser",
            weekID: weekID,
            unit: "cup",
            normalizedName: "rice",
            totalQuantity: 1,
            sourceMeals: "meal:Tuesday",
            modifiedAt: 2
        )
        session.store.setRecord(GroceryCodec.makeRecord(keeper, zoneID: session.zoneID))
        session.store.setRecord(GroceryCodec.makeRecord(loser, zoneID: session.zoneID))
        let eventRow = GroceryMerge.EventGroceryItem(
            recordName: "core-fix7-dedupe-link",
            mergedIntoGroceryItemID: loser.recordName,
            mergedIntoWeekID: weekID,
            eventQuantity: 1
        )
        let eventRowID = CKRecord.ID(recordName: eventRow.recordName, zoneID: session.zoneID)
        session.store.setRecord(EventGroceryCodec.makeRecord(eventRow, zoneID: session.zoneID))

        do {
            _ = try EventMergeAdapter(engine: session.engine, zoneID: session.zoneID).dedupeWeekGrocery(
                weekID: weekID,
                eventLinks: [eventRow]
            )
            Issue.record("grocery dedupe reported success after its first save rejected the WAL")
        } catch let result as HouseholdDataPlaneResult {
            if case .durabilityFailure = result {
                // Expected.
            } else {
                Issue.record("grocery dedupe surfaced \(result) instead of a durability failure")
            }
        } catch {
            Issue.record("grocery dedupe surfaced an unexpected error: \(error)")
        }

        let loserAfterFailure = try #require(session.store.record(for: hardDeleteRecordID(
            loser,
            zoneID: session.zoneID
        )))
        #expect(!GroceryCodec.decode(loserAfterFailure).isUserRemoved)
        let linkAfterFailure = try #require(session.store.record(for: eventRowID))
        #expect(EventGroceryCodec.decode(linkAfterFailure).mergedIntoGroceryItemID == loser.recordName)
    }
}

private func hardDeleteRecordID(
    _ item: GroceryMerge.GroceryItem,
    zoneID: CKRecordZone.ID
) -> CKRecord.ID {
    CKRecord.ID(recordName: item.recordName, zoneID: zoneID)
}

@Suite("P2f receipt-blocking recipe migration", .serialized)
@MainActor
struct P2fRecipeMigrationReceiptTests {
    @Test("a rejected required recipe write withholds the receipt until its retry completes")
    func requiredRecipeSaveFailureIsRetryableAndDoesNotStampTheReceipt() async throws {
        let serialization = try await captureSerialization(pending: [])
        let root = try bootstrapRoot()
        let sourceWriter = try ShadowMirrorCheckpointWriter(
            scope: bootstrapScope(), rootDirectory: root)
        try await sourceWriter.publish(
            records: [bootstrapRecord("recipe-migration-base")],
            engineState: MirrorEngineState(
                serialization: serialization, coverageRevision: 1, zoneEnsured: true)
        )
        let (bootstrap, sourceLeaseWriter) = try openCachedBootstrap(root: root)
        // The catalog writer owns this lease. This test needs a one-shot injected writer, so it
        // must release the catalog lease before substituting the writer rather than leave an
        // unrelated owner blocking the retry bootstrap.
        sourceLeaseWriter.releaseGenerationLeaseSynchronously(bootstrap.lease.id)
        let failingWriter = try ShadowMirrorCheckpointWriter(
            scope: bootstrapScope(),
            rootDirectory: root,
            failurePoint: .beforeJournalAppend
        )
        var failedSession: HouseholdSession? = HouseholdSession(
            householdID: bootstrap.scope.householdID,
            bootstrapCandidate: MirrorBootstrapCandidate(
                bootstrap: bootstrap,
                writer: failingWriter,
                expectedIdentity: bootstrapExpectedIdentity())
        )
        #expect(failedSession?.promoteCachedAuthority() == true)

        RecipeMigrationURLProtocol.responses = requiredRecipeMigrationResponses()
        let client = recipeMigrationClient()
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: "recipes"),
            zoneID: failedSession!.zoneID
        )

        let first = await migrateRecipesIfNeeded(session: failedSession!, apiClient: client)
        #expect(first == .retryable)
        #expect(failedSession!.store.record(for: receiptID) == nil)

        // WAL append failure fences the runtime by design. A retry has to reconstruct a fresh
        // authoritative cached session, not reuse the permanently fenced writer above.
        failedSession?.detach()
        failedSession = nil
        await Task.yield()

        let (retryBootstrap, retryWriter) = try openCachedBootstrap(root: root)
        let retrySession = HouseholdSession(
            householdID: retryBootstrap.scope.householdID,
            bootstrapCandidate: MirrorBootstrapCandidate(
                bootstrap: retryBootstrap,
                writer: retryWriter,
                expectedIdentity: bootstrapExpectedIdentity())
        )
        defer { retrySession.detach() }
        #expect(retrySession.promoteCachedAuthority())

        let retry = await migrateRecipesIfNeeded(
            session: retrySession,
            apiClient: client,
            requiredDataDrain: {})
        #expect(retry == .complete)
        #expect(retrySession.store.record(for: receiptID) != nil)
        #expect(retrySession.store.records(ofType: HouseholdRecordType.managedListItem.recordTypeName).count == 1)
        #expect(retrySession.store.record(for: CKRecord.ID(
            recordName: "required-save-recipe", zoneID: retrySession.zoneID
        )) != nil)
        #expect(retrySession.store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName).count == 1)
        #expect(retrySession.store.records(ofType: HouseholdRecordType.recipeStep.recordTypeName).count == 1)
        #expect(retrySession.store.records(ofType: HouseholdRecordType.recipeMemory.recordTypeName).count == 1)
    }
}

@MainActor
private struct CachedRemoteDeleteFixture {
    let session: HouseholdSession
    let writer: ShadowMirrorCheckpointWriter
    let leaseWriter: ShadowMirrorCheckpointWriter
    let lease: MirrorGenerationLease

    func tearDown() {
        session.detach()
        leaseWriter.releaseGenerationLeaseSynchronously(lease.id)
    }
}

@MainActor
private func cachedRemoteDeleteFixture() async throws -> CachedRemoteDeleteFixture {
    let serialization = try await captureSerialization(pending: [])
    let root = try bootstrapRoot()
    let sourceWriter = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    try await sourceWriter.publish(
        records: [bootstrapRecord("remote-delete-base")],
        engineState: MirrorEngineState(
            serialization: serialization, coverageRevision: 1, zoneEnsured: true)
    )
    let writer = try ShadowMirrorCheckpointWriter(scope: bootstrapScope(), rootDirectory: root)
    let (bootstrap, leaseWriter) = try openCachedBootstrap(root: root)
    let session = HouseholdSession(
        householdID: bootstrap.scope.householdID,
        bootstrapCandidate: MirrorBootstrapCandidate(
            bootstrap: bootstrap,
            writer: writer,
            expectedIdentity: bootstrapExpectedIdentity())
    )
    return CachedRemoteDeleteFixture(
        session: session,
        writer: writer,
        leaseWriter: leaseWriter,
        lease: bootstrap.lease
    )
}

@MainActor
private func remoteDeleteAppState(for session: HouseholdSession) throws -> AppState {
    let state = AppState(
        modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
        cacheFirstLaunchEnabled: false
    )
    state.householdSession = session
    state.publishCachedHouseholdAuthority(session: session, epoch: state.sessionBootEpoch)
    return state
}

@Suite("P2f fetched remote-delete production integration")
@MainActor
struct P2fRemoteDeleteIntegrationTests {
    @Test("an unpromoted cached pending save is terminally superseded and publishes intervention")
    func remoteDeleteSupersedesPreAuthoritySaveWithoutResurrection() async throws {
        let fixture = try await cachedRemoteDeleteFixture()
        defer { fixture.tearDown() }
        let state = try remoteDeleteAppState(for: fixture.session)
        let record = bootstrapRecord("remote-delete-pre-authority")

        #expect(!fixture.session.hasCurrentAuthority)
        #expect(fixture.session.engine.save(record))
        #expect(fixture.session.engine.pendingRecordChangeCount == 1)

        fixture.session.engine.handleFetchedRemoteDeletion(record.recordID)
        for _ in 0..<3 { await Task.yield() }

        #expect(fixture.session.store.record(for: record.recordID) == nil)
        #expect(fixture.session.engine.pendingRecordChangeCount == 0)
        #expect(!fixture.session.engine.hasPendingRecordChanges)
        #expect(try fixture.writer.recoveryStateSynchronously().outbox.map(\.delivery.state)
            == [.supersededByRemoteDelete])
        guard case .intervention = state.householdAuthority else {
            Issue.record("remote-delete terminal conflict did not publish AppState intervention")
            return
        }
    }

    @Test("a promoted cached pending save is terminally superseded without resurrection")
    func remoteDeleteSupersedesPostAuthoritySaveWithoutResurrection() async throws {
        let fixture = try await cachedRemoteDeleteFixture()
        defer { fixture.tearDown() }
        let state = try remoteDeleteAppState(for: fixture.session)
        #expect(fixture.session.promoteCachedAuthority())
        let record = bootstrapRecord("remote-delete-post-authority")

        #expect(fixture.session.engine.save(record))
        fixture.session.engine.handleFetchedRemoteDeletion(record.recordID)
        for _ in 0..<3 { await Task.yield() }

        #expect(fixture.session.store.record(for: record.recordID) == nil)
        #expect(fixture.session.engine.pendingRecordChangeCount == 0)
        #expect(!fixture.session.engine.hasPendingRecordChanges)
        #expect(try fixture.writer.recoveryStateSynchronously().outbox.map(\.delivery.state)
            == [.supersededByRemoteDelete])
        guard case .intervention = state.householdAuthority else {
            Issue.record("promoted remote-delete terminal conflict did not publish intervention")
            return
        }
    }

    @Test("a matching pending delete is consumed without publishing a permanent conflict")
    func remoteDeleteConsumesMatchingDeleteAsSuccess() async throws {
        let fixture = try await cachedRemoteDeleteFixture()
        defer { fixture.tearDown() }
        let state = try remoteDeleteAppState(for: fixture.session)
        #expect(fixture.session.promoteCachedAuthority())
        let record = bootstrapRecord("remote-delete-matching-delete")
        fixture.session.store.setRecord(record)

        #expect(fixture.session.engine.delete(record.recordID) == .allowed)
        #expect(fixture.session.engine.pendingRecordChangeCount == 1)
        fixture.session.engine.handleFetchedRemoteDeletion(record.recordID)
        for _ in 0..<3 { await Task.yield() }

        #expect(fixture.session.store.record(for: record.recordID) == nil)
        #expect(fixture.session.engine.pendingRecordChangeCount == 0)
        #expect(!fixture.session.engine.hasPendingRecordChanges)
        #expect(try fixture.writer.recoveryStateSynchronously().outbox.isEmpty)
        if case .intervention = state.householdAuthority {
            Issue.record("matching remote delete published a permanent conflict")
        }
    }
}
