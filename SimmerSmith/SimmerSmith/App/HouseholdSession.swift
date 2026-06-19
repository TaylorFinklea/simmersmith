#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
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
}
#endif
