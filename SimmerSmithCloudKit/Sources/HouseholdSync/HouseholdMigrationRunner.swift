#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge

// SP-A Phase 7 — the one-time per-household Postgres→CloudKit import. Each export row is run
// through its pure transform (MigrationTransforms) and written to the household zone via the
// dedicated codecs through the CKSyncEngine. Idempotent: a `MigrationReceipt` record
// (`migrated:<scope>`) in the zone gates the whole import — a second run (or a second device
// that already synced the receipt) is a no-op, so the import is safe to re-trigger. Migrating
// the same scope twice can't duplicate rows because the transforms preserve PKs as recordNames
// (re-saving the same recordName is an upsert), AND the receipt short-circuits before any write.
public struct HouseholdMigrationRunner {
    public let engine: HouseholdSyncEngine
    public let zoneID: CKRecordZone.ID

    public init(engine: HouseholdSyncEngine, zoneID: CKRecordZone.ID) {
        self.engine = engine; self.zoneID = zoneID
    }

    /// A household's exported rows (decoded JSON), keyed by table. Extend as codecs land for
    /// the remaining types; today the codec-backed types are grocery + event-grocery.
    public struct Export {
        public var groceryItems: [[String: Any]]
        public var eventGroceryItems: [[String: Any]]
        public init(groceryItems: [[String: Any]] = [], eventGroceryItems: [[String: Any]] = []) {
            self.groceryItems = groceryItems; self.eventGroceryItems = eventGroceryItems
        }
    }

    public struct Result: Equatable {
        public var alreadyMigrated: Bool
        public var groceryCount: Int
        public var eventGroceryCount: Int
        public var skippedRows: Int   // rows that failed to transform (no PK) — logged, not fatal
    }

    public static let receiptType = "MigrationReceipt"
    public static func receiptRecordName(scope: String) -> String { "migrated:\(scope)" }

    /// Migrate `export` into the household zone under `scope`. Returns `alreadyMigrated=true`
    /// (and writes nothing) when the scope's receipt is already present locally.
    @discardableResult
    public func migrate(scope: String, export: Export) -> Result {
        let receiptID = CKRecord.ID(recordName: Self.receiptRecordName(scope: scope), zoneID: zoneID)
        if engine.store.record(for: receiptID) != nil {
            return Result(alreadyMigrated: true, groceryCount: 0, eventGroceryCount: 0, skippedRows: 0)
        }

        var grocery = 0, event = 0, skipped = 0
        for row in export.groceryItems {
            guard let item = migrateGroceryItem(row) else { skipped += 1; continue }
            engine.save(GroceryCodec.makeRecord(item, zoneID: zoneID))
            grocery += 1
        }
        for row in export.eventGroceryItems {
            guard let item = migrateEventGroceryItem(row) else { skipped += 1; continue }
            engine.save(EventGroceryCodec.makeRecord(item, zoneID: zoneID))
            event += 1
        }

        // Stamp the receipt LAST so a crash mid-import re-runs cleanly (no receipt → not skipped;
        // the PK-preserving upserts make the retry idempotent).
        let receipt = CKRecord(recordType: Self.receiptType, recordID: receiptID)
        receipt["scope"] = scope as CKRecordValue
        engine.save(receipt)
        return Result(alreadyMigrated: false, groceryCount: grocery, eventGroceryCount: event, skippedRows: skipped)
    }
}
#endif
