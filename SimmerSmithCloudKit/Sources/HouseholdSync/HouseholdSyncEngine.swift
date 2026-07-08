#if canImport(CloudKit)
import CloudKit
import Foundation
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
        merger: RecordMerger? = nil
    ) {
        self.database = database
        self.zoneID = zoneID
        self.store = store
        self.stateURL = stateURL
        self.ownsZone = ownsZone
        // simmersmith-c7r: assign BEFORE `self.syncEngine` is constructed below. With
        // `automaticSync == true`, CKSyncEngine can deliver `handleEvent` on its own
        // background queue the instant it exists — if `merger` were still nil at that
        // point (previously set post-construction by `HouseholdSession.start()`), a
        // remote change could race in and fall through to blanket LWW instead of
        // `FieldMergeResolver`, corrupting sticky grocery/event fields.
        self.merger = merger

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
        // simmersmith-c7r: `save()` can be called concurrently from multiple threads (the
        // class isn't actor-isolated), so the check-and-set of `zoneEnsured` must be atomic
        // — otherwise two racing first-saves could both observe `false` and double-enqueue
        // `.saveZone`. Read-and-set under the lock; the enqueue itself stays outside it since
        // `syncEngine.state` needs no such guard (mirrors the existing `traceLock` pattern).
        zoneEnsuredLock.lock()
        let shouldEnsureZone = !zoneEnsured
        zoneEnsured = true
        zoneEnsuredLock.unlock()
        if shouldEnsureZone {
            // OWNER ONLY: lazily create the zone on first save. A participant writes into
            // the owner's already-existing shared zone and must never enqueue zone creation.
            if ownsZone {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            }
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
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { recordID in
            self.store.record(for: recordID)
        }
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            Self.saveState(update.stateSerialization, to: stateURL)

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
                    store.setRecord(result.record)
                    if result.needsResave {
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(result.record.recordID)])
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
                store.applyRemoteModification(remote)
                note("fetched mod \(remote.recordID.recordName)")
            }
            for deletion in changes.deletions {
                store.removeRecord(deletion.recordID)
                note("fetched del \(deletion.recordID.recordName)")
            }
            onStoreChanged?()

        case .sentRecordZoneChanges(let sent):
            // Replace local copies with the server-authoritative records (updated
            // change tags) so the next edit bases on the right version.
            for saved in sent.savedRecords {
                if Self.isShareRecord(saved) { continue }
                store.setRecord(saved)
                note("saved \(saved.recordID.recordName)=\(saved["value"] as? String ?? "?")")
            }
            for failure in sent.failedRecordSaves {
                note("FAILED \(failure.record.recordID.recordName) code=\(failure.error.code.rawValue)")
                handleFailedSave(failure)
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
                store.removeAll()
                onStoreChanged?()
                note("participant shared zone revoked \(zoneID.zoneName)")
            }

        // Lifecycle / no-op for Phase 2a.
        case .willFetchChanges, .didFetchChanges,
             .willSendChanges, .didSendChanges,
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

    private func handleFailedSave(_ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave) {
        let recordID = failure.record.recordID
        switch failure.error.code {
        case .serverRecordChanged:
            // Our change tag is stale (a concurrent writer, or our first save's server tag
            // wasn't adopted yet). Rebase onto the server record (which carries the current
            // tag) and re-enqueue so the retry matches. Sticky types field-merge here too —
            // a plain copy-local-over-server would clobber the other device's tombstone /
            // override / check-state; plain types use record-level `updatedAt` LWW instead of
            // blanket local-wins (simmersmith-6ce: blanket local-wins was a field-level lost
            // update whenever the local retry was actually the stale side).
            if let serverRecord = failure.error.serverRecord {
                if let merger, merger.handles(serverRecord.recordType) {
                    let result = merger.resolve(local: failure.record, remote: serverRecord)
                    store.setRecord(result.record)
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                } else if let local = store.record(for: recordID) {
                    let decision = Self.rebaseNonMergerRecord(local: local, server: serverRecord)
                    store.setRecord(decision.record)
                    if decision.reEnqueue {
                        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
                    }
                } else {
                    store.setRecord(serverRecord)
                }
            }
        case .zoneNotFound, .userDeletedZone:
            // Re-create the zone and re-enqueue the save — OWNER ONLY. A participant cannot
            // create the owner's zone; for it this means the share is gone, so do NOT try
            // (the .fetchedDatabaseChanges revocation path purges + recovers instead).
            if ownsZone {
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            }
        case .unknownItem:
            // The record vanished server-side; clear it locally.
            store.removeRecord(recordID)
        default:
            // simmersmith-dab: every other CKError family used to just log and drop the save —
            // a household edit failing with e.g. quotaExceeded/notAuthenticated/permissionFailure
            // never synced and the user was never told. Classify: retryable codes get re-enqueued
            // (CKSyncEngine applies its own backoff timing on re-enqueue — don't hand-roll one);
            // everything else — including any code we don't recognize — surfaces via `onSyncError`
            // instead of looping or vanishing silently.
            log.error("household save failed for \(recordID.recordName, privacy: .public): \(failure.error, privacy: .public)")
            let code = failure.error.code
            switch Self.classifyFailure(code) {
            case .transient:
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
            case .permanent:
                let syncFailure = SyncFailure(
                    recordName: recordID.recordName,
                    code: code,
                    kind: .permanent,
                    message: Self.userMessage(for: code)
                )
                onSyncError?(syncFailure)
            }
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

    /// Pure record-level LWW rebase for non-merger types at the `serverRecordChanged` seam
    /// (simmersmith-6ce). Every manifest record type carries an `updatedAt` date; compare it
    /// on `local` (our attempted, now-rejected save) vs. `server` (the current server record,
    /// which carries the fresh change tag) to decide who legitimately wins:
    /// - Both present, local strictly newer → LOCAL wins: rebase local's fields onto `server`
    ///   (adopting its tag) and ask for a re-save.
    /// - Both present, server newer-or-equal (ties go to the server, since it's already the
    ///   record of truth) → SERVER wins: keep `server` as-is and do NOT re-save our stale copy.
    /// - Either `updatedAt` missing → fall back to the historical blanket local-wins behavior
    ///   (copy local's keys onto `server`, re-save) since recency can't be judged.
    static func rebaseNonMergerRecord(local: CKRecord, server: CKRecord) -> (record: CKRecord, reEnqueue: Bool) {
        guard let localDate = local["updatedAt"] as? Date,
              let serverDate = server["updatedAt"] as? Date else {
            let rebased = server.copy() as! CKRecord
            for key in local.allKeys() { rebased[key] = local[key] }
            return (rebased, true)
        }
        if localDate > serverDate {
            let rebased = server.copy() as! CKRecord
            for key in local.allKeys() { rebased[key] = local[key] }
            return (rebased, true)
        }
        return (server.copy() as! CKRecord, false)
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

    /// simmersmith-dab: only log when a state file is PRESENT but unreadable/undecodable
    /// (corrupt state) — the missing-file case is normal (first launch, and every launch now
    /// that simmersmith-r8q deletes the state file) and must stay silent.
    private static let stateLog = Logger(subsystem: "app.simmersmith.cloud", category: "HouseholdSync")

    private static func loadState(from url: URL) -> CKSyncEngine.State.Serialization? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } catch {
            stateLog.error("failed to load persisted sync state at \(url.path, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

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
