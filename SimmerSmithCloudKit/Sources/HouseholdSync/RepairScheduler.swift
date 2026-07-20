import Foundation

// SP-A Phase 4/5 follow-up (simmersmith-gju) — the cross-record repair layer
// (WeekRepairAdapter's repairSlots/collapseWeeks/reconcileSortOrder/pruneAudit and
// EventMergeAdapter.dedupeWeekGrocery) previously ran ONLY from the DEBUG screen. Nothing in
// production ever invoked it, so two-device concurrent edits accumulate duplicate (day, slot)
// meals, duplicate weeks, and duplicate grocery rows with no self-heal. `RepairScheduler` is
// the production wiring for that layer.
//
// Debounced by design: `signal()` is called on every post-fetch/post-send change
// (`HouseholdSyncEngine.onStoreChanged`, wired in `HouseholdSession.start`) and by the manual
// "Dedupe duplicates" button. A burst of signals inside the debounce window collapses into ONE
// coalesced run after the window settles, so ordinary fetch/save churn (e.g. a big initial
// sync, or a flurry of edits) doesn't thrash the repair passes on every single event.
//
// Role safety (see WeekRepairAdapter's own header + HouseholdSyncEngine.ownsZone):
//   - `nonDestructive` passes — WeekRepairAdapter.repairSlots (slot-dedupe, keeps the richest/
//     lowest-sortOrder meal, relocates the loser) and .reconcileSortOrder (gap-free resort), plus
//     EventMergeAdapter.dedupeWeekGrocery (tombstones losers, never hard-deletes) — only ever
//     UPSERT or TOMBSTONE records. None of them delete another household member's record, so
//     they are safe to run on BOTH the owner and a participant.
//   - `destructive` passes — WeekRepairAdapter.collapseWeeks (deletes loser Week records after
//     re-parenting their children) and .pruneAudit (cascade-deletes old WeekChangeBatch/
//     WeekChangeEvent rows) — actually remove records. A participant does not own the household
//     zone (HouseholdSyncEngine.ownsZone == false for it) and must never delete another member's
//     data, mirroring the same owner-only gate HouseholdSyncEngine applies to `.saveZone`/zone
//     recreation. These run OWNER-ONLY, gated on the scheduler's `ownsZone`.
//
// Idempotent by construction: every underlying pass only re-saves/deletes the records that
// actually changed (see each adapter method's diff-and-resave logic), so a second run over
// already-repaired state is a no-op.
public final class RepairScheduler: @unchecked Sendable {
    /// The two role-gated groups of passes. Injected so this type stays decoupled from
    /// `HouseholdSyncEngine`/CloudKit specifics — the `canImport(CloudKit)` extension below
    /// wires the real `WeekRepairAdapter`/`EventMergeAdapter` calls for production use; tests
    /// inject fakes to verify the debounce + role-gating behavior headlessly.
    public struct Passes: Sendable {
        /// Upsert/tombstone-only — safe on both the owner and a participant. `@MainActor` so it
        /// serializes with the `@MainActor` repositories (WeekRepository, GroceryRepository, etc.)
        /// that mutate the SAME `HouseholdLocalStore` — otherwise a debounced repair run can
        /// interleave a read-modify-write with a repo's, losing an update (simmersmith-9zf).
        public var nonDestructive: @MainActor @Sendable () async throws -> Void
        /// Deletes/re-parents records — OWNER ONLY. `@MainActor` for the same serialization reason.
        public var destructive: @MainActor @Sendable () async throws -> Void

        public init(
            nonDestructive: @escaping @MainActor @Sendable () async throws -> Void,
            destructive: @escaping @MainActor @Sendable () async throws -> Void
        ) {
            self.nonDestructive = nonDestructive
            self.destructive = destructive
        }
    }

    private let ownsZone: Bool
    private let debounceNanoseconds: UInt64
    private let passes: Passes

    private let lock = NSLock()
    private var pendingTask: Task<Void, Never>?

    // simmersmith-vda: cold-launch crash — every launch discards the sync token (r8q),
    // forcing a full zone refetch delivered as MULTIPLE `onStoreChanged` batches. Each batch
    // restarted this scheduler's debounce; on a slow/large refetch the debounce could elapse
    // in a batch GAP, firing a destructive pass (`WeekRepairAdapter.collapseWeeks`) while
    // `HouseholdSession.start()`'s own `engine.fetchChanges()` was still suspended —
    // `collapseWeeks`'s `engine.save`s + `sendUntilDrained` raced that in-flight fetch's
    // CKSyncEngine internals, tripping a CKSyncEngine-internal Swift assertion (SIGTRAP).
    // Independently, `collapseWeeks` run against a PARTIALLY-fetched store only sees the
    // children delivered so far, so it re-parents/deletes based on incomplete data —
    // orphaning children the fetch hasn't delivered yet. Serializing calls alone doesn't fix
    // this: the hazard is running a destructive pass AT ALL before the store is known-complete.
    // `activated`/`signaledWhileInactive` below gate `signal()` on that quiescence.
    private var activated = false
    private var signaledWhileInactive = false

