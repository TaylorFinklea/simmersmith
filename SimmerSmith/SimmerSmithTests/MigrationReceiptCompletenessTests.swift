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

@MainActor
struct RequiredWeekEventMigrationWriteTests {
    @Test("a rejected first Week write is retryable and cannot stamp its receipt")
    func rejectedFirstWeekWriteWithholdsReceipt() async {
        var actions: [String] = []
        let runner = WeekMigrationRunner(
            writeData: {
                actions.append("week")
                throw RequiredMigrationWriteTestError.expected
            },
            isDataComplete: { true },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        let completion = await runner.run()

        #expect(completion == .retryable)
        #expect(actions == ["week"])
    }

    @Test("a rejected first Event write is retryable and cannot stamp its receipt")
    func rejectedFirstEventWriteWithholdsReceipt() async {
        var actions: [String] = []
        let runner = EventMigrationRunner(
            writeData: {
                actions.append("event")
                throw RequiredMigrationWriteTestError.expected
            },
            isDataComplete: { true },
            drain: { actions.append("drain") },
            saveReceipt: { actions.append("receipt") }
        )

        let completion = await runner.run()

        #expect(completion == .retryable)
        #expect(actions == ["event"])
    }

    @Test("a failed Week data drain withholds the receipt")
    func failedWeekDataDrainWithholdsReceipt() async {
        var actions: [String] = []
        let runner = WeekMigrationRunner(
            writeData: { actions.append("data") },
            isDataComplete: { true },
            drain: {
                actions.append("drain")
                throw RequiredMigrationWriteTestError.expected
            },
            saveReceipt: { actions.append("receipt") }
        )

        let completion = await runner.run()

        #expect(completion == .retryable)
        #expect(actions == ["data", "drain"])
    }
}

private enum RequiredMigrationWriteTestError: Error {
    case expected
}

@MainActor
struct RecipeMigrationReceiptOrderingTests {
    @Test("a failed required recipe data drain withholds the recipe receipt")
    func failedRequiredDataDrainWithholdsReceipt() async {
        var receiptSaveCount = 0
        let runner = RecipeMigrationReceiptRunner(
            drainRequiredData: { throw RequiredMigrationWriteTestError.expected },
            saveReceipt: {
                receiptSaveCount += 1
                return true
            }
        )

        let completion = await runner.run()

        #expect(completion == .retryable)
        #expect(receiptSaveCount == 0)
    }
}
