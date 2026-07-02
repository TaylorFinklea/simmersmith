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

    // MARK: — Observable state

    /// Mirrors the sync-engine lifecycle; repositories and UI observe this.
    var syncPhase: AppState.SyncPhase = .idle

    /// Bumped after every remote change batch or authoritative server write so that
    /// @Observable consumers (repositories, views) know to re-read the store.
    var storeRevision: Int = 0

    // MARK: — Init

    init(householdID: String, role: HouseholdSessionRole = .owner) {
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
            ])
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
                self?.storeRevision += 1
                self?.repairScheduler.signal()
            }
        }
    }

    // MARK: — Boot

    /// Provision the zone, wire the merger + change signal, do the first fetch, then
    /// set syncPhase. Must not crash if iCloud is unavailable — sets .offline on throw.
    func start() async {
        syncPhase = .loading  // AppState.SyncPhase.loading

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

            syncPhase = .synced(Date())
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
    func clearState() {
        try? FileManager.default.removeItem(at: stateURL)
        engine.onStoreChanged = nil
    }

    /// Quiesce the engine's change callback WITHOUT deleting the durable state token —
    /// used when swapping an owner session out for a participant (adopt): the parked owner
    /// zone + its sync token must survive for a future un-adopt. ARC then releases the session.
    func detach() {
        engine.onStoreChanged = nil
    }
}
#endif
