import Foundation

// SP-C backup/restore — the serializable snapshot of a household. A backup is just every
// record in the household zone, captured as the generic HouseholdRecordValue transport (the
// same primitive the codec uses for CKRecords), plus metadata. Restoring re-encodes these
// values to CKRecords and upserts them (additive recover — see AppState+Backup).

public struct HouseholdBackup: Codable, Equatable {
    /// Bumped if the on-disk shape changes incompatibly. Restore rejects a newer MAJOR.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let capturedAt: Date
    /// App build (CURRENT_PROJECT_VERSION) that captured the snapshot — for display + debugging.
    public let appBuild: String
    /// "owner" | "participant" — which side captured it (a participant snapshots the shared zone).
    public let role: String
    public let records: [HouseholdRecordValue]

    public init(capturedAt: Date, appBuild: String, role: String, records: [HouseholdRecordValue],
                schemaVersion: Int = HouseholdBackup.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.appBuild = appBuild
        self.role = role
        self.records = records
    }
}

public enum BackupCodec {
    public enum BackupError: Error, Equatable {
        case unsupportedSchema(Int)   // backup is from a newer, incompatible app
    }

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]   // stable bytes for testing / diffs
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public static func encode(_ backup: HouseholdBackup) throws -> Data {
        try makeEncoder().encode(backup)
    }

    /// Decode + validate the schema. A backup from a NEWER major schema is rejected (we can't
    /// safely interpret it); same-or-older is accepted.
    public static func decode(_ data: Data) throws -> HouseholdBackup {
        let backup = try makeDecoder().decode(HouseholdBackup.self, from: data)
        guard backup.schemaVersion <= HouseholdBackup.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(backup.schemaVersion)
        }
        return backup
    }
}
