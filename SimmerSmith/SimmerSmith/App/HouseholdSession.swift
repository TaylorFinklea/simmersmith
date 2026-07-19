#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SwiftData
import SimmerSmithKit
import CloudKitProvisioning
import HouseholdSync

enum HouseholdSessionInterventionCountPolicy {
    static func resolve(
        cachedBootstrapActivated: Bool,
        cachedCandidateCount: Int?,
        recoveryCandidateCount: Int?
    ) -> Int {
        if cachedBootstrapActivated { return cachedCandidateCount ?? 0 }
        return recoveryCandidateCount ?? 0
    }
}

/// Whether this session OWNS the household zone (its own private DB) or PARTICIPATES in
/// someone else's shared zone (the shared DB). Default `.owner` preserves every existing
/// call site. A participant carries the owner's zone ID, recovered from CKShare metadata
/// (never constructed — the owner-name differs across accounts). Equatable only; the value
/// is MainActor-confined (HouseholdSession is @MainActor) so Sendable isn't required.
enum HouseholdSessionRole: Equatable {
    case owner
    case participant(sharedZoneID: CKRecordZone.ID)
    var isOwner: Bool { if case .owner = self { return true } else { return false } }
}

struct HouseholdSessionLifecycleSnapshot: Equatable, Sendable {
    let event: HouseholdSyncLifecycleEvent
    let scope: MirrorScope?
}

/// Small ordered handoff used by the engine→session authority bridge. Legacy session effects
/// are applied immediately; only the authority projection waits for AppState's dispatcher and
/// then drains exactly once in arrival order.
final class OrderedCallbackBuffer<Event> {
    private var sink: ((Event) -> Void)?
    private var pending: [Event] = []

    func submit(_ event: Event) {
        if let sink {
            sink(event)
        } else {
            pending.append(event)
        }
    }

    func install(_ sink: @escaping (Event) -> Void) {
        self.sink = sink
        let events = pending
        pending = []
        events.forEach(sink)
    }

    func clear() {
        sink = nil
        pending = []
    }
}

