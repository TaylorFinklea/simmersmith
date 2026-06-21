#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SwiftData
import SimmerSmithKit
import CloudKitProvisioning
import HouseholdSync

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
    private let householdID: String

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
    var privateStore: PrivatePlaneStore? {
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

    init(householdID: String) {
        let containerID = "iCloud.app.simmersmith.cloud"
        let container = CKContainer(identifier: containerID)
        let database = container.privateCloudDatabase
        // TODO(SP-C participant): shared-DB join via CKShare — the participant path
        // would use container.sharedCloudDatabase and a different zoneID.

        // Derive the deterministic zone name for this household (mirrors
        // HouseholdZoneProvisioner.zoneName(householdID:)).
        let zoneName = HouseholdZoneProvisioner.zoneName(householdID: householdID)
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        self.zoneID = zoneID
        self.householdID = householdID

        // Stable Application Support URL for the sync-engine state token so that
        // the token survives app launches (NOT a temp file — tokens must be durable).
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let syncDir = appSupport.appendingPathComponent("HouseholdSync", isDirectory: true)
        // Create the directory if missing (first launch).
        try? FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let stateURL = syncDir.appendingPathComponent("engine-state.json")
        self.stateURL = stateURL

        // Build the local store + engine with automaticSync enabled for production.
        // Construction mirrors CloudKitDebugView.runHouseholdSyncCheck (line 324) and
        // runMigrationCheck (line 940–944) exactly — same args, same merger composition.
        let store = HouseholdLocalStore()
        let engine = HouseholdSyncEngine(
            database: database,
            zoneID: zoneID,
            store: store,
            stateURL: stateURL,
            automaticSync: true
        )
        self.store = store
        self.engine = engine

        // PUBLIC catalog reader (Phase 6 — read path only, no writes).
        // Construction mirrors CloudKitDebugView.runPublicCatalogCheck (line 1092).
        self.catalog = PublicCatalogReader(database: container.publicCloudDatabase)
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
            // 1. Ensure the zone exists (idempotent — safe to call every launch).
            let provisioner = HouseholdZoneProvisioner()
            try await provisioner.ensureHouseholdZone(householdID: householdID)

            // 2. Wire the full merger stack (mirrors runEventGroceryMergeCheck line 611–614
            //    and runMigrationCheck lines 942–945 in CloudKitDebugView).
            engine.merger = DispatchingMerger([
                GrocerySyncMerger(),
                EventGrocerySyncMerger(),
                EventSyncMerger(),
            ])

            // 3. Wire the change signal so @Observable consumers refresh.
            engine.onStoreChanged = { [weak self] in
                Task { @MainActor in self?.storeRevision += 1 }
            }

            // 4. Initial fetch to populate the local store from the server.
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
}
#endif
