#if canImport(CloudKit)
import Foundation
import CloudKit
import CloudKitProvisioning
import HouseholdSync
import HouseholdRecords

// SP-C backup/restore — snapshot the whole household zone to JSON (on-device, rolling), and
// RECOVER from a snapshot (additive upsert — never deletes newer data). Spec:
// .docs/ai/phases/backup-restore-spec.md. Serialization lives in HouseholdRecords; this is the
// store/file I/O + the CloudKit write-back.
extension AppState {

    struct BackupFile: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        let capturedAt: Date
        let byteSize: Int
    }

    enum BackupRestoreError: LocalizedError {
        case noSession
        case cachedBootstrapDenied
        var errorDescription: String? {
            switch self {
            case .noSession: return "Your household isn't loaded yet — try again in a moment."
            case .cachedBootstrapDenied:
                return "Finish household reconciliation before restoring a backup."
            }
        }
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    // nonisolated: pure FileManager work, called from both the synchronous manual path and the
    // detached auto-snapshot task.
    nonisolated static func backupsDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("SimmerSmithBackups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Snapshot

    /// Capture every household-zone record as a serializable backup. Records whose type isn't a
    /// known HouseholdRecordType (migration receipts, share records) are skipped.
    func snapshotHousehold() -> HouseholdBackup? {
        guard let session = householdSession else { return nil }
        var values: [HouseholdRecordValue] = []
        for record in session.store.allRecords() {
            guard let type = HouseholdRecordType(recordTypeName: record.recordType) else { continue }
            values.append(HouseholdRecordCodec.decode(record, as: type))
        }
        return HouseholdBackup(
            capturedAt: Date(),
            appBuild: Self.appBuild,
            role: session.role.isOwner ? "owner" : "participant",
            records: values
        )
    }

    /// Encode + atomically write a snapshot, then prune to the newest `keepLast`. Pure file I/O,
    /// nonisolated so it can run off the main actor (the auto path runs this in a detached task;
    /// the manual path calls it synchronously, same thread, no actor hop).
    @discardableResult
    nonisolated static func writeBackupFile(_ backup: HouseholdBackup, keepLast: Int) throws -> URL {
        let dir = try backupsDirectory()
        let url = dir.appendingPathComponent(BackupFilePolicy.filename(for: backup.capturedAt))
        try BackupCodec.encode(backup).write(to: url, options: .atomic)
        pruneBackups(in: dir, keepLast: keepLast)
        return url
    }

    /// Write a snapshot to the on-device backups directory, then prune to the newest `keepLast`.
    /// Best-effort: an auto snapshot logs + swallows errors; a manual one surfaces them.
    @discardableResult
    func writeSnapshot(manual: Bool, keepLast: Int = 14) -> URL? {
        guard let backup = snapshotHousehold() else { return nil }
        do {
            let url = try Self.writeBackupFile(backup, keepLast: keepLast)
            print("[Backup] wrote \(url.lastPathComponent) (\(backup.records.count) records, manual=\(manual))")
            return url
        } catch {
            print("[Backup] write failed: \(error)")
            if manual { lastErrorMessage = "Couldn't create the backup: \(error.localizedDescription)" }
            return nil
        }
    }

    nonisolated private static let lastAutoSnapshotDayKey = "backup.lastAutoSnapshotDay.v1"

    /// Take an automatic snapshot at most once per calendar day (called on launch after the
    /// household loads). The rolling 14-deep history is the real protection: even if a build
    /// damages data, a prior day's snapshot — captured while the data was intact — is restorable.
    /// The snapshot read (touches session.store) stays on the main actor; the encode + write +
    /// prune is fire-and-forget background I/O, detached so it doesn't inherit @MainActor.
    func maybeAutoSnapshot() {
        guard householdSession != nil else { return }
        let today = Self.dayKey(Date())
        guard UserDefaults.standard.string(forKey: Self.lastAutoSnapshotDayKey) != today else { return }
        guard let backup = snapshotHousehold() else { return }
        Task.detached(priority: .utility) {
            do {
                let url = try Self.writeBackupFile(backup, keepLast: 14)
                print("[Backup] wrote \(url.lastPathComponent) (\(backup.records.count) records, manual=false)")
                UserDefaults.standard.set(today, forKey: Self.lastAutoSnapshotDayKey)
            } catch {
                print("[Backup] write failed: \(error)")
            }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }

    nonisolated private static func pruneBackups(in dir: URL, keepLast: Int) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in BackupFilePolicy.toPrune(names, keepLast: keepLast) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    func listBackups() -> [BackupFile] {
        guard let dir = try? Self.backupsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return urls.compactMap { url -> BackupFile? in
            guard let date = BackupFilePolicy.date(fromFilename: url.lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return BackupFile(url: url, capturedAt: date, byteSize: size)
        }
        .sorted { $0.capturedAt > $1.capturedAt }
    }

    func deleteBackup(_ file: BackupFile) {
        try? FileManager.default.removeItem(at: file.url)
    }

    // MARK: - Restore (RECOVER — additive upsert; never deletes newer data)

    /// Recover from a snapshot: reconcile with the server, then UPSERT every record from the
    /// backup (re-adds anything deleted, overwrites anything changed) and push. Records present
    /// now but absent from the backup are LEFT ALONE — restoring can only bring data back.
    func restoreHousehold(from backup: HouseholdBackup) async throws {
        guard let session = householdSession else { throw BackupRestoreError.noSession }
        guard CachedHouseholdSystemOperationPolicy.allows(
            .backupRestore,
            isCachedBootstrap: session.isCachedBootstrap) else {
            throw BackupRestoreError.cachedBootstrapDenied
        }
        syncPhase = .loading
        // Reconcile first so the upsert merges against current server state.
        try await session.engine.fetchChanges()
        // Drain any LOCAL edit still queued from before this restore started. CKRecord's
        // `modificationDate` is server-set and only updates once a save round-trips through
        // CloudKit, so a record with a pending-but-unsent edit still reports its stale
        // pre-edit modificationDate — which would fool the later-wins guard below into
        // thinking the backup is newer and overwriting a genuinely newer local edit. Draining
        // BEFORE the loop (instead of only after, as before) lets a successful send refresh
        // that record's modificationDate first, so the guard sees the true modification time.
        // (This can't help while offline — nothing can be pushed — but closes the common
        // online-but-not-yet-synced window.)
        try await session.engine.sendUntilDrained(maxPasses: 30)
        let merger = session.engine.merger
        for value in backup.records {
            let id = CKRecord.ID(recordName: value.recordName, zoneID: session.zoneID)
            if let existing = session.store.record(for: id) {
                // Collaborative merged types (grocery check-state, event quantities): NEVER
                // overwrite a live record — restoring an old value would clobber a household
                // member's newer edit (the field-merger normally guards this; preserving the
                // change tag bypasses it). A DELETED one is still re-added in the else branch.
                if merger?.handles(value.type.recordTypeName) == true { continue }
                // Plain (non-merger) types have no field-level merge guard of their own, so apply
                // the same later-wins rule directly: skip if the live record was modified more
                // recently than this backup was captured (an edit since the snapshot would
                // otherwise be reverted household-wide).
                guard shouldApplyBackupValue(
                    liveModified: existing.modificationDate, capturedAt: backup.capturedAt
                ) else { continue }
                // Overwrite the live record IN PLACE — preserves its change tag so the save
                // doesn't conflict with the server copy.
                HouseholdRecordCodec.apply(value, onto: existing, zoneID: session.zoneID)
                session.engine.save(existing)
            } else {
                // Re-create a deleted record from scratch.
                session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
            }
        }
        try await session.engine.sendUntilDrained(maxPasses: 30)
        if session.engine.hasPendingRecordChanges {
            // Records are saved locally + queued; background sync will finish the push.
            print("[Backup] restore still draining after 30 passes — background sync will finish")
        }
        print("[Backup] restored \(backup.records.count) records from \(backup.capturedAt)")
        // Reload from the LOCAL store (which now holds the recovered records) + re-mirror — NO
        // network fetch, which could pull the just-deleted server state back over the re-adds
        // before the push settles. The push syncs to CloudKit in the background.
        reloadAndMirrorHousehold()
        syncPhase = .synced(.now)
    }

    /// Decode + restore a backup file (used by the in-app list and the Files importer).
    func restoreHousehold(fromFile url: URL) async throws {
        let data = try Data(contentsOf: url)
        let backup = try BackupCodec.decode(data)
        try await restoreHousehold(from: backup)
    }
}
#endif
