#if canImport(CloudKit)
import CloudKit
import Foundation

// SP-A Phase 9 — the migration-completeness signal SP-D (server retirement) depends on, CloudKit-
// native and PER-HOUSEHOLD. Because the server is being retired there is no central operator view:
// the per-household MigrationReceipt that HouseholdMigrationRunner writes in-zone IS the completeness
// signal. This thin, pure ledger reports the LOCAL household's status off the already-synced local
// store — no network. SP-D retires the server only once active households report `.complete`; dormant
// households (never launched the iOS-26 build) are held INDEFINITELY (never force-evicted — they keep
// working off their last-synced CloudKit state). See decisions.md 2026-06-17. Aggregate "X% of
// households migrated" reporting is out of scope in the server-retired end-state.
public struct MigrationLedger {

    public enum Status: Equatable { case notStarted, complete }

    /// The dormant-user policy: never force-evict a household that hasn't migrated. Modeled as an
    /// enum (single case today) so a future comms-then-sunset variant is an additive change, not a
    /// boolean flip scattered through call sites.
    public enum DormantUserPolicy: Equatable { case indefiniteHold }
    public static let dormantUserPolicy: DormantUserPolicy = .indefiniteHold

    public struct Report: Equatable {
        public var status: Status
        /// recordType → count currently in the household zone (the MigrationReceipt sentinel excluded).
        public var recordCounts: [String: Int]
        public var totalRecords: Int
        public init(status: Status, recordCounts: [String: Int], totalRecords: Int) {
            self.status = status; self.recordCounts = recordCounts; self.totalRecords = totalRecords
        }
    }

    public let zoneID: CKRecordZone.ID
    public init(zoneID: CKRecordZone.ID) { self.zoneID = zoneID }

    /// `.complete` iff the scope's MigrationReceipt is present locally — the SAME sentinel the
    /// runner's idempotency gate checks (written LAST, so records-without-receipt = a crashed import
    /// that re-runs cleanly, correctly reported `.notStarted`). Else `.notStarted`.
    public func status(scope: String, store: HouseholdLocalStore) -> Status {
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: scope), zoneID: zoneID)
        return store.record(for: receiptID) != nil ? .complete : .notStarted
    }

    /// Status + a per-recordType census of the household zone (the receipt sentinel is bookkeeping,
    /// not household data, so it's excluded from the counts).
    public func summary(scope: String, store: HouseholdLocalStore) -> Report {
        var counts: [String: Int] = [:]
        var total = 0
        for record in store.allRecords() where record.recordType != HouseholdMigrationRunner.receiptType {
            counts[record.recordType, default: 0] += 1
            total += 1
        }
        return Report(status: status(scope: scope, store: store), recordCounts: counts, totalRecords: total)
    }
}
#endif
