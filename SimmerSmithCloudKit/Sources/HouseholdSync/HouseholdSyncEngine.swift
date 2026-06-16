#if canImport(CloudKit)
import CloudKit
import Foundation
import OSLog

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
    private let log = Logger(subsystem: "app.simmersmith.cloud", category: "HouseholdSync")

    private var syncEngine: CKSyncEngine!
    private var zoneEnsured = false

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
        automaticSync: Bool = false
    ) {
        self.database = database
        self.zoneID = zoneID
        self.store = store
        self.stateURL = stateURL

        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: Self.loadState(from: stateURL),
            delegate: self
        )
        configuration.automaticallySync = automaticSync
        self.syncEngine = CKSyncEngine(configuration)
    }

    // MARK: Public mutation API

    /// Stage a record save: write it locally, then tell the engine it's pending. The
    /// zone is created lazily on the first save.
    public func save(_ record: CKRecord) {
        store.setRecord(record)
        if !zoneEnsured {
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            zoneEnsured = true
        }
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    public func delete(_ recordID: CKRecord.ID) {
        store.removeRecord(recordID)
        syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
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

    /// Fetch remote changes then push local ones. Manual drive for deterministic tests;
    /// the app can also rely on `automaticallySync`.
    public func sync() async throws {
        try await syncEngine.fetchChanges()
        try await syncEngine.sendChanges()
    }

    public func fetchChanges() async throws { try await syncEngine.fetchChanges() }
    public func sendChanges() async throws { try await syncEngine.sendChanges() }

    /// True while record changes are still queued (e.g. a rebased save awaiting retry).
    public var hasPendingRecordChanges: Bool {
        !syncEngine.state.pendingRecordZoneChanges.isEmpty
    }

    /// Send repeatedly until nothing is pending (drains rebase-and-retry), capped.
    public func sendUntilDrained(maxPasses: Int = 4) async throws {
        for _ in 0..<maxPasses {
            try await syncEngine.sendChanges()
            if !hasPendingRecordChanges { return }
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
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            self.store.record(for: recordID)
        }
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.saveState(update.stateSerialization, to: stateURL)

        case .fetchedRecordZoneChanges(let changes):
            // Don't let an incoming fetch clobber a record we have an unsynced local
            // edit for — that edit must reach the server first (a genuine conflict then
            // surfaces as serverRecordChanged on send). Grocery/event field-merge will
            // hook this same skip point at Phase 4.
            let pendingSaves = pendingSaveIDs()
            for modification in changes.modifications {
                if pendingSaves.contains(modification.record.recordID) {
                    note("skip fetched mod (local pending) \(modification.record.recordID.recordName)")
                    continue
                }
                store.applyRemoteModification(modification.record)
                note("fetched mod \(modification.record.recordID.recordName)=\(modification.record["value"] as? String ?? "?")")
            }
            for deletion in changes.deletions {
                store.removeRecord(deletion.recordID)
                note("fetched del \(deletion.recordID.recordName)")
            }

        case .sentRecordZoneChanges(let sent):
            // Replace local copies with the server-authoritative records (updated
            // change tags) so the next edit bases on the right version.
            for saved in sent.savedRecords {
                store.setRecord(saved)
                note("saved \(saved.recordID.recordName)=\(saved["value"] as? String ?? "?")")
            }
            for failure in sent.failedRecordSaves {
                note("FAILED \(failure.record.recordID.recordName) code=\(failure.error.code.rawValue)")
                handleFailedSave(failure)
            }

        case .accountChange(let change):
            handleAccountChange(change)

        // Lifecycle / no-op for Phase 2a.
        case .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
             .fetchedDatabaseChanges, .sentDatabaseChanges,
             .willFetchRecordZoneChanges, .didFetchRecordZoneChanges:
            break

        @unknown default:
            break
        }
    }

    private func pendingSaveIDs() -> Set<CKRecord.ID> {
        var ids = Set<CKRecord.ID>()
        for change in syncEngine.state.pendingRecordZoneChanges {
            if case .saveRecord(let id) = change { ids.insert(id) }
        }
        return ids
    }

    // MARK: Conflict + failure handling

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        let recordID = failure.record.recordID
        switch failure.error.code {
        case .serverRecordChanged:
            // Our change tag is stale (a concurrent writer, or our first save's
            // server tag wasn't adopted yet). Standard CKSyncEngine resolution: rebase
            // our local field values onto the server record (which carries the current
            // tag) and re-enqueue the save so the retry matches. Plain records are LWW —
            // local fields win; grocery/event types swap in the field-merge at Phase 4.
            if let serverRecord = failure.error.serverRecord {
                if let local = store.record(for: recordID) {
                    for key in local.allKeys() { serverRecord[key] = local[key] }
                }
                store.setRecord(serverRecord)
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone and re-enqueue the save.
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        case .unknownItem:
            // The record vanished server-side; clear it locally.
            store.removeRecord(recordID)
        default:
            log.error("household save failed for \(recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signOut, .switchAccounts:
            // The local mirror belongs to the previous account — drop it.
            store.removeAll()
        case .signIn:
            break
        @unknown default:
            break
        }
    }

    // MARK: State persistence

    private static func loadState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func saveState(_ serialization: CKSyncEngine.State.Serialization, to url: URL) {
        guard let data = try? JSONEncoder().encode(serialization) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
#endif
