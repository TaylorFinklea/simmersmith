import Testing

@testable import SimmerSmith

/// Bead simmersmith-91e — WeekMigrationLoader/EventMigrationLoader fetch per-item detail
/// inside a task group using `try?` (silently dropping failures), and PantryProfileMigrationLoader
/// `try?`-swallows every per-item private-plane upsert; all three then stamped their
/// completion receipt unconditionally. One transient blip permanently lost that item, since
/// the receipt gates every future retry. Each loader now gates its receipt stamp behind a
/// count-based completeness check (mirrors RecipeMigrationLoader's RECEIPT-BLOCKING RULE).
///
/// These tests pin the three completeness-check helpers directly. A real HouseholdSession
/// can't be driven end-to-end headlessly here — constructing a live CKContainer needs an
/// iCloud entitlement/XPC session (see MergerWiringOrderTests/ShareRecordFilterTests/
/// RepairSchedulerTests in SimmerSmithCloudKit's test target for this repo's established
/// "can't reproduce headlessly" convention) — so this pins the exact decision the
/// receipt-stamp guard in each loader is gated on instead.
struct MigrationReceiptCompletenessTests {
    @Test
    func weekMigrationWithholdsReceiptWhenOneOfNDropped() {
        #expect(weekMigrationIsComplete(expectedCount: 3, fetchedCount: 2) == false)
    }

    @Test
    func weekMigrationStampsReceiptWhenFullyFetched() {
        #expect(weekMigrationIsComplete(expectedCount: 3, fetchedCount: 3) == true)
    }

    @Test
    func eventMigrationWithholdsReceiptWhenOneOfNDropped() {
        #expect(eventMigrationIsComplete(expectedCount: 5, fetchedCount: 4) == false)
    }

    @Test
    func eventMigrationStampsReceiptWhenFullyFetched() {
        #expect(eventMigrationIsComplete(expectedCount: 5, fetchedCount: 5) == true)
    }

    @Test
    func pantryProfileMigrationWithholdsReceiptWhenAnyUpsertDropped() {
        #expect(pantryProfileMigrationIsComplete(droppedCount: 1) == false)
    }

    @Test
    func pantryProfileMigrationStampsReceiptWhenNothingDropped() {
        #expect(pantryProfileMigrationIsComplete(droppedCount: 0) == true)
    }
}
