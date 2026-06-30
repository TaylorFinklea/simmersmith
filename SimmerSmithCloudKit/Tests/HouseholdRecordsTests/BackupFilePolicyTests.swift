import Foundation
import Testing
@testable import HouseholdRecords

// SP-C backup/restore T2 — the retention policy (keep the newest N) + filename↔date round-trip.

@Test("filename round-trips to a date (second precision)")
func filenameRoundTrip() {
    let date = Date(timeIntervalSince1970: 1_750_000_000)
    let name = BackupFilePolicy.filename(for: date)
    #expect(name.hasPrefix("backup-"))
    #expect(name.hasSuffix(".json"))
    let parsed = BackupFilePolicy.date(fromFilename: name)
    // Round-trips to the same second.
    #expect(parsed.map { Int($0.timeIntervalSince1970) } == Int(date.timeIntervalSince1970))
}

@Test("date(fromFilename:) rejects non-backup names")
func rejectsForeignNames() {
    #expect(BackupFilePolicy.date(fromFilename: "engine-state.json") == nil)
    #expect(BackupFilePolicy.date(fromFilename: "backup-nope.json") == nil)
    #expect(BackupFilePolicy.date(fromFilename: "backup-20260101-120000.txt") == nil)
}

@Test("toPrune keeps the newest N, deletes the rest")
func prunesOldest() {
    // 16 names; keepLast 14 → the 2 oldest are pruned.
    let names = (1...16).map { String(format: "backup-202601%02d-120000.json", $0) }
    let prune = BackupFilePolicy.toPrune(names, keepLast: 14)
    #expect(prune.count == 2)
    #expect(prune.contains("backup-20260101-120000.json"))   // oldest
    #expect(prune.contains("backup-20260102-120000.json"))
    #expect(!prune.contains("backup-20260116-120000.json"))  // newest kept
}

@Test("toPrune is a no-op when at or under the limit; ignores foreign files")
func pruneNoOp() {
    let names = ["backup-20260101-120000.json", "backup-20260102-120000.json", "engine-state.json"]
    #expect(BackupFilePolicy.toPrune(names, keepLast: 14).isEmpty)
    // foreign files are never selected for pruning
    #expect(!BackupFilePolicy.toPrune(names, keepLast: 0).contains("engine-state.json"))
}
