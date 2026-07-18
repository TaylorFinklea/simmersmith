#if canImport(CloudKit)
import CloudKit
import Foundation
import HouseholdRecords
import OSLog

/// A save failure the engine gave up retrying automatically (or classified as permanent).
/// Feeds the future sync-status UI (simmersmith-qrt); this type is only the engine-level seam
/// — wiring it into `HouseholdSession`/`AppState` is qrt's scope, not this bead's.
public struct SyncFailure: Sendable {
    /// Whether a blind retry could plausibly succeed.
    public enum Kind: Sendable {
        /// Worth re-enqueuing (network blip, rate limit, server busy) — CKSyncEngine applies
        /// its own backoff timing on re-enqueue.
        case transient
        /// Won't succeed on retry without user/developer intervention (quota, auth, permissions,
        /// unrecognized codes default here so nothing loops forever unseen).
        case permanent
    }

    public let recordName: String
    public let code: CKError.Code
    public let kind: Kind
    public let message: String

    public init(recordName: String, code: CKError.Code, kind: Kind, message: String) {
        self.recordName = recordName
        self.code = code
        self.kind = kind
        self.message = message
    }
}

/// Buffers automatic engine callbacks until one complete handler set is installed. This closes
/// the construction-to-session-dispatch window where a cached engine can activate and receive
/// CloudKit events before AppState has an authority sink.
enum HouseholdSyncEngineCallback: Sendable {
    case storeChanged
    case syncError(SyncFailure)
    case recordSaved(String)
    case durabilityFailure(MirrorDurabilityFailure)
    case participantRevoked
    case accountChanged
}

final class HouseholdSyncEngineCallbackRelay: @unchecked Sendable {
    typealias Handlers = (
        storeChanged: (@Sendable () -> Void)?,
        syncError: (@Sendable (SyncFailure) -> Void)?,
        recordSaved: (@Sendable (String) -> Void)?,
        durabilityFailure: (@Sendable (MirrorDurabilityFailure) -> Void)?,
        participantRevoked: (@Sendable () -> Void)?,
        accountChanged: (@Sendable () -> Void)?
    )

    private let lock = NSLock()
    private var handlers: Handlers?
    private var buffered: [HouseholdSyncEngineCallback] = []
    private var isDraining = false

    func install(_ handlers: Handlers) {
        let shouldDrain = lock.withLock { () -> Bool in
            self.handlers = handlers
            guard !isDraining, !buffered.isEmpty else { return false }
            isDraining = true
            return true
        }
        if shouldDrain { drain() }
    }

    func clear() {
        lock.withLock {
            handlers = nil
            buffered = []
        }
    }

    func emit(_ event: HouseholdSyncEngineCallback) {
        let shouldDrain = lock.withLock { () -> Bool in
            buffered.append(event)
            guard handlers != nil, !isDraining else { return false }
            isDraining = true
            return true
        }
        if shouldDrain { drain() }
    }

    private func drain() {
        while true {
            let next = lock.withLock { () -> (HouseholdSyncEngineCallback, Handlers)? in
                guard let handlers, !buffered.isEmpty else {
                    isDraining = false
                    return nil
                }
                return (buffered.removeFirst(), handlers)
            }
            guard let (event, handlers) = next else { return }
            deliver(event, to: handlers)
        }
    }

    private func deliver(_ event: HouseholdSyncEngineCallback, to handlers: Handlers) {
        switch event {
        case .storeChanged:
            handlers.storeChanged?()
        case .syncError(let failure):
            handlers.syncError?(failure)
        case .recordSaved(let recordName):
            handlers.recordSaved?(recordName)
        case .durabilityFailure(let failure):
            handlers.durabilityFailure?(failure)
        case .participantRevoked:
            handlers.participantRevoked?()
        case .accountChanged:
            handlers.accountChanged?()
        }
    }
}

/// Per-batch capture of the exact local generation whose payload CKSyncEngine selected. The
/// record provider is `@Sendable`, so the snapshot owns its own lock rather than mutating a
/// captured dictionary. A later local save may advance the engine generation without changing
/// the generation attached to this already-built outbound payload.
private final class OutboundBatchGenerationSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [CKRecord.ID: Int] = [:]

    func capture(_ generation: Int, for recordID: CKRecord.ID) {
        guard generation > 0 else { return }
        lock.withLock { generations[recordID] = generation }
    }

    func generation(for recordID: CKRecord.ID) -> Int? {
        lock.withLock { generations[recordID] }
    }
}

/// SP-A Phase 2a — the household zone's single `CKSyncEngine` stack.
///
/// Spec §4.2: one household zone = ONE sync stack (two stacks racing the change token
/// forks the household). This driver owns that stack for a given zone on a given
/// database (private for the owner, shared for participants). Plain household records
/// sync as last-writer-wins pass-through; the grocery/event field-merge resolver plugs
/// into `HouseholdLocalStore.applyRemoteModification` at Phase 4.
///
/// `automaticSync` is configurable: the DEBUG round-trip drives `sync()` manually for
/// deterministic verification; the app turns automatic sync on.
public final class HouseholdSyncEngine: CKSyncEngineDelegate {
    public let database: CKDatabase
    public let zoneID: CKRecordZone.ID
    public let store: HouseholdLocalStore
    private let stateURL: URL
    /// P1 shadow-only checkpoint runtime. It is intentionally optional until a complete account
    /// scope has been resolved. The same gate orders store snapshots, generation bookkeeping,
    /// state coverage, durable outbox transitions, and lifecycle fencing.
    private let shadowMirrorLock = NSLock()
    private var shadowMirror: ShadowMirrorRuntime?
    private var shadowCoverageRevision: UInt64 = 0
    private var shadowStateHistory: [
        (
            serialization: Data,
            coverageRevision: UInt64,
            zoneEnsured: Bool,
            participantFetchProof: MirrorParticipantFetchCheckpointProof?
        )
    ] = []
    private var shadowCompletedFetch: (
        records: [CKRecord],
        coverageRevision: UInt64,
        zoneEnsured: Bool,
        participantFetchProof: MirrorParticipantFetchCheckpointProof?
    )?
    private var shadowFetchEpochOpen = false
    private var participantFetchProof: MirrorParticipantFetchProof = .unverified
    private var participantCheckpointProof: MirrorParticipantFetchCheckpointProof?
    private var shadowCaptureAllowed = true
    private var shadowMissedLocalMutation = false
    /// Cached bootstrap and successful recovery overlay sessions depend on their durable
    /// outbox. Unlike P1's diagnostic mirror, they must reject a mutation when the WAL cannot
    /// record it before the live store and sync-engine state change.
    private var durableMirrorRequired = false
    /// A materialized bootstrap/recovery lease pins all CKAsset and WAL roots referenced by the
    /// active store/runtime. It remains owned for the entire session and is released only after
    /// the runtime is fenced and active record/pending references are discarded at teardown.
    private var activeMirrorLease: (writer: ShadowMirrorCheckpointWriter, id: UUID)?
    /// A signed-out cached scope cannot be moved while CKSyncEngine may still retain an outbound
    /// CKAsset payload. Keep the root and lease until this engine owner is disposed.
    private var clearShadowRootOnDeinit: URL?
    private var shadowRootDirectory: URL?
    /// Owner engines own their zone (create it lazily, recreate on loss). A PARTICIPANT
    /// engine (shared DB) does NOT own the zone — it must never enqueue `.saveZone` nor
    /// recreate a zone it can't create, and a zone deletion means the share was revoked.
    private let ownsZone: Bool
    /// P2e keeps cached sessions fail-closed for destructive data-plane operations. P2f replaces
    /// this blanket mode with exact current-session authority.
    public let dataPlaneMode: HouseholdDataPlaneMode
    private let log = Logger(subsystem: "app.simmersmith.cloud", category: "HouseholdSync")
    private let callbackRelay = HouseholdSyncEngineCallbackRelay()

    private var syncEngine: CKSyncEngine!
    private let zoneEnsuredLock = NSLock()
    private var zoneEnsured = false

    /// P2 bootstrap seam (spec §3.3). Non-nil only for an engine constructed from a verified
    /// `MirrorBootstrapCandidate`; every delegate entry point waits behind it until
    /// `activateBootstrapCandidate()` proves the engine's direct state against the durable plan.
    /// Nil on the P1 nil-state control path — those engines take today's exact code paths.
    private let bootstrapGate: MirrorBootstrapDelegateGate?
    private var bootstrapCandidateState: MirrorBootstrapCandidate?
    private var recoveryPlanApplied = false

    /// Optional sticky field-merger (Phase 4). When set, records whose type it `handles`
    /// are field-merged at the fetch + serverRecordChanged seams instead of blanket LWW.
    public var merger: RecordMerger?

    /// Called once per sync event after the local store has been mutated by remote changes
    /// (`fetchedRecordZoneChanges`) or by server-authoritative record replacements
    /// (`sentRecordZoneChanges`). Set by `HouseholdSession`/`RecipeRepository` to trigger
    /// a cache refresh. Nil in tests — no behavioral change when unset.
    public var onStoreChanged: (@Sendable () -> Void)? {
        didSet { installLegacyEventHandlers() }
    }

    /// Called when a record save fails with an error the engine classifies as permanent (see
    /// `SyncFailure.Kind`) — i.e. one it will NOT silently re-enqueue. Called off-main from the
    /// delegate, mirroring `onStoreChanged`. Nil in tests and until a caller (simmersmith-qrt)
    /// wires it up — no behavioral change when unset.
    public var onSyncError: (@Sendable (SyncFailure) -> Void)? {
        didSet { installLegacyEventHandlers() }
    }