    // simmersmith-vda: even after activation, two debounced Tasks could still interleave at
    // an `await` — a `signal()` arriving while a pass is RUNNING scheduled a second debounced
    // Task that, once its own timer elapsed, could start a second pass concurrently with the
    // first (same crash class: two concurrent `sendUntilDrained` calls on one engine).
    // `passRunning`/`passQueued` make pass execution single-flight: only one pass instance
    // runs at a time, and a signal that lands mid-run is coalesced into exactly one follow-up
    // run after the current one finishes (never lost, never concurrent). Mirrors
    // `ObservationReloader`'s drain-flag idiom (SimmerSmithKit/Concurrency/ObservationReloader
    // .swift) — the "is another run queued?" check and the flag reset happen inside ONE lock
    // hold so a fire landing between the final check and the reset is never dropped.
    private var passRunning = false
    private var passQueued = false

    // simmersmith-glw: `deactivate()` used to have zero production call sites, so an
    // in-flight pass always ran to completion even after the session that started it was
    // torn down (sign-out, the owner->participant adopt-swap, factory reset) — the pass
    // strongly retains `engine`/`store` and keeps issuing CKModifyRecords past teardown. On
    // factory reset this raced `deleteAllHouseholdZones()`: a mid-pass save hitting
    // `.zoneNotFound` after the wipe enters `HouseholdSyncEngine.handleFailedSave`'s
    // owner-path zone RE-CREATION, resurrecting the just-deleted zone. `abortRequested` is
    // checked at each sub-pass boundary in `runDebouncedPass()` so `deactivate()` (sync,
    // fire-and-forget-safe — see its doc comment) can stop a RUNNING pass at the next
    // opportunity, not just cancel a not-yet-fired one. Reset by `activate()` so a scheduler
    // that is re-armed (see `deactivateCancelsPendingAndGatesSignals`) isn't permanently
    // wedged into aborting.
    private var abortRequested = false
    // Continuations waiting for `passRunning` to become false (see `awaitIdle()`), resumed
    // from the single completion point at the bottom of `runDebouncedPass()` — never resumed
    // while `lock` is held.
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - ownsZone: mirrors `HouseholdSyncEngine.ownsZone` — gates `passes.destructive`.
    ///   - debounceNanoseconds: settle window after the LAST `signal()` before a run fires
    ///     (~2s per the lead design decision). Tests inject a short window to stay fast.
    public init(ownsZone: Bool, debounceNanoseconds: UInt64 = 2_000_000_000, passes: Passes) {
        self.ownsZone = ownsZone
        self.debounceNanoseconds = debounceNanoseconds
        self.passes = passes
    }

    /// Arms the scheduler — call once the store is known to be fully populated this launch
    /// (simmersmith-vda: `HouseholdSession.start()`'s initial `fetchChanges()` succeeding; an
    /// offline boot deliberately never activates — repairs are opportunistic hygiene and run
    /// on the next healthy launch). Crash-safety does NOT depend on this timing — explicit
    /// engine operations are serialized by `HouseholdSyncEngine`'s `AsyncSerialGate`; this
    /// gate exists for the DATA hazard (a destructive pass judging duplicates against a
    /// partially-fetched store). Before this is called, `signal()` is inert (buffered, not
    /// scheduled) — see `signal()`. If a signal arrived while inactive, replay it as a single
    /// `signal()` call now (after releasing the lock) so a burst that landed during boot
    /// coalesces into ONE normal debounced run rather than being lost entirely.
    public func activate() {
        lock.lock()
        activated = true
        abortRequested = false
        let hadBufferedSignal = signaledWhileInactive
        signaledWhileInactive = false
        lock.unlock()
        if hadBufferedSignal {
            signal()
        }
    }

    /// Symmetric with `activate()`: re-gates the scheduler, cancels any not-yet-fired pending
    /// run, and requests abort of a currently RUNNING pass (checked at the next sub-pass
    /// boundary in `runDebouncedPass()` — see `abortRequested`). Synchronous and
    /// fire-and-forget-safe by design: called from plain (non-async) `@MainActor` teardown
    /// funcs (`HouseholdSession.clearState()`/`detach()`) that cannot `await`, so this must
    /// never block waiting for an in-flight pass to actually stop. Callers that CAN await and
    /// need that guarantee (e.g. factory reset, before deleting CloudKit zones) should use
    /// `quiesce()` instead.
    public func deactivate() {
        lock.lock()
        activated = false
        abortRequested = true
        pendingTask?.cancel()
        pendingTask = nil
        lock.unlock()
    }

