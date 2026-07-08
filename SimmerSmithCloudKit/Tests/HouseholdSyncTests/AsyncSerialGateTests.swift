import Foundation
import Testing
@testable import HouseholdSync

// simmersmith-vda — AsyncSerialGate: the engine-level mutex that serializes explicit
// CKSyncEngine operations. Exclusion must span SUSPENSIONS (an operation holds the gate
// across its awaits), a throwing operation must release, and waiters run in arrival order.

/// Tracks concurrent entries into gated operations. `@unchecked Sendable` via the lock.
private final class ConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private(set) var maxConcurrent = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        current += 1
        maxConcurrent = max(maxConcurrent, current)
        order.append(id)
    }

    func exit() {
        lock.lock(); defer { lock.unlock() }
        current -= 1
    }
}

@Test("exclusion spans suspensions — a held gate blocks the next operation until release")
func gateExcludesAcrossSuspensions() async {
    let gate = AsyncSerialGate()
    let probe = ConcurrencyProbe()
    let holdOpen = AsyncStream<Void>.makeStream()

    let first = Task {
        await gate.withLock {
            probe.enter(1)
            // Suspend INSIDE the gated op — exclusion must hold across this await.
            for await _ in holdOpen.stream { break }
            probe.exit()
        }
    }
    // Give the first op time to acquire and suspend.
    try? await Task.sleep(nanoseconds: 50_000_000)

    let second = Task {
        await gate.withLock {
            probe.enter(2)
            probe.exit()
        }
    }
    // The second op must NOT have entered while the first holds the gate.
    try? await Task.sleep(nanoseconds: 50_000_000)
    #expect(probe.order == [1])

    holdOpen.continuation.yield()
    holdOpen.continuation.finish()
    await first.value
    await second.value

    #expect(probe.order == [1, 2])
    #expect(probe.maxConcurrent == 1)
}

@Test("a throwing operation releases the gate for the next waiter")
func gateReleasesOnThrow() async {
    struct Boom: Error {}
    let gate = AsyncSerialGate()
    var secondRan = false

    do {
        try await gate.withLock { throw Boom() }
    } catch {}

    await gate.withLock { secondRan = true }
    #expect(secondRan)
}

@Test("waiters run in arrival order (FIFO)")
func gateIsFIFO() async {
    let gate = AsyncSerialGate()
    let probe = ConcurrencyProbe()
    let holdOpen = AsyncStream<Void>.makeStream()

    let holder = Task {
        await gate.withLock {
            probe.enter(0)
            for await _ in holdOpen.stream { break }
            probe.exit()
        }
    }
    try? await Task.sleep(nanoseconds: 50_000_000)

    // Enqueue three waiters with deterministic arrival order (each confirmed suspended
    // before the next is created — 20ms is ample for a Task to reach the gate).
    var waiters: [Task<Void, Never>] = []
    for id in 1...3 {
        waiters.append(Task {
            await gate.withLock {
                probe.enter(id)
                probe.exit()
            }
        })
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    holdOpen.continuation.yield()
    holdOpen.continuation.finish()
    await holder.value
    for w in waiters { await w.value }

    #expect(probe.order == [0, 1, 2, 3])
    #expect(probe.maxConcurrent == 1)
}
