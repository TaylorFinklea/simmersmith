import Foundation

/// A strict FIFO queue of async operations: enqueued ops never run concurrently, and each
/// op only starts after every previously-enqueued op has finished (in arrival order).
/// MainActor-isolated ops preserve their isolation — the queue itself is `@MainActor`, so
/// `enqueue` is called and chains synchronously on the main actor.
///
/// Used to serialize household-session boots (simmersmith-0gf): an owner-boot
/// (`ensureHouseholdSession`) and a share-accept boot (`processPendingShare`) are independent
/// entry points that both end up wiring `AppState`'s household session. Without a shared FIFO,
/// the two could interleave at suspension points and race on which session wins
/// last-writer-wins. Chaining both entry points through one `SerialTaskQueue` makes the whole
/// sequence of boots run one-at-a-time, in the order they were requested.
@MainActor
public final class SerialTaskQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    /// Append `operation` to the end of the queue. It runs only after every previously
    /// enqueued operation has completed. Returns the `Task` for this operation; callers
    /// that need to wait for completion should `await` its `.value`.
    @discardableResult
    public func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }
}