/// Teardown-safe engine→AppState bridge. Engine callbacks retain this relay, not the Session,
/// until every already-emitted lifecycle snapshot has crossed to MainActor. Detaching the first
/// event therefore cannot drop a later stronger account boundary.
final class HouseholdSessionLifecycleRelay: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (HouseholdSessionLifecycleSnapshot) -> Void

    private let lock = NSLock()
    private var pending: [HouseholdSessionLifecycleSnapshot] = []
    private var sink: Sink?
    private var drainScheduled = false

    func submit(_ snapshot: HouseholdSessionLifecycleSnapshot) {
        let shouldSchedule = lock.withLock { () -> Bool in
            pending.append(snapshot)
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        if shouldSchedule { scheduleDrain() }
    }

    @MainActor
    func install(_ sink: @escaping Sink) {
        let shouldSchedule = lock.withLock { () -> Bool in
            self.sink = sink
            guard !pending.isEmpty, !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        if shouldSchedule { scheduleDrain() }
    }

    private func scheduleDrain() {
        Task { @MainActor [self] in drain() }
    }

    @MainActor
    private func drain() {
        while true {
            let next = lock.withLock { () -> (Sink, HouseholdSessionLifecycleSnapshot)? in
                guard let sink, !pending.isEmpty else {
                    drainScheduled = false
                    return nil
                }
                return (sink, pending.removeFirst())
            }
            guard let (sink, snapshot) = next else { return }
            sink(snapshot)
        }
    }
}

enum DeferredCachedSystemWorkStage: CaseIterable, Hashable {
    case ingredientsMigration
    case recipesMigration
    case ownerCurrentWeek
    case projectionReload
    case repairActivation
    case leftoverCleanup
}

/// Session-local progress for the cached authority tail. Completion advances only after that
/// stage's async boundary returns; stale teardown abandons the claim with the session.
struct DeferredCachedSystemWorkPlan {
    private(set) var completed: Set<DeferredCachedSystemWorkStage> = []
    private(set) var inFlight: DeferredCachedSystemWorkStage?

    var hasPendingWork: Bool {
        inFlight != nil || completed.count < DeferredCachedSystemWorkStage.allCases.count
    }

    mutating func claimNext(isAuthoritative: Bool) -> DeferredCachedSystemWorkStage? {
        guard isAuthoritative, inFlight == nil else { return nil }
        guard let stage = DeferredCachedSystemWorkStage.allCases.first(where: {
            !completed.contains($0)
        }) else { return nil }
        inFlight = stage
        return stage
    }

    mutating func complete(_ stage: DeferredCachedSystemWorkStage) {
        guard inFlight == stage else { return }
        completed.insert(stage)
        inFlight = nil
    }

    mutating func abandon(_ stage: DeferredCachedSystemWorkStage) {
        guard inFlight == stage else { return }
        inFlight = nil
    }

    mutating func discard() {
        completed = []
        inFlight = nil
    }
}

/// SP-C: the single app-lifetime owner of the household CloudKit planes.
///
/// One instance is created at launch (Task 5 wires it into AppState) and lives for
/// the lifetime of the app. It boots the private household zone + CKSyncEngine stack
/// and exposes the live store + engine to repositories.
///
/// Slice 1: OWNER-ONLY on `.privateCloudDatabase`. The shared-DB/participant join path
/// is not built here.
/// TODO(SP-C participant): shared-DB join via CKShare
@MainActor
@Observable
final class HouseholdSession {
    // MARK: — Owned planes

    let store: HouseholdLocalStore
    let engine: HouseholdSyncEngine
    let catalog: PublicCatalogReader
    let zoneID: CKRecordZone.ID
    /// Owner (private DB, own zone) vs participant (shared DB, owner's zone).
    let role: HouseholdSessionRole
    /// The household id (owner zone derivation; exposed for owner-side share creation).
    let householdID: String
    /// simmersmith-qrt: optional so pre-existing call sites (and any future test
    /// construction) keep compiling without a center — nil means "no-op, no behavioral
    /// change", mirroring `engine.onStoreChanged`/`onSyncError` being nil by default.
    private let syncStatusCenter: SyncStatusCenter?
    private enum EngineCallback {
        case storeChanged(pendingCount: Int)
        case syncError(SyncFailure)
        case recordSaved(String)
        case durabilityFailure(MirrorDurabilityFailure)
    }
    private let authorityEventBuffer = OrderedCallbackBuffer<HouseholdAuthorityEvent>()
    private let lifecycleEventRelay = HouseholdSessionLifecycleRelay()
    let lifecycleSourceID = UUID()
    var onAuthorityEvent: ((HouseholdAuthorityEvent) -> Void)? {
        didSet {
            if let onAuthorityEvent {
                authorityEventBuffer.install(onAuthorityEvent)
            } else {
                authorityEventBuffer.clear()
            }
        }
    }
    var onLifecycleEvent: (@MainActor @Sendable (HouseholdSessionLifecycleSnapshot) -> Void)? {
        didSet {
            if let onLifecycleEvent {
                lifecycleEventRelay.install(onLifecycleEvent)
            }
        }
    }
    /// SP-A Phase 4/5 follow-up (simmersmith-gju) — debounced cross-record repair layer
    /// (WeekRepairAdapter + EventMergeAdapter.dedupeWeekGrocery), previously only reachable
    /// from the DEBUG screen. Signaled on every post-fetch/post-send change below, and
    /// callable directly by a manual "fix it" action (e.g. the grocery Dedupe button).
    let repairScheduler: RepairScheduler

    // MARK: — Per-user PRIVATE plane (NSPCKC)
    //
    // SP-C slice 5: a SEPARATE mechanism from the household CKSyncEngine stack above.
    // This is SwiftData over the user's PRIVATE CloudKit DB (NSPersistentCloudKitContainer
    // underneath) and it syncs AUTOMATICALLY — no engine, no merger, no manual save-to-
    // CloudKit. It is PER-USER (the signed-in iCloud account), NOT keyed by householdID:
    // every device on the same account converges via NSPCKC. Phase 0.5 proved NSPCKC and
    // the household CKSyncEngine stack coexist in one container with no token/zone clash.
    //
    // Created in `start()` (mirrors CloudKitDebugView.runPrivatePlaneCheck's construction:
    // `makeSimmerSmithPrivatePlaneContainer()` → `container.mainContext`). It stays nil if
    // construction throws (e.g. iCloud unavailable) — the household plane works regardless.
    private var privateContainer: ModelContainer?

    /// Upsert/read façade over the private plane's `@MainActor` ModelContext. Returns nil
    /// until `start()` succeeds in creating the container (degraded / pre-boot). The
    /// Profile/Preference repositories read/write exclusively through this.
    ///
    /// `@MainActor`-isolated because it touches `privateContainer.mainContext` (a
    /// `@MainActor` property). All callers are already MainActor, so this is a clean
    /// hardening — it makes the isolation explicit rather than relying on the enclosing
    /// `@MainActor` class annotation for a computed property the compiler could otherwise
    /// treat as non-isolated.
    @MainActor var privateStore: PrivatePlaneStore? {
        guard let privateContainer else { return nil }
        return PrivatePlaneStore(context: privateContainer.mainContext)
    }
    /// Durable URL of the sync-engine state token. Held so `clearState()` can delete it
    /// on sign-out — otherwise a different household signed in on this device would
    /// inherit the prior household's sync token (Task-3 token-leakage risk).
    private let stateURL: URL
    /// Scoped P1 shadow generations live beside, but never replace, the legacy active-engine
    /// state token. A new session receives a complete `MirrorScope` only after identity resolves.
    let shadowMirrorRootURL: URL
    /// True only when a verified P2e candidate was constructed and activated. A rejected
    /// candidate falls back to the existing nil-state/full-fetch engine.
    let isCachedBootstrap: Bool
    let isRecoveryOnly: Bool
    /// Recovery-only content remains non-renderable until the nil-state full fetch and atomic
    /// durable overlay both succeed. A transient fetch failure must not wire `.ready`.
    private(set) var recoveryOnlyFetchSucceeded = false
    let cachedInterventionCount: Int
    private let recoveryCandidate: MirrorRecoveryCandidate?
    private enum RecoveryCandidateDisposition: Equatable {
        case pending
        case applied
        case released
    }
    private var recoveryCandidateDisposition: RecoveryCandidateDisposition
    /// Invalidated by clear/detach so a late account-identity callback cannot re-enable an old
    /// writer after this session has been torn down or parked for adoption.
    private var shadowCaptureNonce = UUID()
    /// The cached boot tail belongs to one promoted session. It is intentionally session-local so
    /// retries resume from their first incomplete operation and teardown discards its state.
    private var deferredSystemWork = DeferredCachedSystemWorkPlan()

    /// Exact engine-owned authority for this session. A cached session starts denied and only
    /// AppState's epoch-and-identity checked reconciliation completion may promote it.
    var hasCurrentAuthority: Bool { engine.hasSessionAuthority }

    @discardableResult
    func promoteCachedAuthority() -> Bool {
        engine.promoteSessionAuthority()
    }

    func revokeAuthority() {
        engine.revokeSessionAuthority()
    }

    func claimNextDeferredSystemWorkStage() -> DeferredCachedSystemWorkStage? {
        deferredSystemWork.claimNext(isAuthoritative: hasCurrentAuthority)
    }

    func completeDeferredSystemWorkStage(_ stage: DeferredCachedSystemWorkStage) {
        deferredSystemWork.complete(stage)
    }

    func abandonDeferredSystemWorkStage(_ stage: DeferredCachedSystemWorkStage) {
        deferredSystemWork.abandon(stage)
    }

    func discardDeferredSystemWork() {
        deferredSystemWork.discard()
    }

    var hasPendingDeferredSystemWork: Bool {
        deferredSystemWork.hasPendingWork
    }

    // MARK: — Observable state

    /// Mirrors the sync-engine lifecycle; repositories and UI observe this.
    var syncPhase: AppState.SyncPhase = .idle

    enum CachedHouseholdReconciliationOutcome: Equatable {
        case succeeded(pendingCount: Int)
        case failed
    }

    /// Bumped after every remote change batch or authoritative server write so that
    /// @Observable consumers (repositories, views) know to re-read the store.
    var storeRevision: Int = 0

    // MARK: — Init

    convenience init(
        householdID: String,
        role: HouseholdSessionRole = .owner,
        syncStatusCenter: SyncStatusCenter? = nil,
        bootstrapCandidate: MirrorBootstrapCandidate? = nil,
        recoveryCandidate: MirrorRecoveryCandidate? = nil
    ) {
        try! self.init(
            householdID: householdID,
            role: role,
            initialMirrorScope: recoveryCandidate?.plan.scope ?? bootstrapCandidate?.bootstrap.scope,
            allowUnscopedTestConstruction: true,
            syncStatusCenter: syncStatusCenter,
            bootstrapCandidate: bootstrapCandidate,
            recoveryCandidate: recoveryCandidate)
    }

    convenience init(
        householdID: String,
        role: HouseholdSessionRole = .owner,
        initialMirrorScope: MirrorScope,
        syncStatusCenter: SyncStatusCenter? = nil,
        bootstrapCandidate: MirrorBootstrapCandidate? = nil,
        recoveryCandidate: MirrorRecoveryCandidate? = nil
    ) throws {
        try self.init(
            householdID: householdID,
            role: role,
            initialMirrorScope: initialMirrorScope,
            allowUnscopedTestConstruction: false,
            syncStatusCenter: syncStatusCenter,
            bootstrapCandidate: bootstrapCandidate,
            recoveryCandidate: recoveryCandidate)
    }

    private init(
        householdID: String,
        role: HouseholdSessionRole,
        initialMirrorScope: MirrorScope?,
        allowUnscopedTestConstruction: Bool,
        syncStatusCenter: SyncStatusCenter?,
        bootstrapCandidate: MirrorBootstrapCandidate?,
        recoveryCandidate: MirrorRecoveryCandidate?
    ) throws {
        let containerID = "iCloud.app.simmersmith.cloud"
        let container = CKContainer(identifier: containerID)
        // Owner reads/writes its OWN private DB; a participant reaches the owner's zone
        // through the SHARED DB. (SP-C participant path — replaces the old TODO.)
        let database = role.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase

        // Owner: the deterministic zone in the user's private DB (mirrors
        // HouseholdZoneProvisioner.zoneName). Participant: the OWNER's zone, recovered
        // from CKShare metadata (its ownerName is the owner's record name, not ours).
        let zoneID: CKRecordZone.ID
        switch role {
        case .owner:
            let zoneName = HouseholdZoneProvisioner.zoneName(householdID: householdID)
            zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        case .participant(let sharedZoneID):
            zoneID = sharedZoneID
        }
        self.zoneID = zoneID
        self.role = role
        self.householdID = householdID
        self.syncStatusCenter = syncStatusCenter

        // Stable Application Support URL for the sync-engine state token so that
        // the token survives app launches (NOT a temp file — tokens must be durable).
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let syncDir = appSupport.appendingPathComponent("HouseholdSync", isDirectory: true)
        // Create the directory if missing (first launch).
        try? FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        // Per-scope state token: the owner (private) and a participant (shared) engine must
        // NEVER share a serialization blob, or the two scopes corrupt each other's token.
        let stateFileName = role.isOwner ? "engine-state.json" : "engine-state-shared.json"
        let stateURL = syncDir.appendingPathComponent(stateFileName)
        self.stateURL = stateURL
        let shadowMirrorRootURL = syncDir.appendingPathComponent(
            "shadow-mirror",
            isDirectory: true)
        self.shadowMirrorRootURL = shadowMirrorRootURL

        // simmersmith-r8q interim fix: the local store below is ALWAYS rebuilt fresh/empty
        // on every launch, but the sync-engine state token on disk persists — so a resumed
        // `fetchChanges` would return only deltas against a store that never had the base
        // data, silently leaving it partial forever. Discard this session's role-specific
        // state file so the engine we're about to construct starts from a nil token and
        // does a full zone re-fetch. Superseded once the store itself is persisted (bead e0a).
        HouseholdSyncEngine.clearPersistedState(at: stateURL)

        // Build the local store + engine with automaticSync enabled for production.
        // Construction mirrors CloudKitDebugView.runHouseholdSyncCheck (line 324) and
        // runMigrationCheck (line 940–944) exactly — same args, same merger composition.
        //
        // simmersmith-c7r: the merger is passed in at construction (not wired later by
        // `start()`) so it's non-nil the instant `automaticSync: true` lets CKSyncEngine
        // start delivering background `handleEvent` callbacks — closing the race where an
        // early remote change fell through to blanket LWW instead of `FieldMergeResolver`.
        let localStore = HouseholdLocalStore()
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: false)
        let merger = DispatchingMerger([
            GrocerySyncMerger(),
            EventGrocerySyncMerger(),
            EventSyncMerger(),
        ])
        let engine: HouseholdSyncEngine
        let cachedBootstrap: Bool
        let exactInitialScope = recoveryCandidate?.plan.scope
            ?? initialMirrorScope
            ?? bootstrapCandidate?.bootstrap.scope

        func makeNormalEngine() throws -> HouseholdSyncEngine {
            if let exactInitialScope {
                return try HouseholdSyncEngine(
                    database: database,
                    zoneID: zoneID,
                    store: localStore,
                    stateURL: stateURL,
                    automaticSync: true,
                    ownsZone: role.isOwner,
                    initialMirrorScope: exactInitialScope,
                    merger: merger,
                    shadowMirrorRootDirectory: shadowMirrorRootURL,
                    dataPlaneMode: .normal,
                    authority: authority)
            }
            // Test/debug compatibility only. Production AppState resolves and supplies the
            // current account-bound scope before constructing every HouseholdSession.
            guard allowUnscopedTestConstruction else {
                throw MirrorCheckpointError.scopeMismatch
            }
            return HouseholdSyncEngine(
                database: database,
                zoneID: zoneID,
                store: localStore,
                stateURL: stateURL,
                automaticSync: true,
                ownsZone: role.isOwner,
                merger: merger,
                shadowMirrorRootDirectory: shadowMirrorRootURL,
                dataPlaneMode: .normal,
                authority: authority)
        }

        if let bootstrapCandidate {
            do {
                let candidateEngine = try HouseholdSyncEngine(
                    database: database,
                    zoneID: zoneID,
                    store: localStore,
                    stateURL: stateURL,
                    automaticSync: true,
                    merger: merger,
                    bootstrapCandidate: bootstrapCandidate,
                    shadowMirrorRootDirectory: shadowMirrorRootURL,
                    dataPlaneMode: .cached,
                    authority: authority)
                switch try candidateEngine.activateBootstrapCandidate() {
                case .open:
                    engine = candidateEngine
                    cachedBootstrap = true
                case .discarded:
                    // Retain the frozen candidate long enough for HouseholdSession/AppState to
                    // drain its typed lifecycle event. Replacing it here would lose the event
                    // and construct a fresh unfenced automatic engine under stale authority.
                    engine = candidateEngine
                    cachedBootstrap = false
                case .rejected:
                    localStore.removeAll()
                    engine = try makeNormalEngine()
                    cachedBootstrap = false
                }
            } catch {
                localStore.removeAll()
                engine = try makeNormalEngine()
                cachedBootstrap = false
            }
        } else {
            engine = try makeNormalEngine()
            cachedBootstrap = false
        }
        self.store = localStore
        self.engine = engine
        self.isCachedBootstrap = cachedBootstrap
        self.isRecoveryOnly = recoveryCandidate != nil && !cachedBootstrap
        self.cachedInterventionCount = HouseholdSessionInterventionCountPolicy.resolve(
            cachedBootstrapActivated: cachedBootstrap,
            cachedCandidateCount: bootstrapCandidate?.bootstrap.interventionCount,
            recoveryCandidateCount: recoveryCandidate?.plan.interventionCount)
        self.recoveryCandidate = recoveryCandidate
        self.recoveryCandidateDisposition = recoveryCandidate == nil ? .released : .pending
        self.repairScheduler = RepairScheduler.householdRepairs(
            engine: engine, zoneID: zoneID, ownsZone: role.isOwner
        )

        // PUBLIC catalog reader (Phase 6 — read path only, no writes).
        // Construction mirrors CloudKitDebugView.runPublicCatalogCheck (line 1092).
        self.catalog = PublicCatalogReader(database: container.publicCloudDatabase)

        // Install all handlers atomically after every stored property exists. The engine keeps
        // construction-time automatic callbacks in order until this point; this session keeps
        // them again until AppState installs its authority dispatcher.
        engine.installEventHandlers(
            onStoreChanged: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.receiveEngineCallback(.storeChanged(
                        pendingCount: self.engine.pendingRecordChangeCount))
                }
            },
            onSyncError: { [weak self] failure in
                Task { @MainActor in
                    self?.receiveEngineCallback(.syncError(failure))
                }
            },
            onRecordSaved: { [weak self] recordName in
                Task { @MainActor in
                    self?.receiveEngineCallback(.recordSaved(recordName))
                }
            },
            onMirrorDurabilityFailure: { [weak self] failure in
                Task { @MainActor in
                    self?.receiveEngineCallback(.durabilityFailure(failure))
                }
            },
            onLifecycleEvent: { [lifecycleEventRelay, weak engine] event in
                // Scope capture is synchronous with the engine's already-completed fence. It
                // must happen before this callback crosses into a MainActor Task.
                let snapshot = HouseholdSessionLifecycleSnapshot(
                    event: event,
                    scope: engine?.activeMirrorScopeSnapshot)
                lifecycleEventRelay.submit(snapshot)
            })
    }

    private func receiveEngineCallback(_ event: EngineCallback) {
        // Preserve P1's pre-P2e behavior even before AppState installs an authority dispatcher:
        // observable store, repair, and status effects happen immediately and are never dropped.
        // Only authority events are buffered so cached boot can establish `.cachedReady` first.
        switch event {
        case .storeChanged(let pendingCount):
            storeRevision += 1
            repairScheduler.signal()
            // Preserve SyncStatusCenter's P1 boolean 0/1 contract. The authority reducer is
            // the only P2e consumer of the exact count.
            syncStatusCenter?.setPendingCount(pendingCount == 0 ? 0 : 1)
            if pendingCount == 0 {
                syncStatusCenter?.recordSyncSuccess(Date())
            }
            authorityEventBuffer.submit(.pending(count: pendingCount))
        case .syncError(let failure):
            syncStatusCenter?.recordFailure(failure)
            switch failure.kind {
            case .permanent:
                authorityEventBuffer.submit(.intervention(failure.message))
            case .transient:
                authorityEventBuffer.submit(.degraded(failure.message))
            }
        case .recordSaved(let recordName):
            syncStatusCenter?.recordSaveSucceeded(recordName: recordName)
        case .durabilityFailure(let failure):
            authorityEventBuffer.submit(.intervention(failure.message))
        }
    }

    // MARK: — Boot

    /// Provision the zone, wire the merger + change signal, do the first fetch, then
    /// set syncPhase. Must not crash if iCloud is unavailable — sets .offline on throw.
    func start() async {
        syncPhase = .loading  // AppState.SyncPhase.loading

        // P1 shadow capture is deliberately best-effort and never gates active-engine creation
        // or the first full fetch. A supplied cached/recovery writer is the continuity source;
        // a generic late identity task must never park or replace it with a pre-overlay runtime.
        if !isCachedBootstrap && !isRecoveryOnly {
            let shadowCaptureNonce = shadowCaptureNonce
            let shadowRole: MirrorRole = role.isOwner ? .owner : .participant
            let shadowZoneID = zoneID
            let shadowHouseholdID = householdID
            let shadowRootURL = shadowMirrorRootURL
            Task { @MainActor [weak self] in
                let accountRecordName = try? await HouseholdShareFlow().currentUserRecordName()
                guard let scope = ShadowMirrorScopeFactory.make(
                        accountRecordName: accountRecordName,
                        zoneID: shadowZoneID,
                        householdID: shadowHouseholdID,
                        role: shadowRole) else {
                    return
                }
                guard let self, self.shadowCaptureNonce == shadowCaptureNonce else { return }
                try? await self.engine.enableShadowMirror(scope: scope, rootDirectory: shadowRootURL)
            }
        }

        if isCachedBootstrap {
            // Cached household content is already materialized and activated. Do not ensure a
            // zone or fetch before repositories are wired; AppState starts reconciliation after
            // publishing the cached projection. Preserve the P1 SyncStatusCenter boot snapshot
            // even though this branch deliberately skips the full-fetch tail below.
            syncStatusCenter?.setPendingCount(engine.hasPendingRecordChanges ? 1 : 0)
            syncPhase = .loading
            return
        }

        // Gate-off/P1 preserves the original private-plane-before-household-fetch ordering.
        openPrivatePlane()
        do {
            // 1. Ensure the zone exists (idempotent) — OWNER ONLY. A participant does NOT
            //    own the zone (it lives in the owner's account, reached via the shared DB),
            //    so it must never provision/create it.
            if role.isOwner {
                let provisioner = HouseholdZoneProvisioner()
                try await provisioner.ensureHouseholdZone(householdID: householdID)
            }

            // 2. simmersmith-c7r: the merger + change-signal wiring that used to happen
            //    here now happens in `init` (before `automaticSync` can deliver any
            //    background event) — see the constructor for rationale. Both the owner's
            //    post-fetch/post-send events and the participant's boot-time fetches still
            //    route through that same `onStoreChanged` signal (see
            //    AppState+Sharing.adoptSharedZone, which calls session.start() then fetches
            //    again before repos are wired).

            // 3. Initial fetch to populate the local store from the server.
            try await engine.fetchChanges()
            if let recoveryCandidate {
                guard recoveryCandidateDisposition == .pending,
                      engine.dataPlaneResult(for: .save) != .notAuthoritative else {
                    throw HouseholdDataPlaneResult.notAuthoritative
                }
                do {
                    try engine.applyRecoveryPlan(recoveryCandidate.plan, writer: recoveryCandidate.writer)
                    recoveryCandidateDisposition = .applied
                    recoveryOnlyFetchSucceeded = true
                } catch {
                    guard recoveryCandidateDisposition == .pending,
                          engine.dataPlaneResult(for: .save) != .notAuthoritative else {
                        throw HouseholdDataPlaneResult.notAuthoritative
                    }
                    // Invalid durable payloads are corruption, unlike a transient fetch error.
                    recoveryCandidate.writer.quarantineAndReleaseGenerationLeaseSynchronously(
                        recoveryCandidate.plan.lease.id)
                    recoveryCandidateDisposition = .released
                    throw error
                }
            }
            guard engine.promoteSessionAuthority() || engine.hasSessionAuthority else {
                throw HouseholdDataPlaneResult.notAuthoritative
            }

            // simmersmith-vda: arm repairs only now — the fetch above RETURNED, so the store
            // holds the complete zone for this launch and a destructive pass can no longer
            // re-parent/delete against partially-fetched data. Crash-safety does NOT depend
            // on this timing: every explicit engine operation (this fetch, migration drains,
            // repair drains, repo drains) is serialized by the engine's AsyncSerialGate, so
            // an early repair pass would merely queue behind whatever is in flight. If this
            // fetch FAILS (offline boot), repairs stay dormant for the whole session —
            // deliberate: the store may then fill incrementally via automaticSync and is
            // never known-complete this launch; repair is opportunistic hygiene and runs on
            // the next healthy launch instead.
            if CachedHouseholdSystemOperationPolicy.allows(
                .repair,
                isAuthoritative: hasCurrentAuthority) {
                repairScheduler.activate()
            }
            syncPhase = .synced(Date())
            syncStatusCenter?.setPendingCount(engine.hasPendingRecordChanges ? 1 : 0)
            syncStatusCenter?.recordSyncSuccess(Date())
        } catch {
            if let recoveryCandidate, recoveryCandidateDisposition == .pending {
                // A transient full-fetch failure is not corruption. Preserve the exact durable
                // plan for the next retry; only release this session's lease/writer instance.
                recoveryCandidate.writer.releaseGenerationLeaseSynchronously(recoveryCandidate.plan.lease.id)
                recoveryCandidate.writer.fenceSynchronously()
                recoveryCandidateDisposition = .released
            }
            // iCloud unavailable, network error, etc. — degrade gracefully.
            syncPhase = .offline
        }
    }

    /// Open the independent per-user private plane. Cached household content never awaits this
    /// operation; callers may reload private repositories after checking their boot epoch.
    func openPrivatePlane() {
        guard privateContainer == nil else { return }
        do {
            privateContainer = try makeSimmerSmithPrivatePlaneContainer()
        } catch {
            privateContainer = nil
            print("[HouseholdSession] private plane container create failed: \(error)")
        }
    }

    /// Reconcile a cached candidate after its repositories and projections are visible.
    /// The caller owns epoch/session checks around this await.
    func reconcileCachedHousehold() async -> CachedHouseholdReconciliationOutcome {
        guard isCachedBootstrap else { return .failed }
        do {
            try await engine.fetchChanges()
            syncPhase = .synced(Date())
            return .succeeded(pendingCount: engine.pendingRecordChangeCount)
        } catch {
            syncPhase = .offline
            return .failed
        }
    }

    /// App-target regression seam for the teardown-safe lifecycle relay. Production events enter
    /// through the engine callback installed in `init`; tests use this to deterministically queue
    /// multiple already-emitted snapshots before MainActor drains the first one.
    func submitLifecycleSnapshotForTesting(
        _ event: HouseholdSyncLifecycleEvent,
        scope: MirrorScope?
    ) {
        lifecycleEventRelay.submit(HouseholdSessionLifecycleSnapshot(event: event, scope: scope))
    }

    // MARK: — Teardown

    private func releasePendingRecoveryCandidateForLifecycle() {
        guard let recoveryCandidate, recoveryCandidateDisposition == .pending else { return }
        // Lifecycle invalidation dominates recovery corruption handling. Release/fence the
        // un-applied candidate without quarantine so exact/root clear owns namespace removal.
        recoveryCandidate.writer.releaseGenerationLeaseSynchronously(
            recoveryCandidate.plan.lease.id)
        recoveryCandidate.writer.fenceSynchronously()
        recoveryCandidateDisposition = .released
    }

    /// Fence and durably retire cache state before a destructive server-side zone wipe starts.
    /// The full session/token teardown still happens after the remote operation completes.
    func invalidateShadowCacheForDestructiveReset() -> Bool {
        engine.clearShadowMirror()
    }

    /// Delete the durable sync-engine state token. Called on sign-out so a DIFFERENT
    /// household signed in on this device cannot inherit the prior household's sync
    /// token (which would mis-key the change feed against the new zone). The session
    /// object itself is released by AppState after this call; this only clears the
    /// on-disk token. Idempotent — no-op if the file is already gone.
    ///
    /// simmersmith-glw: also deactivates `repairScheduler` — this is a plain (non-async)
    /// `@MainActor` func and cannot `await` a pass draining, so it uses the sync
    /// `deactivate()` (gates future signals, cancels any not-yet-fired run, and requests
    /// abort of an in-flight one at its next sub-pass boundary) rather than blocking here.
    /// Without this, an in-flight destructive pass outlives teardown, still strongly
    /// retaining `engine`/`store` and issuing CKModifyRecords after this session is gone.
    func clearState() {
        revokeAuthority()
        discardDeferredSystemWork()
        shadowCaptureNonce = UUID()
        releasePendingRecoveryCandidateForLifecycle()
        _ = engine.clearShadowMirror()
        try? FileManager.default.removeItem(at: stateURL)
        repairScheduler.deactivate()
        engine.clearEventHandlers()
        authorityEventBuffer.clear()
    }

    /// The adoption-only counterpart to `detach()`. A participant successor may not construct
    /// until the owner scope's durable parked marker is safely written.
    @discardableResult
    func parkForOwnerToParticipantAdoption() -> Bool {
        revokeAuthority()
        discardDeferredSystemWork()
        shadowCaptureNonce = UUID()
        releasePendingRecoveryCandidateForLifecycle()
        let parked = engine.parkShadowMirrorForAdoption()
        repairScheduler.deactivate()
        engine.clearEventHandlers()
        authorityEventBuffer.clear()
        return parked
    }

    /// Quiesce the engine's change callback WITHOUT deleting the durable state token —
    /// used for stale construction cleanup and non-adoption handoffs: its sync token survives
    /// until the caller selects an explicit retirement path. ARC then releases the session.
    ///
    /// simmersmith-glw: also deactivates `repairScheduler` (see `clearState()`'s note — same
    /// sync/fire-and-forget-safe reasoning applies to the adopt-swap's detach call site).
    func detach() {
        revokeAuthority()
        discardDeferredSystemWork()
        shadowCaptureNonce = UUID()
        releasePendingRecoveryCandidateForLifecycle()
        engine.parkShadowMirror()
        repairScheduler.deactivate()
        engine.clearEventHandlers()
        authorityEventBuffer.clear()
    }
}
#endif