    /// Called when a cache-first mutation is rejected because its WAL append could not be made
    /// durable. This is intentionally separate from a server CKError: no local store or pending
    /// engine state changed, so callers can offer a retry/intervention without misclassifying it
    /// as a remote sync failure.
    public var onMirrorDurabilityFailure: (@Sendable (MirrorDurabilityFailure) -> Void)? {
        didSet { installLegacyEventHandlers() }
    }

    /// Called once per record whose pending change the server CONFIRMED — both
    /// `sentRecordZoneChanges.savedRecords` (share records excluded) and `.deletedRecordIDs`.
    /// simmersmith-ioj: a PERMANENT failure is never auto-re-enqueued (see `handleFailedSave`'s
    /// `.permanent` branch below), so the only in-band evidence that a previously-failed record
    /// is resolved is that record later reaching the server — either the user edits it again
    /// after fixing the cause (signs back into iCloud, frees storage), OR they delete it, which
    /// resolves the failure by removing the data. `SyncStatusCenter` matches on record name to
    /// clear a stale failure; a delete that never fired here would wedge the banner forever.
    /// Called off-main, mirroring `onStoreChanged`/`onSyncError`. Nil in tests and until a caller
    /// wires it up — no behavioral change when unset.
    public var onRecordSaved: (@Sendable (String) -> Void)? {
        didSet { installLegacyEventHandlers() }
    }

    /// Called when CloudKit removes/revokes the participant's shared zone. AppState clears its
    /// durable participant marker and advances the session epoch before returning to owner boot.
    public var onParticipantRevoked: (@Sendable () -> Void)? {
        didSet { installLegacyEventHandlers() }
    }

    /// Called after sign-out/account switch has fenced the old account's full shadow root.
    public var onAccountChanged: (@Sendable () -> Void)? {
        didSet { installLegacyEventHandlers() }
    }

    /// Installs all consumer callbacks atomically and drains automatic callbacks in the exact
    /// order received. HouseholdSession uses this rather than individual property assignments.
    public func installEventHandlers(
        onStoreChanged: (@Sendable () -> Void)?,
        onSyncError: (@Sendable (SyncFailure) -> Void)?,
        onRecordSaved: (@Sendable (String) -> Void)?,
        onMirrorDurabilityFailure: (@Sendable (MirrorDurabilityFailure) -> Void)?,
        onParticipantRevoked: (@Sendable () -> Void)? = nil,
        onAccountChanged: (@Sendable () -> Void)? = nil
    ) {
        callbackRelay.install((
            storeChanged: onStoreChanged,
            syncError: onSyncError,
            recordSaved: onRecordSaved,
            durabilityFailure: onMirrorDurabilityFailure,
            participantRevoked: onParticipantRevoked,
            accountChanged: onAccountChanged))
    }

    public func clearEventHandlers() {
        onStoreChanged = nil
        onSyncError = nil
        onRecordSaved = nil
        onMirrorDurabilityFailure = nil
        onParticipantRevoked = nil
        onAccountChanged = nil
        callbackRelay.clear()
    }

    private func installLegacyEventHandlers() {
        callbackRelay.install((
            storeChanged: onStoreChanged,
            syncError: onSyncError,
            recordSaved: onRecordSaved,
            durabilityFailure: onMirrorDurabilityFailure,
            participantRevoked: onParticipantRevoked,
            accountChanged: onAccountChanged))
    }

    // simmersmith-dkj: per-record LOCAL MUTATION GENERATION. `save()` bumps a record's
    // generation; `nextRecordZoneChangeBatch` stamps the generation each outgoing payload was
    // built from. At the ack we compare: if the record's generation moved between the send and
    // the ack, a second local edit interleaved and the acked payload is STALE — adopt the ack's
    // system fields onto the store's newer record instead of blindly replacing it.
    //
    // A generation counter (not `updatedAt`) is deliberate: `updatedAt` cannot see the whole
    // problem. GroceryItem/EventGroceryItem carry NO `updatedAt` at all (they use `createdAtClock`
    // / `modifiedAtClock` Int logical clocks — see GroceryCodec), and the grocery check/uncheck
    // double-tap is the highest-frequency edit surface in the app. `recipeMemory` and the
    // manifest-external CKAsset image types are likewise date-less. The generation is
    // type-agnostic and needs no schema field at all — it observes the STORE, not the payload.
    private var localGeneration: [CKRecord.ID: Int] = [:]
    private var sentGeneration: [CKRecord.ID: Int] = [:]

    @discardableResult
    private func bumpGenerationLocked(_ id: CKRecord.ID) -> UInt64 {
        localGeneration[id, default: 0] += 1
        return UInt64(localGeneration[id, default: 0])
    }

    /// Durably transition the exact local generation to sent before CKSyncEngine may receive its
    /// payload. Cached/recovery sessions fail closed; P1 preserves its diagnostic-only mirror.
    private func prepareSentGenerationLocked(
        _ id: CKRecord.ID,
        generation: Int?
    ) -> Bool {
        guard let generation, generation > 0 else { return !durableMirrorRequired }
        let mutationGeneration = UInt64(generation)
        let transitionAccepted: Bool
        if let shadowMirror {
            transitionAccepted = shadowMirror.markSent(
                recordID: id,
                mutationGeneration: mutationGeneration) || !durableMirrorRequired
        } else {
            transitionAccepted = !durableMirrorRequired
        }
        guard transitionAccepted else { return false }
        sentGeneration[id] = generation
        shadowCoverageRevision &+= 1
        return true
    }

    /// The generation the outgoing payload was built from plus whether a newer local mutation
    /// landed before its acknowledgement. Consumes the stamp because an ack resolves that send.
    private func consumeSentGenerationLocked(
        _ id: CKRecord.ID
    ) -> (generation: UInt64?, isStale: Bool) {
        guard let sent = sentGeneration.removeValue(forKey: id) else { return (nil, false) }
        return (UInt64(sent), localGeneration[id, default: 0] != sent)
    }

    private let traceLock = NSLock()
    private var trace: [String] = []
    /// Diagnostic trace of sent/failed/fetched events (DEBUG round-trip uses it).
    public var eventTrace: [String] {
        traceLock.lock(); defer { traceLock.unlock() }
        return trace
    }
    private func note(_ s: String) {
        traceLock.lock(); trace.append(s); traceLock.unlock()
    }

