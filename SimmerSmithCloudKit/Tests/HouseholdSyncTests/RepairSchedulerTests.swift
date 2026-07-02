import Foundation
import Testing
@testable import HouseholdSync
import GroceryMerge

// simmersmith-gju — RepairScheduler: the debounced production wiring for the cross-record
// repair layer (WeekRepairAdapter + EventMergeAdapter.dedupeWeekGrocery), which previously ran
// ONLY from the DEBUG screen. These tests exercise the scheduler's debounce + role-gating logic
// headlessly via injected fake passes (constructing a live HouseholdSyncEngine needs a real
// CloudKit account for fetch/send — out of scope here, same convention as
// ShareRecordFilterTests). Idempotency of the underlying ConflictRepair passes themselves is
// covered by GroceryMergeTests/ConflictRepairTests; the test below proves the SCHEDULER'S
// repeated invocation converges (a 2nd run makes no further changes) for a realistic pass.

/// Thread-safe call counter — the scheduler's `Passes` closures are `@Sendable` and may run off
/// the calling thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}

@Test func debounceCoalescesBurstIntoOneRun() async {
    let nonDestructive = Counter()
    let destructive = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: { nonDestructive.increment() },
        destructive: { destructive.increment() }
    )
    // Short window so the test stays fast; the production default is ~2s.
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 40_000_000, passes: passes)

    // A burst of 5 signals, issued back-to-back with no intervening `await` (so the burst can
    // never straddle the debounce window regardless of scheduler/CPU jitter under parallel test
    // execution), must collapse into a single run.
    for _ in 0..<5 {
        scheduler.signal()
    }
    await scheduler.waitForPendingRun()

    #expect(nonDestructive.value == 1)
    #expect(destructive.value == 1)
}

@Test func destructivePassesRunOnlyForOwner() async {
    let nonDestructive = Counter()
    let destructive = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: { nonDestructive.increment() },
        destructive: { destructive.increment() }
    )

    // Participant: non-destructive passes run, destructive ones never fire.
    let participantScheduler = RepairScheduler(ownsZone: false, debounceNanoseconds: 10_000_000, passes: passes)
    participantScheduler.signal()
    await participantScheduler.waitForPendingRun()
    #expect(nonDestructive.value == 1)
    #expect(destructive.value == 0)

    // A second participant signal — still never triggers destructive passes.
    participantScheduler.signal()
    await participantScheduler.waitForPendingRun()
    #expect(nonDestructive.value == 2)
    #expect(destructive.value == 0)

    // Owner: both groups run.
    let ownerScheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 10_000_000, passes: passes)
    ownerScheduler.signal()
    await ownerScheduler.waitForPendingRun()
    #expect(nonDestructive.value == 3)
    #expect(destructive.value == 1)
}

@Test func nonDestructivePassInvokedTwiceConvergesIdempotently() async {
    // A tiny in-memory "store" the injected nonDestructive pass mutates via the REAL
    // ConflictRepair.dedupeGrocery pure logic — proves that re-running the scheduler's pass
    // over already-repaired state makes no further changes (never double-counts a tombstoned
    // loser), exactly like a peer's un-migrated store re-converging.
    final class FakeGroceryStore: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: GroceryItem]
        init(_ items: [GroceryItem]) {
            self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.recordName, $0) })
        }
        func snapshot() -> [GroceryItem] {
            lock.lock(); defer { lock.unlock() }
            return items.values.sorted { $0.recordName < $1.recordName }
        }
        func apply(_ result: ConflictRepair.GroceryDedupeResult) {
            lock.lock(); defer { lock.unlock() }
            for keeper in result.keepers { items[keeper.recordName] = keeper }
            for dead in result.tombstoned { items[dead.recordName] = dead }
        }
    }

    let store = FakeGroceryStore([
        GroceryItem(recordName: "A", unit: "cup", normalizedName: "tomato",
                    totalQuantity: 2, sourceMeals: "meal:mon", createdAt: 1),
        GroceryItem(recordName: "B", unit: "cup", normalizedName: "tomato",
                    totalQuantity: 3, sourceMeals: "meal:tue", createdAt: 2),
    ])
    let runCount = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: {
            runCount.increment()
            let result = ConflictRepair.dedupeGrocery(items: store.snapshot(), eventLinks: [])
            store.apply(result)
        },
        destructive: { }
    )
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 10_000_000, passes: passes)

    scheduler.signal()
    await scheduler.waitForPendingRun()
    let afterFirst = store.snapshot()
    #expect(afterFirst.first { $0.recordName == "A" }?.totalQuantity == 5)   // rolled up 2 + 3
    #expect(afterFirst.first { $0.recordName == "B" }?.isUserRemoved == true) // loser tombstoned

    // A second, separate debounce cycle over the now-repaired state must be a no-op.
    scheduler.signal()
    await scheduler.waitForPendingRun()
    let afterSecond = store.snapshot()
    #expect(afterSecond == afterFirst)
    #expect(runCount.value == 2)   // both signals actually ran the pass (separate bursts)
}

// simmersmith-9zf — `Passes.nonDestructive`/`.destructive` must run on the MainActor so they
// serialize with the `@MainActor` repositories (WeekRepository, GroceryRepository, etc.) that
// mutate the SAME HouseholdLocalStore in production; otherwise a debounced repair run can race a
// repo's read-modify-write. `MainActor.assertIsolated()` traps if the closure body somehow runs
// off the main actor, proving the `Passes` closure types' `@MainActor` annotation actually hops.
@Test func passesRunOnMainActor() async {
    let sawMainActor = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: {
            MainActor.assertIsolated()
            sawMainActor.increment()
        },
        destructive: {
            MainActor.assertIsolated()
            sawMainActor.increment()
        }
    )
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 10_000_000, passes: passes)

    scheduler.signal()
    await scheduler.waitForPendingRun()

    #expect(sawMainActor.value == 2)   // both nonDestructive and destructive ran on the MainActor
}
