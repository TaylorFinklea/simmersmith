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
        /// Upsert/tombstone-only — safe on both the owner and a participant.
        public var nonDestructive: @Sendable () async -> Void
        /// Deletes/re-parents records — OWNER ONLY.
        public var destructive: @Sendable () async -> Void

        public init(
            nonDestructive: @escaping @Sendable () async -> Void,
            destructive: @escaping @Sendable () async -> Void
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

    /// - Parameters:
    ///   - ownsZone: mirrors `HouseholdSyncEngine.ownsZone` — gates `passes.destructive`.
    ///   - debounceNanoseconds: settle window after the LAST `signal()` before a run fires
    ///     (~2s per the lead design decision). Tests inject a short window to stay fast.
    public init(ownsZone: Bool, debounceNanoseconds: UInt64 = 2_000_000_000, passes: Passes) {
        self.ownsZone = ownsZone
        self.debounceNanoseconds = debounceNanoseconds
        self.passes = passes
    }

    /// Call on every change signal (post-fetch, post-send, or a manual "fix it" action).
    /// Cancels any not-yet-fired pending run and restarts the debounce window — N signals in a
    /// burst collapse into ONE run after the last one settles.
    public func signal() {
        lock.lock()
        pendingTask?.cancel()
        let interval = debounceNanoseconds
        let task = Task { [passes, ownsZone] in
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { return }
            await passes.nonDestructive()
            if ownsZone {
                await passes.destructive()
            }
        }
        pendingTask = task
        lock.unlock()
    }

    /// Test/debug hook: await the most recently scheduled run to completion (no-op if nothing
    /// is pending).
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
                    weekAdapter.repairSlots(weekID: weekID, slots: slots)
                    weekAdapter.reconcileSortOrder(weekID: weekID)
                    groceryAdapter.dedupeWeekGrocery(weekID: weekID, eventLinks: eventLinks(weekID))
                }
            },
            destructive: {
                // collapseWeeks re-parents + deletes loser Weeks FIRST, so pruneAudit (per the
                // post-collapse week set) never touches a week that's about to disappear.
                _ = try? await weekAdapter.collapseWeeks()
                for weekID in weekIDs() {
                    weekAdapter.pruneAudit(weekID: weekID, keep: auditRetention)
                }
            }
        )
        return RepairScheduler(ownsZone: ownsZone, debounceNanoseconds: debounceNanoseconds, passes: passes)
    }
}
#endif
