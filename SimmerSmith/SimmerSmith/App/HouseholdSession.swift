#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SwiftData
import SimmerSmithKit
import CloudKitProvisioning
import HouseholdSync

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
    private let shadowMirrorRootURL: URL
    /// Invalidated by clear/detach so a late account-identity callback cannot re-enable an old
    /// writer after this session has been torn down or parked for adoption.
    private var shadowCaptureNonce = UUID()

    // MARK: — Observable state

    /// Mirrors the sync-engine lifecycle; repositories and UI observe this.
    var syncPhase: AppState.SyncPhase = .idle

    /// Bumped after every remote change batch or authoritative server write so that
    /// @Observable consumers (repositories, views) know to re-read the store.
    var storeRevision: Int = 0

    // MARK: — Init

    init(householdID: String, role: HouseholdSessionRole = .owner, syncStatusCenter: SyncStatusCenter? = nil) {
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
        self.shadowMirrorRootURL = syncDir.appendingPathComponent("shadow-mirror", isDirectory: true)

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
        let store = HouseholdLocalStore()
        let engine = HouseholdSyncEngine(
            database: database,
            zoneID: zoneID,
            store: store,
            stateURL: stateURL,
            automaticSync: true,
            ownsZone: role.isOwner,
            merger: DispatchingMerger([
                GrocerySyncMerger(),
                EventGrocerySyncMerger(),
                EventSyncMerger(),
            ]),
            shadowMirrorRootDirectory: shadowMirrorRootURL
        )
        self.store = store
        self.engine = engine
        self.repairScheduler = RepairScheduler.householdRepairs(
            engine: engine, zoneID: zoneID, ownsZone: role.isOwner
        )

        // PUBLIC catalog reader (Phase 6 — read path only, no writes).
        // Construction mirrors CloudKitDebugView.runPublicCatalogCheck (line 1092).
        self.catalog = PublicCatalogReader(database: container.publicCloudDatabase)

        // simmersmith-c7r: wired LAST — after every stored property has a value — since
        // capturing `self` in a closure (even weakly) requires `self` to be fully
        // initialized first. Closes the same background-delivery race as the merger: the
        // closure exists before `start()` runs, so an automatic-sync event that fires
        // before `start()` still has a live signal to call.
        engine.onStoreChanged = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.storeRevision += 1
                self.repairScheduler.signal()
                // simmersmith-qrt: piggyback the sync-status feed on the same per-event
                // signal — no new engine API. Pending count is the boolean
                // `hasPendingRecordChanges` (0/1, per spec); no pending work left after
                // this batch is treated as a success tick.
                let pendingCount = self.engine.hasPendingRecordChanges ? 1 : 0
                self.syncStatusCenter?.setPendingCount(pendingCount)
                if pendingCount == 0 {
                    self.syncStatusCenter?.recordSyncSuccess(Date())
                }
            }
        }
        // simmersmith-qrt: wired alongside `onStoreChanged` above (same "must be non-nil
        // before automaticSync can deliver a background event" rationale as the merger —
        // see the simmersmith-c7r note on `merger` earlier in this initializer). Nil'd
        // wherever `onStoreChanged` is nil'd (see `clearState()`/`detach()` below).
        engine.onSyncError = { [weak self] failure in
            Task { @MainActor in
                self?.syncStatusCenter?.recordFailure(failure)
            }
        }
        // simmersmith-ioj: a permanent failure (see `recordFailure` above) persists across
        // clean sync ticks by design — its only clear path is the SAME record later saving
        // successfully. Wired alongside `onStoreChanged`/`onSyncError` for the same reason
        // (must be non-nil before automaticSync can deliver a background event); nil'd
        // wherever those are nil'd below.
        engine.onRecordSaved = { [weak self] recordName in
            Task { @MainActor in
                self?.syncStatusCenter?.recordSaveSucceeded(recordName: recordName)
            }
        }
    }

    // MARK: — Boot

    /// Provision the zone, wire the merger + change signal, do the first fetch, then
    /// set syncPhase. Must not crash if iCloud is unavailable — sets .offline on throw.
    func start() async {
        syncPhase = .loading  // AppState.SyncPhase.loading

        // P1 shadow capture is deliberately best-effort and never gates active-engine creation
        // or the first full fetch. If CloudKit cannot immediately resolve an account identity,
        // this session simply remains shadow-disabled; no persisted cache reaches the live store.
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

        // 0. Boot the per-user PRIVATE plane (NSPCKC). Independent of the household
        //    CKSyncEngine boot below — a failure here (or there) must not take the other
        //    down. Construction can throw if iCloud is unavailable or the store fails to
        //    open; on throw we leave `privateContainer` nil and the household plane still
        //    works. NSPCKC then syncs automatically once it's created (no fetch kick here).
        do {
            privateContainer = try makeSimmerSmithPrivatePlaneContainer()
        } catch {
            privateContainer = nil
            print("[HouseholdSession] private plane container create failed: \(error)")
        }

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
            repairScheduler.activate()
            syncPhase = .synced(Date())
            syncStatusCenter?.setPendingCount(engine.hasPendingRecordChanges ? 1 : 0)
            syncStatusCenter?.recordSyncSuccess(Date())
        } catch {
            // iCloud unavailable, network error, etc. — degrade gracefully.
            syncPhase = .offline
        }
    }

    // MARK: — Teardown

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
        shadowCaptureNonce = UUID()
        engine.clearShadowMirror()
        try? FileManager.default.removeItem(at: stateURL)
        repairScheduler.deactivate()
        engine.onStoreChanged = nil
        engine.onSyncError = nil
        engine.onRecordSaved = nil
    }

    /// Quiesce the engine's change callback WITHOUT deleting the durable state token —
    /// used when swapping an owner session out for a participant (adopt): the parked owner
    /// zone + its sync token must survive for a future un-adopt. ARC then releases the session.
    ///
    /// simmersmith-glw: also deactivates `repairScheduler` (see `clearState()`'s note — same
    /// sync/fire-and-forget-safe reasoning applies to the adopt-swap's detach call site).
    func detach() {
        shadowCaptureNonce = UUID()
        engine.parkShadowMirror()
        repairScheduler.deactivate()
        engine.onStoreChanged = nil
        engine.onSyncError = nil
        engine.onRecordSaved = nil
    }
}
#endif
