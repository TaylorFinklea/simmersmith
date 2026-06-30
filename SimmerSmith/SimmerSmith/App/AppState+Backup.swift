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
        var errorDescription: String? {
            switch self {
            case .noSession: return "Your household isn't loaded yet — try again in a moment."
            }
        }
    }

    private static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    static func backupsDirectory() throws -> URL {
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
            guard let type = HouseholdRecordType(rawValue: record.recordType) else { continue }
            values.append(HouseholdRecordCodec.decode(record, as: type))
        }
        return HouseholdBackup(
            capturedAt: Date(),
            appBuild: Self.appBuild,
            role: session.role.isOwner ? "owner" : "participant",
            records: values
        )
    }

    /// Write a snapshot to the on-device backups directory, then prune to the newest `keepLast`.
    /// Best-effort: an auto snapshot logs + swallows errors; a manual one surfaces them.
    @discardableResult
    func writeSnapshot(manual: Bool, keepLast: Int = 14) -> URL? {
        guard let backup = snapshotHousehold() else { return nil }
        do {
            let dir = try Self.backupsDirectory()
            let url = dir.appendingPathComponent(BackupFilePolicy.filename(for: backup.capturedAt))
            try BackupCodec.encode(backup).write(to: url, options: .atomic)
            pruneBackups(in: dir, keepLast: keepLast)
            print("[Backup] wrote \(url.lastPathComponent) (\(backup.records.count) records, manual=\(manual))")
            return url
        } catch {
            print("[Backup] write failed: \(error)")
            if manual { lastErrorMessage = "Couldn't create the backup: \(error.localizedDescription)" }
            return nil
        }
    }

    private func pruneBackups(in dir: URL, keepLast: Int) {
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
        syncPhase = .loading
        // Reconcile first so the upsert merges against current server state.
        try await session.engine.fetchChanges()
        for value in backup.records {
            session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }
        try await session.engine.sendUntilDrained()
        print("[Backup] restored \(backup.records.count) records from \(backup.capturedAt)")
        // Re-fetch + reload repos + re-mirror so the UI reflects the recovered data.
        await refreshHouseholdFromCloud()
    }

    /// Decode + restore a backup file (used by the in-app list and the Files importer).
    func restoreHousehold(fromFile url: URL) async throws {
        let data = try Data(contentsOf: url)
        let backup = try BackupCodec.decode(data)
        try await restoreHousehold(from: backup)
    }
}
#endif
