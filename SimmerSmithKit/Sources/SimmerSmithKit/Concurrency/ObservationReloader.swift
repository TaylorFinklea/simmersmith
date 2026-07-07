import Foundation
import Observation

/// Re-arms a `withObservationTracking` watch on a tracked value and drives a coalescing
/// reload whenever it changes — fixing simmersmith-7mb.
///
/// The bug: every repository observing `session.storeRevision` re-registered its
/// `withObservationTracking` watch INSIDE the hopped `Task`, AFTER `reload()` ran:
///
/// ```swift
/// withObservationTracking { _ = session.storeRevision } onChange: { [weak self] in
///     Task { @MainActor [weak self] in
///         self?.reload()
///         self?.observeRevision()   // re-register AFTER reload — too late
///     }
/// }
/// ```
///
/// For a fully-synchronous `reload()` the gap is mostly benign — a missed trigger is
/// covered by the full re-read that follows. But any suspension inside `reload()` leaves
/// a window where a bump has NO registered observer AND no subsequent re-read: the UI
/// stays stale until an unrelated edit happens to re-arm the watch.
///
/// The fix is the invariant this type enforces: **re-register the observation BEFORE
/// doing any reload work**, then run a coalescing drain loop that guarantees a terminal
/// reload after the last bump, regardless of whether `reload` suspends. Concretely:
///
/// - `fire()` re-registers the watch FIRST (so a bump landing during the ensuing reload
///   is never missed), THEN marks a pending reload and (re-)starts the drain if needed.
/// - The drain loop clears `pending` before awaiting `reload()`, then loops again if a
///   new bump set `pending` back to `true` while `reload()` was suspended — guaranteeing
///   a reload that runs strictly after the last observed bump.
/// - Reloads never run concurrently with each other (a single drain `Task` at a time).
/// - Weak-self capture in both the `onChange` handler and the drain `Task` means a
///   deallocated owner stops the chain rather than leaking work.
@MainActor
public final class ObservationReloader {
    private let track: @MainActor () -> Void
    private let reload: @MainActor () async -> Void

    private var pending = false
    private var draining = false

    public init(track: @escaping @MainActor () -> Void, reload: @escaping @MainActor () async -> Void) {
        self.track = track
        self.reload = reload
    }

    /// Perform the first registration. Call once after construction.
    public func start() {
        observe()
    }

    private func observe() {
        withObservationTracking {
            self.track()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.fire()
            }
        }
    }

    /// Re-register FIRST — before any reload work; this is the fix for simmersmith-7mb.
    private func fire() {
        observe()
        pending = true
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        guard !draining else { return }
        draining = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.pending {
                self.pending = false
                await self.reload()
            }
            self.draining = false
        }
    }
}
