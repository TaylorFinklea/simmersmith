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
    // simmersmith-vda: signal() is inert until the scheduler is armed — this test is about
    // debounce coalescing (post-activation), not the activation gate itself (see
    // `signalsBeforeActivateNeverRunAPass`/`activateRunsBufferedSignalExactlyOnce` below), so
    // activate immediately. This also covers the "signal storm post-activation" case.
    scheduler.activate()

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
    // simmersmith-vda: activate — this test is about owner/participant role-gating, not the
    // activation gate itself.
    participantScheduler.activate()
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
    ownerScheduler.activate()
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
    // simmersmith-vda: activate — this test is about idempotent convergence, not the
    // activation gate itself.
    scheduler.activate()

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
    // simmersmith-vda: activate — this test is about MainActor isolation, not the activation
    // gate itself.
    scheduler.activate()

    scheduler.signal()
    await scheduler.waitForPendingRun()

    #expect(sawMainActor.value == 2)   // both nonDestructive and destructive ran on the MainActor
}

// simmersmith-vda: repairs must never run against a partially-fetched store. Before
// `activate()` (called once the store is known-complete this launch — see
// `HouseholdSession.start()`), `signal()` must not schedule any pass at all.
@Test func signalsBeforeActivateNeverRunAPass() async {
    let nonDestructive = Counter()
    let destructive = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: { nonDestructive.increment() },
        destructive: { destructive.increment() }
    )
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 15_000_000, passes: passes)

    scheduler.signal()
    scheduler.signal()
    // Well past the debounce window — if signal() had scheduled anything, it would have
    // fired by now.
    try? await Task.sleep(nanoseconds: 90_000_000)
    #expect(nonDestructive.value == 0)
    #expect(destructive.value == 0)

    // Nothing pending pre-activation, so this is a no-op too.
    await scheduler.waitForPendingRun()
    #expect(nonDestructive.value == 0)
    #expect(destructive.value == 0)
}

// simmersmith-vda: a burst of signals that arrives before `activate()` must not be lost —
// it coalesces into exactly ONE debounced run once the scheduler is armed.
@Test func activateRunsBufferedSignalExactlyOnce() async {
    let nonDestructive = Counter()
    let destructive = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: { nonDestructive.increment() },
        destructive: { destructive.increment() }
    )
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 20_000_000, passes: passes)

    scheduler.signal()
    scheduler.signal()
    scheduler.signal()
    // Still gated — confirm no pass fires even after the debounce window would have elapsed.
    try? await Task.sleep(nanoseconds: 60_000_000)
    #expect(nonDestructive.value == 0)
    #expect(destructive.value == 0)

    scheduler.activate()
    await scheduler.waitForPendingRun()
    #expect(nonDestructive.value == 1)
    #expect(destructive.value == 1)
}

// simmersmith-vda: `deactivate()` cancels a not-yet-fired pending run and re-gates the
// scheduler — subsequent signals are dropped (buffered, not scheduled) until re-activated.
@Test func deactivateCancelsPendingAndGatesSignals() async {
    let nonDestructive = Counter()
    let destructive = Counter()
    let passes = RepairScheduler.Passes(
        nonDestructive: { nonDestructive.increment() },
        destructive: { destructive.increment() }
    )
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 20_000_000, passes: passes)
    scheduler.activate()

    scheduler.signal()      // schedules a debounced run
    scheduler.deactivate()  // must cancel it before it fires
    try? await Task.sleep(nanoseconds: 80_000_000)   // past the debounce window
    #expect(nonDestructive.value == 0)
    #expect(destructive.value == 0)

    scheduler.signal()      // dropped: scheduler is inactive again
    try? await Task.sleep(nanoseconds: 80_000_000)
    #expect(nonDestructive.value == 0)
    #expect(destructive.value == 0)

    // Re-activating replays the one buffered signal above as a single coalesced run.
    scheduler.activate()
    await scheduler.waitForPendingRun()
    #expect(nonDestructive.value == 1)
    #expect(destructive.value == 1)
}

/// Simple resumable gate for deterministically sequencing test/pass-side execution without
/// arbitrary sleeps — `wait()` suspends until `open()` is called (or returns immediately if
/// already open).
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        lock.unlock()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// Tracks concurrent entries into a pass so a test can assert the scheduler never runs two
/// passes at once.
private final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var _maxConcurrent = 0
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return _maxConcurrent }

    func enter() {
        lock.lock()
        current += 1
        if current > _maxConcurrent { _maxConcurrent = current }
        lock.unlock()
    }
    func exit() {
        lock.lock()
        current -= 1
        lock.unlock()
    }
}

// simmersmith-vda: the core fix under test — a `signal()` that lands WHILE a pass is running
// must not start a second, concurrent pass (the exact crash class: two concurrent
// `sendUntilDrained`-style calls racing on one engine). It must instead coalesce into exactly
// ONE follow-up run after the current pass finishes.
@Test func signalDuringRunningPassDoesNotOverlap() async {
    let tracker = ConcurrencyTracker()
    let callCount = Counter()
    let firstCallStarted = Gate()
    let firstCallProceed = Gate()

    let passes = RepairScheduler.Passes(
        nonDestructive: {
            tracker.enter()
            callCount.increment()
            if callCount.value == 1 {
                // Block the FIRST call open until the test explicitly releases it, holding
                // the scheduler "mid-pass" long enough to prove a concurrent signal doesn't
                // start a second pass.
                firstCallStarted.open()
                await firstCallProceed.wait()
            }
            tracker.exit()
        },
        destructive: { }
    )
    let scheduler = RepairScheduler(ownsZone: true, debounceNanoseconds: 20_000_000, passes: passes)
    scheduler.activate()

    scheduler.signal()
    await firstCallStarted.wait()   // first pass is now running and blocked mid-await
    #expect(tracker.maxConcurrent == 1)

    // A signal arriving mid-pass must be coalesced, not run concurrently.
    scheduler.signal()
    // Give the second debounced Task's timer time to elapse and reach the
    // passRunning/passQueued check (it must find passRunning == true and just queue).
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(tracker.maxConcurrent == 1)   // still no overlap
    #expect(callCount.value == 1)         // follow-up hasn't started yet — it's queued

    firstCallProceed.open()   // let the first pass finish
    // Give the first pass's drain loop time to notice the queued follow-up and run it.
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(callCount.value == 2)         // exactly one follow-up pass ran
    #expect(tracker.maxConcurrent == 1)   // never overlapped
}