    /// Async, wait-for-completion counterpart to `deactivate()`: deactivates (gating future
    /// signals, cancelling any not-yet-fired pending run, and requesting abort of an
    /// in-flight pass), then awaits that pass actually stopping. simmersmith-glw: factory
    /// reset's zone wipe must never race a repair pass still landing CKModifyRecords against
    /// a household zone that's about to be deleted — a mid-wipe save hitting `.zoneNotFound`
    /// would otherwise resurrect the zone via `HouseholdSyncEngine.handleFailedSave`'s
    /// owner-path recreation. Only call from an async context that can afford to wait a
    /// sub-pass boundary or two; never from `@MainActor`-synchronous teardown (use
    /// `deactivate()` there).
    public func quiesce() async {
        deactivate()
        await awaitIdle()
    }

    /// Suspends until no pass is currently running (returns immediately if already idle).
    /// Does not itself request an abort of a running pass — pair with `deactivate()` (or use
    /// `quiesce()`, which does both) if that's what's needed. The continuation is stored
    /// under `lock` and resumed by `runDebouncedPass()`'s single completion point, mirroring
    /// the rest of this type's "check + mutate inside one lock hold" discipline so a pass
    /// finishing between the idle-check and the continuation's registration is never missed.
    public func awaitIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !passRunning {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Call on every change signal (post-fetch, post-send, or a manual "fix it" action).
    /// Before `activate()` has been called, this only records that a signal arrived (see
    /// `activate()`) and schedules nothing — the store isn't known-complete yet, so running a
    /// destructive pass would be unsafe (simmersmith-vda). Once active, cancels any
    /// not-yet-fired pending run and restarts the debounce window — N signals in a burst
    /// collapse into ONE run after the last one settles.
    public func signal() {
        lock.lock()
        guard activated else {
            signaledWhileInactive = true
            lock.unlock()
            return
        }
        pendingTask?.cancel()
        let interval = debounceNanoseconds
        // simmersmith-e0a.1: `signal()` is normally reached from CKSyncEngine's
        // `handleEvent` callback. A regular unstructured Task inherits CloudKit's delegate
        // task-local context, so a later repair drain traps when it awaits `sendChanges()`.
        // Detach this owned debounce boundary; cancellation remains explicit through
        // `pendingTask`, and the repair closures still hop to MainActor below.
        let task = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled, let self else { return }
            await self.runDebouncedPass()
        }
        pendingTask = task
        lock.unlock()
    }

    /// Runs the pass pair (`nonDestructive`, then `destructive` if `ownsZone`), single-flight.
    /// If a pass is already running, this just marks a follow-up as queued and returns —
    /// coalescing into the running pass's drain loop rather than overlapping it
    /// (simmersmith-vda). The "queued?" check + flag reset happen inside one lock hold so a
    /// `signal()` landing between the final check and the reset is never lost.
    ///
    /// simmersmith-glw: `abortRequested` (set by `deactivate()`) is checked at every sub-pass
    /// boundary — before `nonDestructive`, before `destructive`, and between drain
    /// iterations — so a deactivate arriving mid-pass stops the drain at the NEXT boundary
    /// rather than letting it run (and re-loop) to completion. Whichever way the loop exits
    /// (aborted or drained), `endPassAndTakeIdleWaiters()` is the single completion point that
    /// clears `passRunning`/`passQueued` and wakes anything awaiting `awaitIdle()`.
    private func runDebouncedPass() async {
        guard beginPassOrQueueFollowUp() else { return }
        runLoop: while true {
            if isAbortRequested() { break runLoop }
            do {
                try await passes.nonDestructive()
                if isAbortRequested() { break runLoop }
                if ownsZone {
                    try await passes.destructive()
                }
            } catch {
                print("[RepairScheduler] repair pass failed: \(error)")
                break runLoop
            }
            if !finishIterationAndTakeQueued() { break runLoop }
        }
        for waiter in endPassAndTakeIdleWaiters() {
            waiter.resume()
        }
    }

