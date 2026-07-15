#if canImport(CloudKit)
import CloudKit
import Darwin
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
        (serialization: Data, coverageRevision: UInt64, zoneEnsured: Bool)
    ] = []
    private var shadowCompletedFetch: (records: [CKRecord], coverageRevision: UInt64, zoneEnsured: Bool)?
    private var shadowFetchEpochOpen = false
    private var shadowCaptureAllowed = true
    private var shadowMissedLocalMutation = false
    private var shadowRootDirectory: URL?
    /// Owner engines own their zone (create it lazily, recreate on loss). A PARTICIPANT
    /// engine (shared DB) does NOT own the zone — it must never enqueue `.saveZone` nor
    /// recreate a zone it can't create, and a zone deletion means the share was revoked.
    private let ownsZone: Bool
    private let log = Logger(subsystem: "app.simmersmith.cloud", category: "HouseholdSync")

    private var syncEngine: CKSyncEngine!
    private let zoneEnsuredLock = NSLock()
    private var zoneEnsured = false

    /// Optional sticky field-merger (Phase 4). When set, records whose type it `handles`
    /// are field-merged at the fetch + serverRecordChanged seams instead of blanket LWW.
    public var merger: RecordMerger?

    /// Called once per sync event after the local store has been mutated by remote changes
    /// (`fetchedRecordZoneChanges`) or by server-authoritative record replacements
    /// (`sentRecordZoneChanges`). Set by `HouseholdSession`/`RecipeRepository` to trigger
    /// a cache refresh. Nil in tests — no behavioral change when unset.
    public var onStoreChanged: (@Sendable () -> Void)?

    /// Called when a record save fails with an error the engine classifies as permanent (see
    /// `SyncFailure.Kind`) — i.e. one it will NOT silently re-enqueue. Called off-main from the
    /// delegate, mirroring `onStoreChanged`. Nil in tests and until a caller (simmersmith-qrt)
    /// wires it up — no behavioral change when unset.
    public var onSyncError: (@Sendable (SyncFailure) -> Void)?

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
    public var onRecordSaved: (@Sendable (String) -> Void)?

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

    @discardableResult
    private func stampSentGenerationLocked(_ id: CKRecord.ID) -> UInt64? {
        let generation = localGeneration[id, default: 0]
        guard generation > 0 else { return nil }
        sentGeneration[id] = generation
        return UInt64(generation)
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
        shadowMirrorRootDirectory: URL? = nil
    ) {
        self.database = database
        self.zoneID = zoneID
        self.store = store
        self.stateURL = stateURL
        self.ownsZone = ownsZone
        self.shadowRootDirectory = shadowMirrorRootDirectory
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
                    zoneEnsured: state.zoneEnsured), publication == nil {
                    publication = candidate
                }
            }
            return publication
        }
        if let publication { try await runtime.publish(publication) }
    }

    /// Sign-out/account change clears a fully fenced scope. P1 failures are diagnostic-only:
    /// callers preserve the active engine and full-fetch behavior even if a cache cannot clear.
    public func clearShadowMirror() {
        shadowMirrorLock.lock(); defer { shadowMirrorLock.unlock() }
        shadowCaptureAllowed = false
        // Fence synchronously so no stale pointer can install, but do not wait on a whole-cache
        // asset build from HouseholdSession's main-actor teardown. Moving the root makes every
        // in-flight candidate unreachable; its final install also fails the writer fence.
        shadowMirror?.fence()
        shadowMirror = nil
        shadowStateHistory = []
        shadowCompletedFetch = nil
        shadowFetchEpochOpen = false
        if let shadowRootDirectory {
            Self.clearShadowRoot(shadowRootDirectory)
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
        shadowStateHistory = []
        shadowCompletedFetch = nil
        shadowFetchEpochOpen = false
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
            shadowStateHistory.append((data, coverageRevision, ensured))
            if shadowStateHistory.count > 256 {
                shadowStateHistory.removeFirst(shadowStateHistory.count - 256)
            }
            guard let runtime = shadowMirror else { return }
            do {
                if let publication = try runtime.observeStateUpdate(
                    data,
                    coverageRevision: coverageRevision,
                    zoneEnsured: ensured
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
                zoneEnsured: zoneEnsuredValue())
            shadowCompletedFetch = snapshot
            guard let runtime = shadowMirror else { return }
            do {
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

    private static func clearShadowRoot(_ root: URL) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else { return }
        let retired = root.deletingLastPathComponent()
            .appendingPathComponent(".shadow-mirror-clearing-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.moveItem(at: root, to: retired)
            let parent = root.deletingLastPathComponent()
            let descriptor = Darwin.open(parent.path, O_RDONLY)
            if descriptor >= 0 {
                _ = Darwin.fsync(descriptor)
                Darwin.close(descriptor)
            }
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.removeItem(at: retired)
            }
        } catch {}
    }

    // MARK: Public mutation API

    /// Stage a record save: write it locally, then tell the engine it's pending. The
    /// zone is created lazily on the first save.
    public func save(_ record: CKRecord) {
        shadowMirrorLock.withLock {
            let mutationGeneration = bumpGenerationLocked(record.recordID)
            if let shadowMirror {
                shadowMirror.appendSaveBeforeMutation(
                    record,
                    mutationGeneration: mutationGeneration)
            } else {
                shadowMissedLocalMutation = true
            }
            store.setRecord(record)
            // simmersmith-c7r: `save()` can be called concurrently from multiple threads, so
            // the check-and-set remains atomic. The mirror gate also keeps the store payload,
            // its generation stamp, and CKSyncEngine pending ID in one logical mutation.
            zoneEnsuredLock.lock()
            let shouldEnsureZone = !zoneEnsured
            zoneEnsured = true
            zoneEnsuredLock.unlock()
            if shouldEnsureZone, ownsZone {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            }
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            shadowCoverageRevision &+= 1
        }
    }

    public func delete(_ recordID: CKRecord.ID) {
        shadowMirrorLock.withLock {
            let mutationGeneration = bumpGenerationLocked(recordID)
            if let record = store.record(for: recordID) {
                shadowMirror?.appendDeleteBeforeMutation(
                    MirrorRecordIdentity(record),
                    mutationGeneration: mutationGeneration)
                if shadowMirror == nil { shadowMissedLocalMutation = true }
            } else if let shadowMirror {
                // A record ID does not carry its record type, so inventing a tombstone here
                // would fail to supersede a later save of the real identity. Disable this
                // diagnostic cache instead; the active delete and full-fetch path continue.
                shadowMirror.invalidate()
            } else {
                shadowMissedLocalMutation = true
            }
            store.removeRecord(recordID)
            syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
            shadowCoverageRevision &+= 1
        }
    }

    /// Delete a record AND sweep its local CASCADE subtree. CloudKit's `.deleteSelf` only
    /// fires on the deleting device, so the client must enqueue child deletes itself; this
    /// recurses the local store's `.deleteSelf` edges (recipe→ingredient/step→child-step,
    /// event→meal→ingredient, baseIngredient→variation). The sweep lives ONLY here on the
    /// issuing engine — the fetch handler stays the untouched LWW seam.
    public func deleteCascading(_ recordID: CKRecord.ID) {
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

    /// True while record changes are still queued (e.g. a rebased save awaiting retry).
    public var hasPendingRecordChanges: Bool {
        !syncEngine.state.pendingRecordZoneChanges.isEmpty
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

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            // simmersmith-dkj: stamp the generation the OUTGOING payload was built from. The ack
            // for this batch compares against the store's generation at that later moment; an
            // intervening `save()` will have bumped it, which is what tells us the ack is stale.
            self.shadowMirrorLock.withLock {
                guard let record = self.store.record(for: recordID) else { return nil }
                if let mutationGeneration = self.stampSentGenerationLocked(recordID) {
                    self.shadowMirror?.markSent(
                        recordID: recordID,
                        mutationGeneration: mutationGeneration)
                    self.shadowCoverageRevision &+= 1
                }
                return record
            }
        }
        guard let batch else { return nil }
        // The initializer may cap a large pending set. Stamp only the deletes it actually chose,
        // exactly as save stamping is gated by its record-provider callback; a deferred delete
        // must remain pending rather than being mistaken for an in-flight generation.
        for recordID in batch.recordIDsToDelete {
            shadowMirrorLock.withLock {
                guard let mutationGeneration = stampSentGenerationLocked(recordID) else { return }
                shadowMirror?.markSent(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration)
                shadowCoverageRevision &+= 1
            }
        }
        return batch
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.saveState(update.stateSerialization, to: stateURL)
            observeShadowState(update.stateSerialization)

        case .fetchedRecordZoneChanges(let changes):
            let pendingSaves = pendingSaveIDs()
            for modification in changes.modifications {
                let remote = modification.record
                // The zone-wide CKShare record lives in the shared zone and loops back
                // through fetched changes on the owner engine — never ingest it as data.
                if Self.isShareRecord(remote) { continue }
                let hasPendingEdit = pendingSaves.contains(remote.recordID)
                // Field-merge ONLY on a genuine concurrent edit — i.e. we hold an UNSYNCED local
                // edit for this record. Without a pending edit the remote is authoritative (a
                // peer's later write, including a deliberate unmerge that clears event_quantity);
                // merging our stale local would resurrect dropped state via the sticky rules.
                // (The other side of a conflict — our save losing the race — is handled at the
                // serverRecordChanged seam.)
                if hasPendingEdit, let merger, merger.handles(remote.recordType),
                   let local = store.record(for: remote.recordID) {
                    let result = merger.resolve(local: local, remote: remote)
                    shadowMirrorLock.withLock {
                        let mutationGeneration = bumpGenerationLocked(result.record.recordID)
                        if let shadowMirror {
                            shadowMirror.appendSaveBeforeMutation(
                                result.record,
                                mutationGeneration: mutationGeneration)
                        } else {
                            shadowMissedLocalMutation = true
                        }
                        store.setRecord(result.record)
                        if result.needsResave {
                            syncEngine.state.add(
                                pendingRecordZoneChanges: [.saveRecord(result.record.recordID)])
                        }
                        shadowCoverageRevision &+= 1
                    }
                    note("merged fetched \(remote.recordID.recordName) resave=\(result.needsResave)")
                    continue
                }
                // A pending edit on a non-merge record must reach the server first (don't let the
                // fetch clobber it; the conflict surfaces as serverRecordChanged on send).
                if hasPendingEdit {
                    note("skip fetched mod (local pending) \(remote.recordID.recordName)")
                    continue
                }
                mutateStoreUnderShadowGate {
                    store.applyRemoteModification(remote)
                }
                note("fetched mod \(remote.recordID.recordName)")
            }
            for deletion in changes.deletions {
                mutateStoreUnderShadowGate {
                    store.removeRecord(deletion.recordID)
                }
                note("fetched del \(deletion.recordID.recordName)")
            }
            onStoreChanged?()

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
                    if let mutationGeneration = sent.generation {
                        shadowMirror?.acknowledge(
                            recordID: saved.recordID,
                            mutationGeneration: mutationGeneration,
                            rebasedRecord: shadowRebase)
                    } else if shadowMirror != nil {
                        shadowMirror?.invalidate()
                    }
                    if let toStore { store.setRecord(toStore) }
                    shadowCoverageRevision &+= 1
                }
                if staleAck { note("stale ack rebased \(saved.recordID.recordName)") }
                note("saved \(saved.recordID.recordName)=\(saved["value"] as? String ?? "?")")
                onRecordSaved?(saved.recordID.recordName)
            }
            // simmersmith-ioj (lead amendment): a DELETE of the failed record resolves its
            // failure exactly as well as a re-save does — the user removed the data rather than
            // fixing it. Without this, deleting the offending record is a one-way trip: no later
            // save of that recordName ever fires, so the permanent-failure banner (which a clean
            // tick deliberately no longer clears) would persist for the rest of the session.
            for deletedID in sent.deletedRecordIDs {
                shadowMirrorLock.withLock {
                    let sent = consumeSentGenerationLocked(deletedID)
                    if let mutationGeneration = sent.generation {
                        shadowMirror?.acknowledge(recordID: deletedID, mutationGeneration: mutationGeneration)
                        shadowCoverageRevision &+= 1
                    } else if shadowMirror != nil {
                        shadowMirror?.invalidate()
                    }
                }
                note("deleted \(deletedID.recordName)")
                onRecordSaved?(deletedID.recordName)
            }
            for failure in sent.failedRecordSaves {
                note("FAILED \(failure.record.recordID.recordName) code=\(failure.error.code.rawValue)")
                handleFailedSave(failure)
            }
            for (recordID, error) in sent.failedRecordDeletes {
                note("FAILED delete \(recordID.recordName) code=\(error.code.rawValue)")
                handleFailedDelete(recordID: recordID, error: error)
            }
            onStoreChanged?()

        case .accountChange(let change):
            handleAccountChange(change)

        case .fetchedDatabaseChanges(let changes):
            // A PARTICIPANT whose shared zone is deleted/revoked (owner removed them or
            // deleted the share) must purge its local mirror. OWNER-SAFE: gated on
            // !ownsZone so an owner's own zone-deletion (e.g. factory reset) never wipes
            // the owner mirror through this path — owners keep today's no-op behavior.
            if !ownsZone, changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                mutateStoreUnderShadowGate {
                    store.removeAll()
                }
                onStoreChanged?()
                note("participant shared zone revoked \(zoneID.zoneName)")
            }

        case .willFetchChanges:
            beginShadowFetchEpoch()

        case .didFetchChanges:
            completeShadowFetchEpoch()

        // Lifecycle / no-op for Phase 2a.
        case .willSendChanges, .didSendChanges,
             .sentDatabaseChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    /// A CKShare record (the zone-wide share itself) surfaces through the owner engine's
    /// fetched changes — it must NEVER be ingested as household data.
    static func isShareRecord(_ record: CKRecord) -> Bool {
        record.recordType == "cloudkit.share" || record.recordID.recordName == CKRecordNameZoneWideShare
    }

    private func pendingSaveIDs() -> Set<CKRecord.ID> {
        var ids = Set<CKRecord.ID>()
        for change in syncEngine.state.pendingRecordZoneChanges {
            if case .saveRecord(let id) = change { ids.insert(id) }
        }
        return ids
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
    ) {
        guard let mutationGeneration else {
            if shadowMirror != nil { shadowMirror?.invalidate() }
            return
        }
        switch resolution {
        case .retry(let replacement):
            if isStale {
                shadowMirror?.acknowledge(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    rebasedRecord: replacement)
            } else {
                shadowMirror?.markDeliveryFailure(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    permanent: false,
                    rebasedRecord: replacement)
            }
        case .blocked:
            if isStale {
                shadowMirror?.acknowledge(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    rebasedRecord: store.record(for: recordID))
            } else {
                shadowMirror?.markDeliveryFailure(
                    recordID: recordID,
                    mutationGeneration: mutationGeneration,
                    permanent: true)
            }
        case .consumed(let replacement):
            shadowMirror?.acknowledge(
                recordID: recordID,
                mutationGeneration: mutationGeneration,
                rebasedRecord: isStale ? replacement : nil)
        }
    }

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        let recordID = failure.record.recordID
        var surfacedFailure: SyncFailure?
        shadowMirrorLock.withLock {
            let sent = consumeSentGenerationLocked(recordID)
            let current = store.record(for: recordID)
            switch failure.error.code {
            case .serverRecordChanged:
                // The newer local operation wins the race against this older wire payload. A
                // newer delete stays deleted; a newer save is rebased onto server system fields.
                guard let serverRecord = failure.error.serverRecord else {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: sent.isStale,
                        resolution: .blocked)
                    shadowCoverageRevision &+= 1
                    return
                }
                if sent.isStale, current == nil {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: true,
                        resolution: .consumed(nil))
                } else if let merger, merger.handles(serverRecord.recordType) {
                    let result = merger.resolve(
                        local: sent.isStale ? (current ?? failure.record) : failure.record,
                        remote: serverRecord)
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: sent.isStale,
                        resolution: .retry(result.record))
                    store.setRecord(result.record)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else if let current {
                    if sent.isStale {
                        let rebased = Self.rebaseAckedRecord(acked: serverRecord, current: current)
                        resolveShadowDeliveryLocked(
                            recordID: recordID,
                            mutationGeneration: sent.generation,
                            isStale: true,
                            resolution: .retry(rebased))
                        store.setRecord(rebased)
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    } else {
                        let decision = Self.rebaseNonMergerRecord(local: current, server: serverRecord)
                        resolveShadowDeliveryLocked(
                            recordID: recordID,
                            mutationGeneration: sent.generation,
                            isStale: false,
                            resolution: decision.reEnqueue ? .retry(decision.record) : .consumed(nil))
                        store.setRecord(decision.record)
                        if decision.reEnqueue {
                            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                        }
                    }
                } else {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: false,
                        resolution: .consumed(nil))
                    store.setRecord(serverRecord)
                }

            case .zoneNotFound, .userDeletedZone:
                // Re-create the zone and re-enqueue the save — OWNER ONLY. A participant cannot
                // create the owner's zone; for it this means the share is gone.
                if ownsZone, !(sent.isStale && current == nil) {
                    let retryRecord = sent.isStale ? current : failure.record
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: sent.isStale,
                        resolution: .retry(retryRecord))
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: sent.isStale,
                        resolution: sent.isStale ? .consumed(current) : .blocked)
                }

            case .unknownItem:
                if sent.isStale, let current {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: true,
                        resolution: .retry(current))
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else if sent.isStale {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: true,
                        resolution: .consumed(nil))
                } else {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: false,
                        resolution: .blocked)
                    store.removeRecord(recordID)
                }

            default:
                // simmersmith-dab: retry known-transient failures; surface every other code.
                let code = failure.error.code
                log.error("household save failed for \(recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
                switch Self.classifyFailure(code) {
                case .transient:
                    if sent.isStale, current == nil {
                        resolveShadowDeliveryLocked(
                            recordID: recordID,
                            mutationGeneration: sent.generation,
                            isStale: true,
                            resolution: .consumed(nil))
                    } else {
                        let retryRecord = sent.isStale ? current : failure.record
                        resolveShadowDeliveryLocked(
                            recordID: recordID,
                            mutationGeneration: sent.generation,
                            isStale: sent.isStale,
                            resolution: .retry(retryRecord))
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                case .permanent:
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: sent.isStale,
                        resolution: sent.isStale ? .consumed(current) : .blocked)
                    surfacedFailure = SyncFailure(
                        recordName: recordID.recordName,
                        code: code,
                        kind: .permanent,
                        message: Self.userMessage(for: code))
                }
            }
            shadowCoverageRevision &+= 1
        }
        if let surfacedFailure { onSyncError?(surfacedFailure) }
    }

    private func handleFailedDelete(recordID: CKRecord.ID, error: CKError) {
        var surfacedFailure: SyncFailure?
        var resolvedRecordName: String?
        shadowMirrorLock.withLock {
            let sent = consumeSentGenerationLocked(recordID)
            switch Self.classifyFailedDelete(error.code) {
            case .consumed:
                // The record (or its entire zone) is already absent, so the requested end state
                // has been reached even though CloudKit reported the delete as a failure.
                resolveShadowDeliveryLocked(
                    recordID: recordID,
                    mutationGeneration: sent.generation,
                    isStale: sent.isStale,
                    resolution: .consumed(nil))
                resolvedRecordName = recordID.recordName

            case .retry:
                if sent.isStale {
                    // A newer save/delete owns the current pending slot. Consume only this old
                    // wire attempt; its exact durable successor remains in the outbox.
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: true,
                        resolution: .consumed(nil))
                } else {
                    resolveShadowDeliveryLocked(
                        recordID: recordID,
                        mutationGeneration: sent.generation,
                        isStale: false,
                        resolution: .retry(nil))
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
                }

            case .blocked:
                resolveShadowDeliveryLocked(
                    recordID: recordID,
                    mutationGeneration: sent.generation,
                    isStale: sent.isStale,
                    resolution: sent.isStale ? .consumed(nil) : .blocked)
                surfacedFailure = SyncFailure(
                    recordName: recordID.recordName,
                    code: error.code,
                    kind: .permanent,
                    message: Self.userMessage(for: error.code))
            }
            shadowCoverageRevision &+= 1
        }
        if let surfacedFailure { onSyncError?(surfacedFailure) }
        if let resolvedRecordName { onRecordSaved?(resolvedRecordName) }
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