    public init(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        store: HouseholdLocalStore,
        stateURL: URL,
        automaticSync: Bool = false,
        ownsZone: Bool = true,
        merger: RecordMerger? = nil,
        shadowMirrorRootDirectory: URL? = nil,
        dataPlaneMode: HouseholdDataPlaneMode = .normal
    ) {
        self.database = database
        self.zoneID = zoneID
        self.store = store
        self.stateURL = stateURL
        self.ownsZone = ownsZone
        self.dataPlaneMode = dataPlaneMode
        self.shadowRootDirectory = shadowMirrorRootDirectory
        self.bootstrapGate = nil
        self.durableMirrorRequired = dataPlaneMode == .cached
        // simmersmith-c7r: assign BEFORE `self.syncEngine` is constructed below. With
        // `automaticSync == true`, CKSyncEngine can deliver `handleEvent` on its own
        // background queue the instant it exists — if `merger` were still nil at that
        // point (previously set post-construction by `HouseholdSession.start()`), a
        // remote change could race in and fall through to blanket LWW instead of
        // `FieldMergeResolver`, corrupting sticky grocery/event fields.
        self.merger = merger

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.coldStartStateSerialization(),
            delegate: self
        )
        configuration.automaticallySync = automaticSync
        self.syncEngine = CKSyncEngine(configuration)
    }

    // MARK: P2 gated resumable construction (spec §3.3)

    /// Constructs a candidate engine from one verified bootstrap. Store content, per-record
    /// mutation generations, zone state, and the continuing checkpoint runtime are ready before
    /// the `CKSyncEngine` exists; the engine receives the bootstrap serialization instead of
    /// nil, and every delegate entry point waits behind the closed gate. The candidate is inert
    /// until `activateBootstrapCandidate()` proves its direct state against the durable plan.
    ///
    /// Candidate validation failure quarantines the exact scope, releases its generation
    /// lease, clears the store, and throws — the caller falls back to the nil-state engine.
    public init(
        database: CKDatabase,
        zoneID: CKRecordZone.ID,
        store: HouseholdLocalStore,
        stateURL: URL,
        automaticSync: Bool = false,
        merger: RecordMerger? = nil,
        bootstrapCandidate candidate: MirrorBootstrapCandidate,
        shadowMirrorRootDirectory: URL? = nil,
        dataPlaneMode: HouseholdDataPlaneMode = .cached
    ) throws {
        self.database = database
        self.zoneID = zoneID
        self.store = store
        self.stateURL = stateURL
        // The bootstrap scope's role decides zone ownership; validation below pins the scope
        // against the caller's live identity and this engine's zone.
        self.ownsZone = candidate.bootstrap.scope.role == .owner
        self.dataPlaneMode = dataPlaneMode
        self.shadowRootDirectory = shadowMirrorRootDirectory
        self.merger = merger
        do {
            try MirrorBootstrapReconciler.validateCandidate(
                scope: candidate.bootstrap.scope,
                zoneEnsured: candidate.bootstrap.zoneEnsured,
                expected: candidate.expectedIdentity,
                engineZoneID: zoneID)
        } catch {
            Self.failBootstrapCandidate(candidate, store: store)
            throw error
        }
        self.bootstrapGate = MirrorBootstrapDelegateGate()
        self.bootstrapCandidateState = candidate
        self.durableMirrorRequired = true

        // Spec §3.3 step 1: the complete runtime exists before the candidate engine does.
        // Generation publication stays structurally fenced while the gate is closed — every
        // capture that could publish flows through a gated delegate callback.
        store.removeAll()
        for record in candidate.bootstrap.records {
            store.setRecord(record)
        }
        localGeneration = MirrorBootstrapReconciler.seededLocalGenerations(
            from: candidate.bootstrap.maxMutationGenerationByIdentity)
        zoneEnsured = candidate.bootstrap.zoneEnsured
        shadowMirror = ShadowMirrorRuntime(writer: candidate.writer)

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: candidate.bootstrap.engineStateSerialization,
            delegate: self
        )
        configuration.automaticallySync = automaticSync
        self.syncEngine = CKSyncEngine(configuration)
    }

    /// Spec §3.3 steps 4–6: canonicalize the candidate engine's direct pending state, diff it
    /// against the normalized durable plan through the public `state.remove`/`state.add` APIs,
    /// require an exact reprojection, then open the gate. Any failure rejects the candidate:
    /// the gate terminally discards queued delegate work, the store is cleared before content
    /// can render, the exact scope is quarantined, its lease is released, and the error is
    /// rethrown so the caller constructs a fresh nil-state/full-fetch engine.
    public func activateBootstrapCandidate() throws {
        guard let gate = bootstrapGate, gate.resolvedOutcome == nil,
              let candidate = bootstrapCandidateState else {
            throw MirrorBootstrapEngineError.activationUnavailable
        }
        do {
            try MirrorBootstrapReconciler.validateDatabaseState(
                serialized: canonicalPendingDatabaseChanges())
            let actions = try MirrorBootstrapReconciler.planRecordZoneReconciliation(
                serialized: canonicalPendingRecordZoneChanges(),
                plan: candidate.bootstrap.pendingChanges,
                removalProofs: candidate.bootstrap.removalProofs,
                scope: candidate.bootstrap.scope)
            if !actions.removals.isEmpty {
                syncEngine.state.remove(
                    pendingRecordZoneChanges: actions.removals.map(\.pendingRecordZoneChange))
            }
            if !actions.additions.isEmpty {
                syncEngine.state.add(
                    pendingRecordZoneChanges: actions.additions.map(\.pendingRecordZoneChange))
            }
            try MirrorBootstrapReconciler.verifyExactReprojection(
                serialized: canonicalPendingRecordZoneChanges(),
                plan: candidate.bootstrap.pendingChanges)
            try MirrorBootstrapReconciler.validateDatabaseState(
                serialized: canonicalPendingDatabaseChanges())
        } catch {
            rejectBootstrapCandidate(candidate, gate: gate)
            throw error
        }
        shadowMirrorLock.withLock {
            activeMirrorLease = (candidate.writer, candidate.bootstrap.lease.id)
        }
        bootstrapCandidateState = nil
        note("bootstrap gate open")
        gate.resolve(.open)
    }

    /// Terminal outcome of this engine's bootstrap gate; nil while unresolved or when this is
    /// a nil-state control engine.
    public var bootstrapGateOutcome: MirrorBootstrapDelegateGate.Outcome? {
        bootstrapGate?.resolvedOutcome
    }

    /// Canonical projection of the engine's current pending record-zone changes. Diagnostics
    /// plus the app-target bootstrap tests — the package host cannot read a real engine state.
    public func canonicalPendingChangesSnapshot() -> [MirrorEnginePendingChange] {
        syncEngine.state.pendingRecordZoneChanges.compactMap { MirrorEnginePendingChange($0) }
    }

    private func canonicalPendingRecordZoneChanges() throws -> [MirrorEnginePendingChange] {
        try syncEngine.state.pendingRecordZoneChanges.map { change in
            guard let canonical = MirrorEnginePendingChange(change) else {
                throw MirrorBootstrapReconciliationError.unknownPendingChangeCase
            }
            return canonical
        }
    }

    private func canonicalPendingDatabaseChanges() throws -> [MirrorEngineDatabaseChange] {
        try syncEngine.state.pendingDatabaseChanges.map { change in
            guard let canonical = MirrorEngineDatabaseChange(change) else {
                throw MirrorBootstrapReconciliationError.unknownDatabaseChangeCase
            }
            return canonical
        }
    }

    private func rejectBootstrapCandidate(
        _ candidate: MirrorBootstrapCandidate,
        gate: MirrorBootstrapDelegateGate
    ) {
        note("bootstrap gate rejected")
        gate.resolve(.rejected)
        shadowMirrorLock.withLock {
            shadowCaptureAllowed = false
            shadowMirror = nil
            localGeneration = [:]
            sentGeneration = [:]
            store.removeAll()
            shadowCoverageRevision &+= 1
        }
        zoneEnsuredLock.withLock { zoneEnsured = false }
        bootstrapCandidateState = nil
        Self.failBootstrapCandidate(candidate, store: store)
    }

    private static func failBootstrapCandidate(
        _ candidate: MirrorBootstrapCandidate,
        store: HouseholdLocalStore
    ) {
        store.removeAll()
        candidate.writer.quarantineAndReleaseGenerationLeaseSynchronously(
            candidate.bootstrap.lease.id)
    }

    /// Apply a recovery-only WAL plan after the nil-state engine has completed its authoritative
    /// full fetch. The base remains server-rendered until this one-shot overlay, which installs
    /// the continuing writer/runtime and enqueues normalized changes exactly once.
    public func applyRecoveryPlan(
        _ plan: MirrorRecoveryPlan,
        writer: ShadowMirrorCheckpointWriter
    ) throws {
        guard !recoveryPlanApplied else { throw MirrorBootstrapEngineError.activationUnavailable }
        // Decode and cross-check every durable payload before mutating either the fetched store
        // or CKSyncEngine state. A malformed later row must not publish a partial recovery.
        let overlay = try MirrorRecoveryPlanOverlay.prepare(plan: plan, zoneID: zoneID)
        let runtime = ShadowMirrorRuntime(writer: writer)
        let publication = try shadowMirrorLock.withLock { () throws -> ShadowMirrorPublication? in
            guard !recoveryPlanApplied else { throw MirrorBootstrapEngineError.activationUnavailable }
            for record in overlay.recordsToSave {
                store.setRecord(record)
            }
            for recordID in overlay.recordIDsToDelete {
                store.removeRecord(recordID)
            }
            localGeneration = MirrorBootstrapReconciler.seededLocalGenerations(
                from: plan.maxMutationGenerationByIdentity)
            shadowMirror?.park()
            shadowMirror = runtime
            durableMirrorRequired = true
            shadowCaptureAllowed = true
            shadowMissedLocalMutation = false
            shadowCoverageRevision &+= 1
            let snapshot = (
                records: store.allRecords(),
                coverageRevision: shadowCoverageRevision,
                zoneEnsured: zoneEnsuredValue(),
                participantFetchProof: participantCheckpointProof)
            shadowCompletedFetch = snapshot
            runtime.beginFetchEpoch()
            _ = try runtime.completeFetchEpoch(
                records: snapshot.records,
                coverageRevision: snapshot.coverageRevision,
                zoneEnsured: snapshot.zoneEnsured)
            var recoveryPublication: ShadowMirrorPublication?
            for state in shadowStateHistory {
                if let candidate = try runtime.observeStateUpdate(
                    state.serialization,
                    coverageRevision: state.coverageRevision,
                    zoneEnsured: state.zoneEnsured,
                    participantFetchProof: state.participantFetchProof) {
                    recoveryPublication = candidate
                }
            }
            for change in overlay.pendingChanges {
                let recordID = CKRecord.ID(recordName: change.identity.recordName, zoneID: zoneID)
                switch change.operation {
                case .save:
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                case .delete:
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                }
            }
            activeMirrorLease = (writer, plan.lease.id)
            recoveryPlanApplied = true
            // Publish only after the validated overlay and every pending change have been
            // installed, never from the pre-overlay fetched snapshot.
            return recoveryPublication
        }
        if let publication { publishShadowAsync(runtime: runtime, publication: publication) }
    }

    deinit {
        var activeLease: (writer: ShadowMirrorCheckpointWriter, id: UUID)?
        var candidateLease: (writer: ShadowMirrorCheckpointWriter, id: UUID)?
        let rootToClear = shadowMirrorLock.withLock { () -> URL? in
            shadowMirror?.fence()
            shadowMirror = nil
            // The store is the engine-owned CKAsset reference. A batch already handed to
            // CKSyncEngine is released only when `syncEngine` is disposed below.
            store.removeAll()
            activeLease = activeMirrorLease
            activeMirrorLease = nil
            if let candidate = bootstrapCandidateState {
                candidateLease = (candidate.writer, candidate.bootstrap.lease.id)
                bootstrapCandidateState = nil
            }
            return clearShadowRootOnDeinit
        }
        // Stored properties outlive a deinit body by default. Dispose CKSyncEngine explicitly
        // before dropping the lease or moving its asset root so an outbound batch cannot retain
        // a CKAsset whose source path has already disappeared.
        syncEngine = nil
        if let activeLease {
            activeLease.writer.releaseGenerationLeaseSynchronously(activeLease.id)
        }
        if let candidateLease {
            candidateLease.writer.releaseGenerationLeaseSynchronously(candidateLease.id)
        }
        if let rootToClear {
            try? ShadowMirrorCheckpointWriter.completeRootClearSynchronously(rootToClear)
        }
    }

    /// P1's active engine always starts from a nil token and performs the existing full fetch.
    /// The shadow generation remains write-only until P2 independently validates cache restore.
    static func coldStartStateSerialization() -> CKSyncEngine.State.Serialization? { nil }

    // MARK: P1 shadow mirror

    /// Enables scoped checkpoint capture only after a caller has a complete account identity.
    /// This never changes the active `CKSyncEngine` configuration or hydrates `store`; P1 keeps
    /// the existing nil-token/full-fetch boot path and only records an isolated shadow snapshot.
    public func enableShadowMirror(scope: MirrorScope, rootDirectory: URL) async throws {
        let rootMatches = shadowMirrorLock.withLock {
            guard let configured = shadowRootDirectory else {
                shadowRootDirectory = rootDirectory
                return true
            }
            return configured.standardizedFileURL == rootDirectory.standardizedFileURL
        }
        guard rootMatches else { throw MirrorCheckpointError.scopeMismatch }
        guard shadowMirrorLock.withLock({ shadowCaptureAllowed }) else { return }
        let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: rootDirectory)
        let runtime = ShadowMirrorRuntime(writer: writer)
        let publication = try shadowMirrorLock.withLock { () throws -> ShadowMirrorPublication? in
            guard shadowCaptureAllowed else {
                // A detach may have parked a valid owner generation while this identity lookup
                // was constructing its runtime. Fence only this late writer; never delete the
                // parked scope (or sibling account scopes) from the stale callback.
                runtime.park()
                return nil
            }
            shadowMirror?.park()
            shadowMirror = runtime
            if shadowMissedLocalMutation {
                runtime.invalidate()
            }
            if shadowFetchEpochOpen {
                runtime.beginFetchEpoch()
            } else if let completedFetch = shadowCompletedFetch {
                runtime.beginFetchEpoch()
                _ = try runtime.completeFetchEpoch(
                    records: completedFetch.records,
                    coverageRevision: completedFetch.coverageRevision,
                    zoneEnsured: completedFetch.zoneEnsured)
            }
            var publication: ShadowMirrorPublication?
            for state in shadowStateHistory {
                if let candidate = try runtime.observeStateUpdate(
                    state.serialization,
                    coverageRevision: state.coverageRevision,
                    zoneEnsured: state.zoneEnsured,
                    participantFetchProof: state.participantFetchProof), publication == nil {
                    publication = candidate
                }
            }
            return publication
        }
        if let publication { try await runtime.publish(publication) }
    }

    /// Sign-out/account change clears a fully fenced scope. P1 failures are diagnostic-only:
    /// callers preserve the active engine and full-fetch behavior even if a cache cannot clear.
    @discardableResult
    public func clearShadowMirror() -> Bool {
        shadowMirrorLock.lock(); defer { shadowMirrorLock.unlock() }
        var rootRetirementDurable = true
        shadowCaptureAllowed = false
        if let shadowRootDirectory {
            do {
                try ShadowMirrorCheckpointWriter.requestRootClearSynchronously(shadowRootDirectory)
            } catch {
                rootRetirementDurable = false
                note("shadow root clear marker failed")
                callbackRelay.emit(.durabilityFailure(MirrorDurabilityFailure()))
            }
        }
        // Fence synchronously so no stale pointer can install, but do not wait on a whole-cache
        // asset build from HouseholdSession's main-actor teardown. P1 can move the root now;
        // an active cached/recovery lease defers that move until engine disposal so an outbound
        // CKAsset payload cannot lose its file while CKSyncEngine still retains it.
        if let shadowMirror {
            // Request retirement through the writer so an active asset lease gets both an
            // in-process fence and a durable deferred-clear marker. A same-process rebootstrap
            // then rejects the scope without moving it; a later process clears it before scan.
            do {
                try shadowMirror.requestClear()
            } catch {
                shadowMirror.fence()
            }
        } else if let activeMirrorLease {
            // A parked cached/recovery runtime has already been detached, but its writer still
            // owns the lease and must receive the same deferred-clear request.
            try? activeMirrorLease.writer.fenceAndRequestClearSynchronously()
        }
        shadowMirror = nil
        discardActiveMirrorReferencesLocked()
        if activeMirrorLease != nil {
            clearShadowRootOnDeinit = shadowRootDirectory
        }
        shadowStateHistory = []
        shadowCompletedFetch = nil
        shadowFetchEpochOpen = false
        participantFetchProof = .unverified
        participantCheckpointProof = nil
        if activeMirrorLease == nil, let shadowRootDirectory {
            do {
                try ShadowMirrorCheckpointWriter.completeRootClearSynchronously(shadowRootDirectory)
            } catch {
                rootRetirementDurable = false
            }
        }
        return rootRetirementDurable
    }

    /// Revocation retires only this participant scope, not sibling owner/participant scopes under
    /// the same account root. Its lease keeps assets stable until engine disposal completes move.
    private func retireActiveShadowScope() -> Bool {
        shadowMirrorLock.withLock {
            shadowCaptureAllowed = false
            do {
                if let shadowMirror {
                    try shadowMirror.requestClear()
                } else if let activeMirrorLease {
                    try activeMirrorLease.writer.fenceAndRequestClearSynchronously()
                }
            } catch {
                return false
            }
            shadowMirror = nil
            discardActiveMirrorReferencesLocked()
            shadowStateHistory = []
            shadowCompletedFetch = nil
            shadowFetchEpochOpen = false
            participantFetchProof = .unverified
            participantCheckpointProof = nil
            return true
        }
    }

    /// Owner-to-participant adoption parks the old scope after fencing it, so a stale owner
    /// callback cannot publish into the new participant session while the prior checkpoint stays
    /// available only to a later scope-validated owner session.
    public func parkShadowMirror() {
        shadowMirrorLock.lock(); defer { shadowMirrorLock.unlock() }
        shadowCaptureAllowed = false
        shadowMirror?.park()
        shadowMirror = nil
        discardActiveMirrorReferencesLocked()
        shadowStateHistory = []
        shadowCompletedFetch = nil
        shadowFetchEpochOpen = false
        participantFetchProof = .unverified
        participantCheckpointProof = nil
    }

    /// Remove local payload references and future pending work at detach. A batch already handed
    /// to CKSyncEngine may outlive this call, so the generation lease remains pinned until engine
    /// disposal; only then may post-teardown cleanup reclaim the root.
    private func discardActiveMirrorReferencesLocked() {
        store.removeAll()
        let pending = syncEngine.state.pendingRecordZoneChanges
        if !pending.isEmpty {
            syncEngine.state.remove(pendingRecordZoneChanges: pending)
        }
        let databaseChanges = syncEngine.state.pendingDatabaseChanges
        if !databaseChanges.isEmpty {
            syncEngine.state.remove(pendingDatabaseChanges: databaseChanges)
        }
    }

    private func releaseActiveMirrorLeaseLocked() {
        guard let lease = activeMirrorLease else { return }
        activeMirrorLease = nil
        lease.writer.releaseGenerationLeaseSynchronously(lease.id)
    }

    private func mutateStoreUnderShadowGate(
        _ mutation: () -> Void
    ) {
        shadowMirrorLock.lock(); defer { shadowMirrorLock.unlock() }
        mutation()
        shadowCoverageRevision &+= 1
    }

    private func observeShadowState(_ serialization: CKSyncEngine.State.Serialization) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        var captured: (ShadowMirrorRuntime, ShadowMirrorPublication)?
        shadowMirrorLock.withLock {
            let coverageRevision = shadowCoverageRevision
            let ensured = zoneEnsuredValue()
            let participantProof = participantCheckpointProof
            shadowStateHistory.append((data, coverageRevision, ensured, participantProof))
            if shadowStateHistory.count > 256 {
                shadowStateHistory.removeFirst(shadowStateHistory.count - 256)
            }
            guard let runtime = shadowMirror else { return }
            do {
                if let publication = try runtime.observeStateUpdate(
                    data,
                    coverageRevision: coverageRevision,
                    zoneEnsured: ensured,
                    participantFetchProof: participantProof
                ) {
                    captured = (runtime, publication)
                }
            } catch {
                runtime.invalidate()
            }
        }
        if let (runtime, publication) = captured {
            publishShadowAsync(runtime: runtime, publication: publication)
        }
    }

    private func beginShadowFetchEpoch() {
        shadowMirrorLock.withLock {
            shadowFetchEpochOpen = true
            shadowCompletedFetch = nil
            participantFetchProof = .unverified
            participantCheckpointProof = nil
            shadowMirror?.beginFetchEpoch()
        }
    }

    private func completeShadowFetchEpoch() {
        var captured: (ShadowMirrorRuntime, ShadowMirrorPublication)?
        shadowMirrorLock.withLock {
            guard shadowFetchEpochOpen else { return }
            shadowFetchEpochOpen = false
            let snapshot = (
                records: store.allRecords(),
                coverageRevision: shadowCoverageRevision,
                zoneEnsured: MirrorZoneEnsuredPolicy.value(
                    role: ownsZone ? .owner : .participant,
                    recoveredZoneEnsured: zoneEnsuredValue(),
                    checkpointProof: participantCheckpointProof,
                    fetch: ownsZone ? .verified : participantFetchProof),
                participantFetchProof: participantCheckpointProof)
            shadowCompletedFetch = snapshot
            // A state update may arrive before `didFetchRecordZoneChanges`; bind the typed
            // proof to the latest covered serialization before the checkpoint runtime sees it.
            if let proof = snapshot.participantFetchProof,
               let index = shadowStateHistory.indices.last(where: {
                   shadowStateHistory[$0].coverageRevision <= snapshot.coverageRevision
               }) {
                let state = shadowStateHistory[index]
                shadowStateHistory[index] = (
                    state.serialization,
                    state.coverageRevision,
                    state.zoneEnsured,
                    proof)
            }
            guard let runtime = shadowMirror else { return }
            do {
                if let proof = snapshot.participantFetchProof {
                    try runtime.bindParticipantFetchProof(
                        proof,
                        coverageRevision: snapshot.coverageRevision)
                }
                if let publication = try runtime.completeFetchEpoch(
                    records: snapshot.records,
                    coverageRevision: snapshot.coverageRevision,
                    zoneEnsured: snapshot.zoneEnsured
                ) {
                    captured = (runtime, publication)
                }
            } catch {
                runtime.invalidate()
            }
        }
        if let (runtime, publication) = captured {
            publishShadowAsync(runtime: runtime, publication: publication)
        }
    }

    /// Checkpoint generation can copy every record and asset. Keep that work off both the
    /// mirror gate and CKSyncEngine's serial delegate callback so diagnostic P1 capture cannot
    /// extend initial-fetch launch readiness. Runtime/writer fences still quiesce this task.
    private func publishShadowAsync(
        runtime: ShadowMirrorRuntime,
        publication: ShadowMirrorPublication
    ) {
        Task.detached {
            try? await runtime.publish(publication)
        }
    }

    private func zoneEnsuredValue() -> Bool {
        zoneEnsuredLock.lock(); defer { zoneEnsuredLock.unlock() }
        return zoneEnsured
    }

    // MARK: Public mutation API

    /// Must be called under `shadowMirrorLock`. Every path that creates a new local save intent
    /// uses this same seam, including a fetched-conflict merge. P1 treats a failed diagnostic
    /// append as non-blocking; cached/recovery sessions require the append before any generation,
    /// store, or engine-state mutation.
    private func appendSaveToMirrorBeforeMutationLocked(
        _ record: CKRecord,
        mutationGeneration: UInt64
    ) -> Bool {
        if let shadowMirror {
            let appended = shadowMirror.appendSaveBeforeMutation(
                record,
                mutationGeneration: mutationGeneration)
            return appended || !durableMirrorRequired
        }
        if durableMirrorRequired { return false }
        shadowMissedLocalMutation = true
        return true
    }

    /// Stage a record save: write it locally, then tell the engine it's pending. The
    /// zone is created lazily on the first save. Cache-first/recovery sessions return `false`
    /// before mutating when their durable WAL cannot accept the intent; P1 preserves its
    /// historical diagnostic-only behavior and returns `true` after the normal mutation.
    @discardableResult
    public func save(_ record: CKRecord) -> Bool {
        var durabilityFailure: MirrorDurabilityFailure?
        let accepted = shadowMirrorLock.withLock { () -> Bool in
            let nextGeneration = UInt64(localGeneration[record.recordID, default: 0] + 1)
            guard appendSaveToMirrorBeforeMutationLocked(
                record,
                mutationGeneration: nextGeneration) else {
                durabilityFailure = MirrorDurabilityFailure()
                return false
            }
            _ = bumpGenerationLocked(record.recordID)
            store.setRecord(record)
            // simmersmith-c7r: `save()` can be called concurrently from multiple threads, so
            // the check-and-set remains atomic. The mirror gate also keeps the store payload,
            // its generation stamp, and CKSyncEngine pending ID in one logical mutation.
            zoneEnsuredLock.lock()
            let shouldEnsureZone = ownsZone && !zoneEnsured
            if ownsZone { zoneEnsured = true }
            zoneEnsuredLock.unlock()
            if shouldEnsureZone {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            shadowCoverageRevision &+= 1
            return true
        }
        if let durabilityFailure {
            note("cached save denied: WAL append failed")
            callbackRelay.emit(.durabilityFailure(durabilityFailure))
        }
        return accepted
    }

    public func delete(_ recordID: CKRecord.ID) {
        guard HouseholdDataPlanePolicy.allows(.delete, mode: dataPlaneMode) else {
            note("destructive delete denied before authority")
            return
        }
        var durabilityFailure: MirrorDurabilityFailure?
        shadowMirrorLock.withLock {
            let nextGeneration = UInt64(localGeneration[recordID, default: 0] + 1)
            if let record = store.record(for: recordID) {
                if let shadowMirror {
                    let appended = shadowMirror.appendDeleteBeforeMutation(
                        MirrorRecordIdentity(record),
                        mutationGeneration: nextGeneration)
                    if !appended, durableMirrorRequired {
                        durabilityFailure = MirrorDurabilityFailure()
                        return
                    }
                } else if durableMirrorRequired {
                    durabilityFailure = MirrorDurabilityFailure()
                    return
                } else {
                    shadowMissedLocalMutation = true
                }
            } else if durableMirrorRequired {
                durabilityFailure = MirrorDurabilityFailure()
                return
            } else if let shadowMirror {
                // A record ID does not carry its record type, so inventing a tombstone here
                // would fail to supersede a later save of the real identity. Disable this
                // diagnostic cache instead; the active delete and full-fetch path continue.
                shadowMirror.invalidate()
            } else {
                shadowMissedLocalMutation = true
            }
            _ = bumpGenerationLocked(recordID)
            store.removeRecord(recordID)
            syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            shadowCoverageRevision &+= 1
        }
        if let durabilityFailure {
            note("cached delete denied: WAL append failed")
            callbackRelay.emit(.durabilityFailure(durabilityFailure))
        }
    }

    /// Delete a record AND sweep its local CASCADE subtree. CloudKit's `.deleteSelf` only
    /// fires on the deleting device, so the client must enqueue child deletes itself; this
    /// recurses the local store's `.deleteSelf` edges (recipe→ingredient/step→child-step,
    /// event→meal→ingredient, baseIngredient→variation). The sweep lives ONLY here on the
    /// issuing engine — the fetch handler stays the untouched LWW seam.
    public func deleteCascading(_ recordID: CKRecord.ID) {
        guard HouseholdDataPlanePolicy.allows(.deleteCascading, mode: dataPlaneMode) else {
            note("destructive cascade denied before authority")
            return
        }
        deleteCascading(recordID, visited: [])
    }

    private func deleteCascading(_ recordID: CKRecord.ID, visited: Set<String>) {
        guard !visited.contains(recordID.recordName) else { return }
        var visited = visited
        visited.insert(recordID.recordName)
        for childID in store.recordIDsCascadingFrom(recordID.recordName) {
            deleteCascading(childID, visited: visited)
        }
        delete(recordID)
    }

    // simmersmith-vda: every EXPLICIT engine operation below runs under one AsyncSerialGate.
    // Build 149 crashed at first open when a repair pass's send overlapped the still-suspended
    // boot fetch on this same engine (CKSyncEngine-internal Swift assertion). Serializing at
    // the entry points kills the class: no per-call-site ordering rules, no activation-timing
    // races — a caller that fires "too early" just queues. `CKSyncEngine`'s own
    // `automaticallySync` machinery is internal to the framework and stays ungated (it
    // coexisted with explicit ops for weeks on builds ≤147 without this assertion). The gate
    // is non-reentrant: gated bodies must use raw `syncEngine` calls, never each other.
    private let operationGate = AsyncSerialGate()

    /// Fetch remote changes then push local ones, as ONE gated unit. Manual drive for
    /// deterministic tests; the app can also rely on `automaticallySync`.
    public func sync() async throws {
        try await operationGate.withLock {
            try await self.syncEngine.fetchChanges()
            try await self.syncEngine.sendChanges()
        }
    }

    public func fetchChanges() async throws {
        try await operationGate.withLock { try await self.syncEngine.fetchChanges() }
    }

    public func sendChanges() async throws {
        try await operationGate.withLock { try await self.syncEngine.sendChanges() }
    }

    /// Exact number of record changes still queued (e.g. rebased saves awaiting retry).
    /// App authority displays/counts this value rather than collapsing it to a Boolean.
    public var pendingRecordChangeCount: Int {
        syncEngine.state.pendingRecordZoneChanges.count
    }

    /// True while record changes are still queued (e.g. a rebased save awaiting retry).
    public var hasPendingRecordChanges: Bool {
        pendingRecordChangeCount > 0
    }

    /// Send repeatedly until nothing is pending. A per-record conflict (serverRecordChanged)
    /// can both be delivered to the delegate (which re-enqueues a merged save) AND thrown from
    /// `sendChanges()`; catch it and keep draining while the delegate left pending work, so the
    /// merged retry goes out. Rethrow only if nothing is pending (a real, unhandled failure).
    /// The whole drain holds the operation gate — passes never interleave with another
    /// explicit fetch/send (simmersmith-vda).
    public func sendUntilDrained(maxPasses: Int = 8) async throws {
        try await operationGate.withLock {
            for _ in 0..<maxPasses {
                do {
                    try await self.syncEngine.sendChanges()
                    if !self.hasPendingRecordChanges { return }
                } catch {
                    if !self.hasPendingRecordChanges { throw error }
                }
            }
        }
    }

    // MARK: CKSyncEngineDelegate

    /// An automatic engine may call back the instant it exists (spec §3.3 step 3): every
    /// delegate entry point waits behind the closed bootstrap gate. A rejected candidate's
    /// queued work releases into no-op/discard behavior; the nil-gate control path is the
    /// exact P1 code.
    private func awaitBootstrapGate(_ entry: String) async -> Bool {
        guard let bootstrapGate else { return true }
        if bootstrapGate.resolvedOutcome == nil {
            note("bootstrap gate queued \(entry)")
        }
        guard await bootstrapGate.awaitOutcome() == .open else {
            note("bootstrap gate discarded \(entry)")
            return false
        }
        return true
    }

    /// Implemented (rather than inherited as a default) so a candidate engine's imminent fetch
    /// also waits behind the gate. The returned value is the context's own options — the same
    /// defaults the SDK uses when this method is not implemented — so the nil-gate control
    /// path is behaviorally unchanged.
    public func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        _ = await awaitBootstrapGate("fetch-options")
        return context.options
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard await awaitBootstrapGate("batch") else { return nil }
        let generationSnapshot = OutboundBatchGenerationSnapshot()
        let pending = shadowMirrorLock.withLock { () -> [CKSyncEngine.PendingRecordZoneChange] in
            let selected = syncEngine.state.pendingRecordZoneChanges.filter {
                context.options.scope.contains($0)
            }
            // Deletes have no record-provider callback. Capture their exact generation together
            // with the pending-state snapshot so a concurrent save cannot relabel an old delete.
            for change in selected {
                if case .deleteRecord(let recordID) = change {
                    generationSnapshot.capture(
                        localGeneration[recordID, default: 0],
                        for: recordID)
                }
            }
            return selected
        }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            self.shadowMirrorLock.withLock {
                guard let record = self.store.record(for: recordID) else { return nil }
                // Capture the payload and its generation under the same lock. If a later save
                // lands before this batch is returned, its higher generation remains pending and
                // the old acknowledgement takes the stale-rebase path instead of consuming it.
                generationSnapshot.capture(
                    self.localGeneration[recordID, default: 0],
                    for: recordID)
                return record
            }
        }
        guard let batch else { return nil }
        // The initializer may cap a large pending set. Transition only the exact save/delete
        // payloads it selected, and transition every one before returning anything to CloudKit.
        // A partial WAL failure returns no batch; cached/recovery remains intervention-blocked
        // rather than sending an intent whose durable delivery state is still pending.
        let selectedRecordIDs = batch.recordsToSave.map(\.recordID) + batch.recordIDsToDelete
        for recordID in selectedRecordIDs {
            let generation = generationSnapshot.generation(for: recordID)
            let accepted = shadowMirrorLock.withLock {
                prepareSentGenerationLocked(recordID, generation: generation)
            }
            guard accepted else {
                note("cached send denied: WAL sent transition failed")
                callbackRelay.emit(.durabilityFailure(MirrorDurabilityFailure()))
                return nil
            }
        }
        return batch
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard await awaitBootstrapGate("event") else { return }
        switch event {
        case .stateUpdate(let update):
            Self.saveState(update.stateSerialization, to: stateURL)
            observeShadowState(update.stateSerialization)

        case .fetchedRecordZoneChanges(let changes):
            for modification in changes.modifications {
                let remote = modification.record
                // The zone-wide CKShare record lives in the shared zone and loops back
                // through fetched changes on the owner engine — never ingest it as data.
                if Self.isShareRecord(remote) { continue }
                var durabilityFailure: MirrorDurabilityFailure?
                shadowMirrorLock.withLock {
                    // Recheck pending state and read/mutate the store under the same gate as
                    // save(). A local save arriving before this lock is therefore merged/skipped;
                    // one arriving afterward sees the fetched record and cannot be overwritten.
                    let hasPendingEdit = hasPendingSaveLocked(remote.recordID)
                    if hasPendingEdit, let merger, merger.handles(remote.recordType),
                       let local = store.record(for: remote.recordID) {
                        let result = merger.resolve(local: local, remote: remote)
                        let nextGeneration = UInt64(
                            localGeneration[result.record.recordID, default: 0] + 1)
                        guard appendSaveToMirrorBeforeMutationLocked(
                            result.record,
                            mutationGeneration: nextGeneration) else {
                            durabilityFailure = MirrorDurabilityFailure()
                            return
                        }
                        _ = bumpGenerationLocked(result.record.recordID)
                        store.setRecord(result.record)
                        if result.needsResave {
                            syncEngine.state.add(
                                pendingRecordZoneChanges: [.saveRecord(result.record.recordID)])
                        }
                        shadowCoverageRevision &+= 1
                        note("merged fetched \(remote.recordID.recordName) resave=\(result.needsResave)")
                        return
                    }
                    // A pending edit on a non-merge record must reach the server first (don't let
                    // the fetch clobber it; the conflict surfaces as serverRecordChanged on send).
                    guard !hasPendingEdit else {
                        note("skip fetched mod (local pending) \(remote.recordID.recordName)")
                        return
                    }
                    store.applyRemoteModification(remote)
                    shadowCoverageRevision &+= 1
                    note("fetched mod \(remote.recordID.recordName)")
                }
                if let durabilityFailure {
                    note("cached fetched merge denied: WAL append failed")
                    callbackRelay.emit(.durabilityFailure(durabilityFailure))
                }
            }
            for deletion in changes.deletions {
                var durabilityFailure: MirrorDurabilityFailure?
                var supersededCachedSave = false
                shadowMirrorLock.withLock {
                    let pendingSave = hasPendingSaveLocked(deletion.recordID)
                    if durableMirrorRequired, hasPendingRecordChangeLocked(deletion.recordID) {
                        let transitioned = shadowMirror?.resolveRemoteDelete(
                            recordID: deletion.recordID) == true
                        guard transitioned else {
                            durabilityFailure = MirrorDurabilityFailure()
                            return
                        }
                        syncEngine.state.remove(pendingRecordZoneChanges: [
                            .saveRecord(deletion.recordID),
                            .deleteRecord(deletion.recordID),
                        ])
                        sentGeneration.removeValue(forKey: deletion.recordID)
                        supersededCachedSave = pendingSave
                    }
                    // P1 remains exact: fetched deletion removes the store record even if its
                    // diagnostic engine still has a pending save. Cached/recovery first writes
                    // the terminal WAL transition above so restart cannot resurrect it.
                    store.removeRecord(deletion.recordID)
                    shadowCoverageRevision &+= 1
                    note("fetched del \(deletion.recordID.recordName)")
                }
                if let durabilityFailure {
                    note("cached fetched delete denied: WAL transition failed")
                    callbackRelay.emit(.durabilityFailure(durabilityFailure))
                } else if supersededCachedSave {
                    callbackRelay.emit(.syncError(SyncFailure(
                        recordName: deletion.recordID.recordName,
                        code: .unknownItem,
                        kind: .permanent,
                        message: "A cached change was removed on another device and needs attention.")))
                }
            }
            callbackRelay.emit(.storeChanged)

        case .sentRecordZoneChanges(let sent):
            // Adopt the server-authoritative record for each ack — guarding the seam
            // (simmersmith-dkj): a `save()` for the SAME record landing while this send was in
            // flight leaves the store holding a newer local edit than what's being acked here.
            // A blind replace would silently erase that edit, and the resave `save()` already
            // enqueued for it would then just resend the now-stale acked payload (the next batch
            // pulls whatever the store currently holds). `rebaseAckedRecord` keeps the store's
            // newer fields and only lifts the ack's system fields/change tag onto them.
            for saved in sent.savedRecords {
                if Self.isShareRecord(saved) { continue }
                // Stale-ack guard: only rebase when the store's record actually changed AFTER
                // this payload went out. The common case (no interleaved edit) still takes the
                // server record verbatim, exactly as before.
                var staleAck = false
                var durabilityFailure: MirrorDurabilityFailure?
                shadowMirrorLock.withLock {
                    let sent = consumeSentGenerationLocked(saved.recordID)
                    staleAck = sent.isStale
                    var toStore: CKRecord?
                    var shadowRebase: CKRecord?
                    if staleAck, let current = store.record(for: saved.recordID) {
                        let rebased = Self.rebaseAckedRecord(acked: saved, current: current)
                        toStore = rebased
                        shadowRebase = rebased
                    } else if staleAck {
                        // A newer local delete removed the record while this save was in flight.
                        // Resolve only the old sent save; never resurrect it from the ack.
                        toStore = nil
                    } else {
                        toStore = saved
                    }
                    let transitionAccepted: Bool
                    if let mutationGeneration = sent.generation {
                        if let shadowMirror {
                            transitionAccepted = shadowMirror.acknowledge(
                                recordID: saved.recordID,
                                mutationGeneration: mutationGeneration,
                                rebasedRecord: shadowRebase) || !durableMirrorRequired
                        } else {
                            transitionAccepted = !durableMirrorRequired
                        }
                    } else {
                        shadowMirror?.invalidate()
                        transitionAccepted = !durableMirrorRequired
                    }
                    guard transitionAccepted else {
                        durabilityFailure = MirrorDurabilityFailure()
                        return
                    }
                    if let toStore { store.setRecord(toStore) }
                    shadowCoverageRevision &+= 1
                }
                if let durabilityFailure {
                    callbackRelay.emit(.durabilityFailure(durabilityFailure))
                    continue
                }
                if staleAck { note("stale ack rebased \(saved.recordID.recordName)") }
                note("saved \(saved.recordID.recordName)=\(saved["value"] as? String ?? "?")")
                callbackRelay.emit(.recordSaved(saved.recordID.recordName))
            }
            // simmersmith-ioj (lead amendment): a DELETE of the failed record resolves its
            // failure exactly as well as a re-save does — the user removed the data rather than
            // fixing it. Without this, deleting the offending record is a one-way trip: no later
            // save of that recordName ever fires, so the permanent-failure banner (which a clean
            // tick deliberately no longer clears) would persist for the rest of the session.
            for deletedID in sent.deletedRecordIDs {
                var durabilityFailure: MirrorDurabilityFailure?
                shadowMirrorLock.withLock {
                    let sent = consumeSentGenerationLocked(deletedID)
                    let transitionAccepted: Bool
                    if let mutationGeneration = sent.generation {
                        if let shadowMirror {
                            transitionAccepted = shadowMirror.acknowledge(
                                recordID: deletedID,
                                mutationGeneration: mutationGeneration) || !durableMirrorRequired
                        } else {
                            transitionAccepted = !durableMirrorRequired
                        }
                    } else {
                        shadowMirror?.invalidate()
                        transitionAccepted = !durableMirrorRequired
                    }
                    guard transitionAccepted else {
                        durabilityFailure = MirrorDurabilityFailure()
                        return
                    }
                    shadowCoverageRevision &+= 1
                }
                if let durabilityFailure {
                    callbackRelay.emit(.durabilityFailure(durabilityFailure))
                    continue
                }
                note("deleted \(deletedID.recordName)")
                callbackRelay.emit(.recordSaved(deletedID.recordName))
            }
            for failure in sent.failedRecordSaves {
                note("FAILED \(failure.record.recordID.recordName) code=\(failure.error.code.rawValue)")
                handleFailedSave(failure)
            }
            for (recordID, error) in sent.failedRecordDeletes {
                note("FAILED delete \(recordID.recordName) code=\(error.code.rawValue)")
                handleFailedDelete(recordID: recordID, error: error)
            }
            callbackRelay.emit(.storeChanged)

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedDatabaseChanges(let changes):
            // A PARTICIPANT whose shared zone is deleted/revoked (owner removed them or
            // deleted the share) must purge its local mirror. OWNER-SAFE: gated on
            // !ownsZone so an owner's own zone-deletion (e.g. factory reset) never wipes
            // the owner mirror through this path — owners keep today's no-op behavior.
            if !ownsZone, changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                if retireActiveShadowScope() {
                    mutateStoreUnderShadowGate {
                        store.removeAll()
                    }
                    callbackRelay.emit(.storeChanged)
                    callbackRelay.emit(.participantRevoked)
                    note("participant shared zone revoked \(zoneID.zoneName)")
                } else {
                    callbackRelay.emit(.durabilityFailure(MirrorDurabilityFailure()))
                    note("participant revocation retirement failed closed")
                }
            }

        case .willFetchChanges:
            beginShadowFetchEpoch()

        case .didFetchChanges:
            completeShadowFetchEpoch()

        // Lifecycle / no-op for Phase 2a.
        case .willSendChanges, .didSendChanges,
             .sentDatabaseChanges,
             .willFetchRecordZoneChanges:
            break

        case .didFetchRecordZoneChanges(let changes):
            guard !ownsZone else { break }
            let observed = MirrorParticipantFetchObservation.proof(
                role: .participant,
                expectedZoneID: zoneID,
                fetchedZoneID: changes.zoneID,
                error: changes.error)
            shadowMirrorLock.withLock {
                if observed == .verified || observed == .failed {
                    participantFetchProof = observed
                }
                if observed == .verified {
                    participantCheckpointProof = MirrorParticipantFetchCheckpointProof(fetch: .verified)
                }
            }

        @unknown default:
            break
        }
    }

    /// A CKShare record (the zone-wide share itself) surfaces through the owner engine's
    /// fetched changes — it must NEVER be ingested as household data.
    static func isShareRecord(_ record: CKRecord) -> Bool {
        record.recordType == "cloudkit.share" || record.recordID.recordName == CKRecordNameZoneWideShare
    }

    /// Call only while holding `shadowMirrorLock`; save/delete update pending state under it.
    private func hasPendingSaveLocked(_ recordID: CKRecord.ID) -> Bool {
        syncEngine.state.pendingRecordZoneChanges.contains { change in
            if case .saveRecord(let id) = change { return id == recordID }
            return false
        }
    }

    private func hasPendingRecordChangeLocked(_ recordID: CKRecord.ID) -> Bool {
        syncEngine.state.pendingRecordZoneChanges.contains { change in
            switch change {
            case .saveRecord(let id), .deleteRecord(let id):
                return id == recordID
            @unknown default:
                return false
            }
        }
    }

    // MARK: Conflict + failure handling

    private enum ShadowDeliveryResolution {
        case retry(CKRecord?)
        case blocked
        case consumed(CKRecord?)
    }

    enum FailedDeleteDisposition: Equatable {
        case consumed
        case retry
        case blocked
    }

    /// Must be called under `shadowMirrorLock`. A failed wire attempt that raced a newer local
    /// mutation resolves the old sent intent and preserves/rebases the newer one; it must never
    /// turn the old intent back into a second pending mutation.
    private func resolveShadowDeliveryLocked(
        recordID: CKRecord.ID,
        mutationGeneration: UInt64?,
        isStale: Bool,
        resolution: ShadowDeliveryResolution
    ) -> Bool {
        guard let mutationGeneration else {
            shadowMirror?.invalidate()
            return !durableMirrorRequired
        }
        guard let shadowMirror else { return !durableMirrorRequired }
        let transitioned: Bool
        switch resolution {
        case .retry(let replacement):
            if isStale {
                transitioned = shadowMirror.acknowledge(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    rebasedRecord: replacement)
            } else {
                transitioned = shadowMirror.markDeliveryFailure(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    permanent: false,
                    rebasedRecord: replacement)
            }
        case .blocked:
            if isStale {
                transitioned = shadowMirror.acknowledge(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    rebasedRecord: store.record(for: recordID))
            } else {
                transitioned = shadowMirror.markDeliveryFailure(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    permanent: true)
            }
        case .consumed(let replacement):
            transitioned = shadowMirror.acknowledge(
                recordID: recordID,
                mutationGeneration: mutationGeneration,
                rebasedRecord: isStale ? replacement : nil)
        }
        return transitioned || !durableMirrorRequired
    }

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        let recordID = failure.record.recordID
        var surfacedFailure: SyncFailure?
        var durabilityFailure: MirrorDurabilityFailure?
        func resolveDurably(
            generation: UInt64?,
            isStale: Bool,
            resolution: ShadowDeliveryResolution
        ) -> Bool {
            let resolved = resolveShadowDeliveryLocked(
                recordID: recordID,
                mutationGeneration: generation,
                isStale: isStale,
                resolution: resolution)
            if !resolved { durabilityFailure = MirrorDurabilityFailure() }
            return resolved
        }

        shadowMirrorLock.withLock {
            let sent = consumeSentGenerationLocked(recordID)
            let current = store.record(for: recordID)
            switch failure.error.code {
            case .serverRecordChanged:
                // The newer local operation wins the race against this older wire payload. A
                // newer delete stays deleted; a newer save is rebased onto server system fields.
                guard let serverRecord = failure.error.serverRecord else {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: sent.isStale,
                        resolution: .blocked) else { return }
                    shadowCoverageRevision &+= 1
                    return
                }
                if sent.isStale, current == nil {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: true,
                        resolution: .consumed(nil)) else { return }
                } else if let merger, merger.handles(serverRecord.recordType) {
                    let result = merger.resolve(
                        local: sent.isStale ? (current ?? failure.record) : failure.record,
                        remote: serverRecord)
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: sent.isStale,
                        resolution: .retry(result.record)) else { return }
                    store.setRecord(result.record)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else if let current {
                    if sent.isStale {
                        let rebased = Self.rebaseAckedRecord(acked: serverRecord, current: current)
                        guard resolveDurably(
                            generation: sent.generation,
                            isStale: true,
                            resolution: .retry(rebased)) else { return }
                        store.setRecord(rebased)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    } else {
                        let decision = Self.rebaseNonMergerRecord(local: current, server: serverRecord)
                        guard resolveDurably(
                            generation: sent.generation,
                            isStale: false,
                            resolution: decision.reEnqueue
                                ? .retry(decision.record) : .consumed(nil)) else { return }
                        store.setRecord(decision.record)
                        if decision.reEnqueue {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        }
                    }
                } else {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: false,
                        resolution: .consumed(nil)) else { return }
                    store.setRecord(serverRecord)
                }

            case .zoneNotFound, .userDeletedZone:
                // Re-create the zone and re-enqueue the save — OWNER ONLY. A participant cannot
                // create the owner's zone; for it this means the share is gone.
                if ownsZone,
                   HouseholdDataPlanePolicy.allows(.zoneRecreation, mode: dataPlaneMode),
                   !(sent.isStale && current == nil) {
                    let retryRecord = sent.isStale ? current : failure.record
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: sent.isStale,
                        resolution: .retry(retryRecord)) else { return }
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: sent.isStale,
                        resolution: sent.isStale ? .consumed(current) : .blocked) else { return }
                    if ownsZone, dataPlaneMode == .cached {
                        surfacedFailure = SyncFailure(
                            recordName: recordID.recordName,
                            code: failure.error.code,
                            kind: .permanent,
                            message: Self.userMessage(for: failure.error.code))
                    }
                }

            case .unknownItem:
                if sent.isStale, let current {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: true,
                        resolution: .retry(current)) else { return }
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else if sent.isStale {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: true,
                        resolution: .consumed(nil)) else { return }
                } else {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: false,
                        resolution: .blocked) else { return }
                    store.removeRecord(recordID)
                }

            default:
                // simmersmith-dab: retry known-transient failures; surface every other code.
                let code = failure.error.code
                log.error("household save failed for \(recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
                switch Self.classifyFailure(code) {
                case .transient:
                    if sent.isStale, current == nil {
                        guard resolveDurably(
                            generation: sent.generation,
                            isStale: true,
                            resolution: .consumed(nil)) else { return }
                    } else {
                        let retryRecord = sent.isStale ? current : failure.record
                        guard resolveDurably(
                            generation: sent.generation,
                            isStale: sent.isStale,
                            resolution: .retry(retryRecord)) else { return }
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                case .permanent:
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: sent.isStale,
                        resolution: sent.isStale ? .consumed(current) : .blocked) else { return }
                    surfacedFailure = SyncFailure(
                        recordName: recordID.recordName,
                        code: code,
                        kind: .permanent,
                        message: Self.userMessage(for: code))
                }
            }
            shadowCoverageRevision &+= 1
        }
        if let durabilityFailure {
            callbackRelay.emit(.durabilityFailure(durabilityFailure))
            return
        }
        if let surfacedFailure { callbackRelay.emit(.syncError(surfacedFailure)) }
    }

    private func handleFailedDelete(recordID: CKRecord.ID, error: CKError) {
        var surfacedFailure: SyncFailure?
        var durabilityFailure: MirrorDurabilityFailure?
        var resolvedRecordName: String?
        func resolveDurably(
            generation: UInt64?,
            isStale: Bool,
            resolution: ShadowDeliveryResolution
        ) -> Bool {
            let resolved = resolveShadowDeliveryLocked(
                recordID: recordID,
                mutationGeneration: generation,
                isStale: isStale,
                resolution: resolution)
            if !resolved { durabilityFailure = MirrorDurabilityFailure() }
            return resolved
        }

        shadowMirrorLock.withLock {
            let sent = consumeSentGenerationLocked(recordID)
            switch Self.classifyFailedDelete(error.code) {
            case .consumed:
                // The record (or its entire zone) is already absent, so the requested end state
                // has been reached even though CloudKit reported the delete as a failure.
                guard resolveDurably(
                    generation: sent.generation,
                    isStale: sent.isStale,
                    resolution: .consumed(nil)) else { return }
                resolvedRecordName = recordID.recordName

            case .retry:
                if sent.isStale {
                    // A newer save/delete owns the current pending slot. Consume only this old
                    // wire attempt; its exact durable successor remains in the outbox.
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: true,
                        resolution: .consumed(nil)) else { return }
                } else {
                    guard resolveDurably(
                        generation: sent.generation,
                        isStale: false,
                        resolution: .retry(nil)) else { return }
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                }

            case .blocked:
                guard resolveDurably(
                    generation: sent.generation,
                    isStale: sent.isStale,
                    resolution: sent.isStale ? .consumed(nil) : .blocked) else { return }
                surfacedFailure = SyncFailure(
                    recordName: recordID.recordName,
                    code: error.code,
                    kind: .permanent,
                    message: Self.userMessage(for: error.code))
            }
            shadowCoverageRevision &+= 1
        }
        if let durabilityFailure {
            callbackRelay.emit(.durabilityFailure(durabilityFailure))
            return
        }
        if let surfacedFailure { callbackRelay.emit(.syncError(surfacedFailure)) }
        if let resolvedRecordName { callbackRelay.emit(.recordSaved(resolvedRecordName)) }
    }

    static func classifyFailedDelete(_ code: CKError.Code) -> FailedDeleteDisposition {
        switch code {
        case .unknownItem, .zoneNotFound, .userDeletedZone:
            return .consumed
        default:
            return classifyFailure(code) == .transient ? .retry : .blocked
        }
    }

    /// PURE classifier (simmersmith-dab) for the `default:` seam above — no side effects, no
    /// engine state. Anything not explicitly known-transient is treated as permanent, so an
    /// unrecognized future `CKError.Code` surfaces to the user instead of silently re-enqueuing
    /// forever.
    static func classifyFailure(_ code: CKError.Code) -> SyncFailure.Kind {
        switch code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost:
            return .transient
        default:
            return .permanent
        }
    }

    /// A short, user-facing explanation naming the cause. Falls back to a generic message for
    /// codes without a specific one (still permanent — the caller decides retry policy).
    static func userMessage(for code: CKError.Code) -> String {
        switch code {
        case .quotaExceeded:
            return "iCloud storage is full — free up space to sync your changes."
        case .notAuthenticated:
            return "You're signed out of iCloud — sign in to sync your changes."
        case .permissionFailure:
            return "SimmerSmith doesn't have permission to use iCloud for this account."
        case .limitExceeded:
            return "This change is too large for iCloud to sync in one request."
        case .serverRejectedRequest:
            return "iCloud rejected this change and it can't be retried automatically."
        case .badContainer, .badDatabase:
            return "iCloud sync is misconfigured for this app."
        case .incompatibleVersion:
            return "Update SimmerSmith to keep syncing with iCloud."
        case .managedAccountRestricted:
            return "Your iCloud account's management restrictions are blocking this sync."
        case .constraintViolation:
            return "This change conflicts with existing iCloud data and can't sync."
        default:
            return "This change couldn't sync to iCloud."
        }
    }

    /// Ack-seam rebase for `sentRecordZoneChanges` (simmersmith-dkj). Called ONLY when the
    /// generation bookkeeping proved the store's record was mutated after `acked`'s payload went
    /// out — i.e. a second `save()` interleaved and `acked` reflects the older wire payload.
    ///
    /// Keeps `current`'s fields (the user's newer edit) and lifts only `acked`'s system
    /// fields/change tag onto them (`CKRecord.copy()` preserves `changedKeys()` exactly —
    /// `HouseholdLocalStoreCopyTests.changedKeysSurviveStoreBoundary`), so the resave already
    /// pending for that interleaving `save()` carries the tag the server now expects.
    ///
    /// Field copy goes through `manifestKeys` and NOT `current.allKeys()` (simmersmith-t6t):
    /// a deliberately CLEARED field is ABSENT from `allKeys()`, so an allKeys copy would leave
    /// `acked`'s stale value in place and silently resurrect it — the exact class t6t exists to
    /// kill, which this seam must not reintroduce.
    static func rebaseAckedRecord(acked: CKRecord, current: CKRecord) -> CKRecord {
        let rebased = acked.copy() as! CKRecord
        applyFields(from: current, onto: rebased)
        return rebased
    }

    /// Copy `source`'s field set onto `destination`, PROPAGATING CLEARS (simmersmith-t6t).
    ///
    /// The naive `for key in source.allKeys() { dest[key] = source[key] }` is wrong at every
    /// local-wins seam: a deliberately CLEARED field (nil'd — e.g. `WeekRepository.updateMealSide`'s
    /// `SidePatch.clear` nils `recipeName` AND the `recipe` reference) is ABSENT from `allKeys()`,
    /// so the destination silently keeps the server's stale value and the user's clear resurrects.
    ///
    /// Key set:
    /// - Manifest type → every manifest key (scalar `fields` + `refs`; they share one CKRecord key
    ///   namespace). Writing them ALL from `source` means an absent key writes nil = an explicit
    ///   clear, while a field this app's manifest doesn't know about (a NEWER build's addition,
    ///   already on the server record) is left untouched rather than destroyed. That
    ///   forward-compatibility property is why this enumerates the manifest instead of a key union
    ///   for manifest types (see the mixed-version writer design bead).
    /// - Manifest-EXTERNAL type (GroceryItem / EventGroceryItem via their own codecs, and the
    ///   CKAsset image types) → the union of both records' keys, so a cleared key is still written
    ///   as nil. These types genuinely carry clearable fields (a grocery `quantityOverride` the
    ///   user removes), so `source.allKeys()` alone would resurrect those clears too.
    static func applyFields(from source: CKRecord, onto destination: CKRecord) {
        for key in fieldKeys(source: source, destination: destination) {
            destination[key] = source[key]
        }
    }

    static func fieldKeys(source: CKRecord, destination: CKRecord) -> [String] {
        if let type = HouseholdRecordType(recordTypeName: source.recordType) {
            return type.fields.map(\.name) + type.refs.map(\.name)
        }
        return Array(Set(source.allKeys()).union(destination.allKeys()))
    }

    /// Pure record-level LWW rebase for non-merger types at the `serverRecordChanged` seam
    /// (simmersmith-6ce). Every manifest record type carries an `updatedAt` date; compare it
    /// on `local` (our attempted, now-rejected save) vs. `server` (the current server record,
    /// which carries the fresh change tag) to decide who legitimately wins:
    /// - Both present, local strictly newer → LOCAL wins: rebase local's fields onto `server`
    ///   (adopting its tag) and ask for a re-save.
    /// - Both present, server newer-or-equal (ties go to the server, since it's already the
    ///   record of truth) → SERVER wins: keep `server` as-is and do NOT re-save our stale copy.
    /// - Either `updatedAt` missing → fall back to the historical blanket local-wins behavior
    ///   (copy local's manifest keys onto `server`, re-save) since recency can't be judged.
    static func rebaseNonMergerRecord(local: CKRecord, server: CKRecord) -> (record: CKRecord, reEnqueue: Bool) {
        guard let localDate = local["updatedAt"] as? Date,
              let serverDate = server["updatedAt"] as? Date else {
            let rebased = server.copy() as! CKRecord
            applyFields(from: local, onto: rebased)
            return (rebased, true)
        }
        if localDate > serverDate {
            let rebased = server.copy() as! CKRecord
            applyFields(from: local, onto: rebased)
            return (rebased, true)
        }
        return (server.copy() as! CKRecord, false)
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut, .switchAccounts:
            // The local mirror belongs to the previous account — drop it.
            clearShadowMirror()
            mutateStoreUnderShadowGate {
                store.removeAll()
            }
            callbackRelay.emit(.accountChanged)
        case .signIn:
            break
        @unknown default:
            break
        }
    }

    // MARK: State persistence

    /// Legacy active-engine state remains write-only in P1. Cold construction always passes a
    /// nil token; the file is retained solely for the explicit deletion backstop until P2.
    private static let stateLog = Logger(subsystem: "app.simmersmith.cloud", category: "HouseholdSync")

    private static func saveState(_ serialization: CKSyncEngine.State.Serialization, to url: URL) {
        do {
            let data = try JSONEncoder().encode(serialization)
            try data.write(to: url, options: .atomic)
        } catch {
            stateLog.error("failed to persist sync state to \(url.path, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// simmersmith-r8q interim fix: delete a persisted sync-engine state file so the NEXT
    /// engine construction at this URL starts from a nil token, forcing a full zone re-fetch.
    /// The local store is rebuilt fresh in-memory on every cold launch, but the on-disk state
    /// token otherwise survives — so a resumed `fetchChanges` returns only deltas against a
    /// store that never had the base data, silently leaving it partial. Superseded once the
    /// store itself is persisted (bead e0a); until then, callers should invoke this BEFORE
    /// constructing the engine that will load from the same URL. Missing file is a no-op.
    public static func clearPersistedState(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
#endif