    /// Synchronous lock scope: true once `deactivate()` has requested an abort of the
    /// currently running pass.
    private func isAbortRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return abortRequested
    }

    /// Synchronous lock scope (NSLock must not be held across `await`): returns true if this
    /// caller becomes the single running pass; false if one is already running (in which case
    /// a follow-up run has been queued into its drain loop instead).
    private func beginPassOrQueueFollowUp() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if passRunning {
            passQueued = true
            return false
        }
        passRunning = true
        return true
    }

    /// Synchronous lock scope: consumes the queued-follow-up flag; clears `passRunning` only
    /// when nothing was queued — the check and the reset happen in ONE lock hold so a
    /// `signal()` landing between them is never dropped.
    private func finishIterationAndTakeQueued() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let again = passQueued
        passQueued = false
        if !again {
            passRunning = false
        }
        return again
    }

    /// Synchronous lock scope (NSLock must not be held across `await`): the single completion
    /// point `runDebouncedPass()` calls exactly once on every exit path (normal drain-out OR
    /// aborted mid-pass). Force-clears `passRunning`/`passQueued` — a no-op if
    /// `finishIterationAndTakeQueued()` already cleared them on the normal-exit path, but load-
    /// bearing on the abort path, where the loop breaks before that call runs. Returns any
    /// `awaitIdle()` continuations so the caller can resume them OUTSIDE the lock.
    private func endPassAndTakeIdleWaiters() -> [CheckedContinuation<Void, Never>] {
        lock.lock(); defer { lock.unlock() }
        passRunning = false
        passQueued = false
        let waiters = idleWaiters
        idleWaiters = []
        return waiters
    }

    /// Test/debug hook: await the most recently scheduled run to completion (no-op if nothing
    /// is pending). Note: if a `signal()` arrived while a pass was already running, the Task
    /// this awaits may only have queued a follow-up (returning immediately) rather than run it
    /// — the follow-up itself is driven by the ORIGINAL task's drain loop. Tests that need to
    /// observe that follow-up should await on pass-side signals instead.
    public func waitForPendingRun() async {
        await currentPendingTask()?.value
    }

    /// Synchronous lock scope so `waitForPendingRun` never holds the NSLock across an `await`.
    private func currentPendingTask() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return pendingTask
    }
}

#if canImport(CloudKit)
import CloudKit
import GroceryMerge
import HouseholdRecords

extension RepairScheduler {
    /// Meal-slot vocabulary `WeekRepairAdapter.repairSlots` relocates a slot-collision loser
    /// into (mirrors the vocabulary CloudKitDebugView's Phase-4 check exercises).
    public static let defaultSlotVocabulary = ["breakfast", "lunch", "dinner", "snack"]

    /// Number of `WeekChangeBatch` audit rows `pruneAudit` retains per week. The audit syncs to
    /// every household member's iCloud quota, so it needs SOME cap; 20 is a generous default —
    /// callers can override for a tighter/looser retention policy.
    public static let defaultAuditRetention = 20

    /// Wires the real cross-record repair passes over a household's live `HouseholdSyncEngine`.
    /// `nonDestructive` runs `WeekRepairAdapter.repairSlots`/`.reconcileSortOrder` and
    /// `EventMergeAdapter.dedupeWeekGrocery` for every week currently in the local store;
    /// `destructive` runs `WeekRepairAdapter.collapseWeeks` then `.pruneAudit` per (post-collapse)
    /// week — gated OWNER-ONLY by the scheduler's `ownsZone`.
    public static func householdRepairs(
        engine: HouseholdSyncEngine,
        zoneID: CKRecordZone.ID,
        ownsZone: Bool,
        slots: [String] = defaultSlotVocabulary,
        auditRetention: Int = defaultAuditRetention,
        debounceNanoseconds: UInt64 = 2_000_000_000
    ) -> RepairScheduler {
        let weekAdapter = WeekRepairAdapter(engine: engine, zoneID: zoneID)
        let groceryAdapter = EventMergeAdapter(engine: engine, zoneID: zoneID)

        let weekIDs: @Sendable () -> [String] = {
            engine.store.records(ofType: HouseholdRecordType.week.recordTypeName)
                .map { $0.recordID.recordName }
        }
        let eventLinks: @Sendable (String) -> [EventGroceryItem] = { weekID in
            engine.store.records(ofType: EventGroceryCodec.recordType)
                .map(EventGroceryCodec.decode)
                .filter { $0.mergedIntoWeekID == weekID }
        }

        let passes = Passes(
            nonDestructive: {
                for weekID in weekIDs() {
                    _ = try weekAdapter.repairSlots(weekID: weekID, slots: slots)
                    _ = try weekAdapter.reconcileSortOrder(weekID: weekID)
                    _ = try groceryAdapter.dedupeWeekGrocery(
                        weekID: weekID,
                        eventLinks: eventLinks(weekID)
                    )
                }
            },
            destructive: {
                // collapseWeeks re-parents + deletes loser Weeks FIRST, so pruneAudit (per the
                // post-collapse week set) never touches a week that's about to disappear.
                _ = try await weekAdapter.collapseWeeks()
                for weekID in weekIDs() {
                    _ = try weekAdapter.pruneAudit(weekID: weekID, keep: auditRetention)
                }
            }
        )
        return RepairScheduler(ownsZone: ownsZone, debounceNanoseconds: debounceNanoseconds, passes: passes)
    }
}
#endif
