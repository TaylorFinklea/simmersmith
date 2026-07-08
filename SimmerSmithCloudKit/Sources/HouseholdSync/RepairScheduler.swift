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
        public var nonDestructive: @MainActor @Sendable () async -> Void
        /// Deletes/re-parents records — OWNER ONLY. `@MainActor` for the same serialization reason.
        public var destructive: @MainActor @Sendable () async -> Void

        public init(
            nonDestructive: @escaping @MainActor @Sendable () async -> Void,
            destructive: @escaping @MainActor @Sendable () async -> Void
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
        let hadBufferedSignal = signaledWhileInactive
        signaledWhileInactive = false
        lock.unlock()
        if hadBufferedSignal {
            signal()
        }
    }

    /// Symmetric with `activate()`: re-gates the scheduler and cancels any not-yet-fired
    /// pending run. No production call site needs this yet (a household session activates
    /// once per launch and stays active) — kept for test symmetry and future re-gating needs.
    public func deactivate() {
        lock.lock()
        activated = false
        pendingTask?.cancel()
        pendingTask = nil
        lock.unlock()
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
        let task = Task { [weak self] in
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
    private func runDebouncedPass() async {
        guard beginPassOrQueueFollowUp() else { return }
        var again = true
        while again {
            await passes.nonDestructive()
            if ownsZone {
                await passes.destructive()
            }
            again = finishIterationAndTakeQueued()
        }
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
import OSLog

private let repairLogger = Logger(subsystem: "app.simmersmith.cloud", category: "RepairScheduler")

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
                    weekAdapter.repairSlots(weekID: weekID, slots: slots)
                    weekAdapter.reconcileSortOrder(weekID: weekID)
                    groceryAdapter.dedupeWeekGrocery(weekID: weekID, eventLinks: eventLinks(weekID))
                }
            },
            destructive: {
                // collapseWeeks re-parents + deletes loser Weeks FIRST, so pruneAudit (per the
                // post-collapse week set) never touches a week that's about to disappear.
                do {
                    _ = try await weekAdapter.collapseWeeks()
                } catch {
                    repairLogger.error("collapseWeeks failed: \(String(describing: error), privacy: .public)")
                }
                for weekID in weekIDs() {
                    weekAdapter.pruneAudit(weekID: weekID, keep: auditRetention)
                }
            }
        )
        return RepairScheduler(ownsZone: ownsZone, debounceNanoseconds: debounceNanoseconds, passes: passes)
    }
}
#endif
