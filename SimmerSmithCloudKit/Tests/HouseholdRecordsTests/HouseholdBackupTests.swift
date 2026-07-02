import Foundation
import Testing
@testable import HouseholdRecords

// SP-C backup/restore T1 — the snapshot serialization is the load-bearing core: a backup must
// round-trip every scalar kind + refs losslessly (a Date must stay a Date, not become a string
// or double), and a newer-schema file must be rejected rather than mis-read.

private func roundTrip(_ scalar: ScalarValue) throws -> ScalarValue {
    let data = try BackupCodec.makeEncoder().encode(scalar)
    return try BackupCodec.makeDecoder().decode(ScalarValue.self, from: data)
}

@Test("ScalarValue round-trips every kind, preserving type")
func scalarRoundTrip() throws {
    let date = Date(timeIntervalSince1970: 1_750_000_000)  // fixed instant
    #expect(try roundTrip(.string("taco night")) == .string("taco night"))
    #expect(try roundTrip(.int(42)) == .int(42))
    #expect(try roundTrip(.double(3.5)) == .double(3.5))
    #expect(try roundTrip(.bool(true)) == .bool(true))
    #expect(try roundTrip(.date(date)) == .date(date))
    // A bool must NOT collapse into an int, nor a date into a double.
    #expect(try roundTrip(.bool(false)) != .int(0))
}

@Test("HouseholdRecordValue round-trips scalars + refs")
func recordValueRoundTrip() throws {
    let value = HouseholdRecordValue(
        type: .weekMeal,
        recordName: "meal-123",
        scalars: [
            "slot": .string("dinner"),
            "approved": .bool(true),
            "servings": .double(4),
            "mealDate": .date(Date(timeIntervalSince1970: 1_750_100_000)),
        ],
        refs: ["week": "week-abc", "recipe": "recipe-xyz"]
    )
    let data = try BackupCodec.makeEncoder().encode(value)
    let decoded = try BackupCodec.makeDecoder().decode(HouseholdRecordValue.self, from: data)
    #expect(decoded == value)
}

@Test("HouseholdBackup encode → decode equals the input")
func backupRoundTrip() throws {
    let backup = HouseholdBackup(
        capturedAt: Date(timeIntervalSince1970: 1_750_200_000),
        appBuild: "144",
        role: "owner",
        records: [
            HouseholdRecordValue(type: .recipe, recordName: "r1", scalars: ["name": .string("Tacos")]),
            HouseholdRecordValue(type: .week, recordName: "w1", scalars: ["weekStart": .date(Date(timeIntervalSince1970: 1_750_000_000))]),
        ]
    )
    let data = try BackupCodec.encode(backup)
    let decoded = try BackupCodec.decode(data)
    #expect(decoded == backup)
    #expect(decoded.schemaVersion == HouseholdBackup.currentSchemaVersion)
}

@Test("decode rejects a backup from a newer, incompatible schema")
func rejectsNewerSchema() throws {
    let future = HouseholdBackup(
        capturedAt: Date(timeIntervalSince1970: 1_750_200_000),
        appBuild: "999", role: "owner", records: [],
        schemaVersion: HouseholdBackup.currentSchemaVersion + 1
    )
    let data = try BackupCodec.makeEncoder().encode(future)
    #expect(throws: BackupCodec.BackupError.self) {
        _ = try BackupCodec.decode(data)
    }
}

// SP-C simmersmith-9i6 — restoreHousehold's later-wins guard for plain (non-merger) record
// types: a backup must never revert an edit made to the live record since the snapshot was
// taken. `shouldApplyBackupValue` is the pure decision extracted from
// AppState+Backup.restoreHousehold so it's host-testable without a CloudKit session.

private let reference = Date(timeIntervalSince1970: 1_750_200_000)

@Test("applies when the live record has never synced (no modification date)")
func shouldApplyWhenLiveNeverSynced() {
    #expect(shouldApplyBackupValue(liveModified: nil, capturedAt: reference))
    #expect(shouldApplyBackupValue(liveModified: nil, capturedAt: nil))
}

@Test("applies when the backup carries no capture time (legacy fallback)")
func shouldApplyWhenCapturedAtMissing() {
    #expect(shouldApplyBackupValue(liveModified: reference, capturedAt: nil))
}

@Test("applies when the live record is at or before the backup's capture time")
func shouldApplyWhenLiveNotNewer() {
    #expect(shouldApplyBackupValue(liveModified: reference, capturedAt: reference))
    #expect(shouldApplyBackupValue(liveModified: reference.addingTimeInterval(-60), capturedAt: reference))
}

@Test("skips when the live record was modified after the backup was captured")
func skipsWhenLiveIsNewer() {
    #expect(!shouldApplyBackupValue(liveModified: reference.addingTimeInterval(60), capturedAt: reference))
}
