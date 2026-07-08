import Foundation

/// A non-reentrant async mutex: at most one `withLock` operation runs at a time; the rest
/// suspend and run in arrival order (simmersmith-vda).
///
/// Exists to serialize the app's EXPLICIT `CKSyncEngine` operations (`fetchChanges` /
/// `sendChanges` / drains) on one `HouseholdSyncEngine`. Build 149 crashed at first open
/// because a debounced repair pass issued `sendChanges` while `HouseholdSession.start()`'s
/// initial `fetchChanges` was still suspended on the same engine — a CKSyncEngine-internal
/// Swift assertion (device .ips, 2026-07-08). Per-call-site ordering rules proved unfixable
/// by review (two adversarial rounds found new overlaps: migration drain vs repair drain,
/// activation-fallback vs boot fetch), so the mutual exclusion lives at the engine's own
/// entry points instead — any operation that fires "too early" simply queues here.
///
/// NON-REENTRANT: a `withLock` operation that calls back into another `withLock` on the same
/// gate deadlocks. `HouseholdSyncEngine` therefore uses raw `syncEngine` calls INSIDE gated
/// bodies (see `sync()` / `sendUntilDrained()`), and the gate is deliberately `private` to
/// the engine so no outside caller can nest it.
///
/// Unlike an actor's own serialization, exclusion here spans SUSPENSIONS: an operation holds
/// the gate across its awaits until it returns or throws.
public actor AsyncSerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
            // Resumed by release(): ownership was handed to us directly — `busy` stays true.
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand ownership straight to the next waiter (FIFO) without dropping `busy`,
            // so a fresh acquire() can't barge in between resume and the waiter running.
            waiters.removeFirst().resume()
        }
    }
}
