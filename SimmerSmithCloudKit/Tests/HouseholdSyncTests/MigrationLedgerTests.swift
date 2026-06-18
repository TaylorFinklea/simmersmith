import Foundation
import Testing
import CloudKit
@testable import HouseholdSync

// SP-A Phase 9 — the per-household migration-completeness signal. Pure (reads the in-memory store),
// so it's fully headless: status is gated on the MigrationReceipt sentinel; summary censuses the zone.

@Test func migrationLedgerReportsStatusAndCensus() {
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let store = HouseholdLocalStore()
    let ledger = MigrationLedger(zoneID: zoneID)
    let scope = "hh"
    func add(_ type: String, _ name: String) {
        store.setRecord(CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID)))
    }

    // No receipt → notStarted, even with household data present (a crashed import re-runs cleanly).
    #expect(ledger.status(scope: scope, store: store) == .notStarted)
    add("GroceryItem", "G1"); add("GroceryItem", "G2"); add("Recipe", "R1")
    #expect(ledger.status(scope: scope, store: store) == .notStarted)

    // Receipt written → complete; the census counts data and EXCLUDES the receipt sentinel.
    add(HouseholdMigrationRunner.receiptType, HouseholdMigrationRunner.receiptRecordName(scope: scope))
    let report = ledger.summary(scope: scope, store: store)
    #expect(report.status == .complete)
    #expect(report.recordCounts["GroceryItem"] == 2 && report.recordCounts["Recipe"] == 1)
    #expect(report.recordCounts[HouseholdMigrationRunner.receiptType] == nil)
    #expect(report.totalRecords == 3)
    #expect(MigrationLedger.dormantUserPolicy == .indefiniteHold)

    // A different scope's receipt is independent.
    #expect(ledger.status(scope: "other", store: store) == .notStarted)
}
