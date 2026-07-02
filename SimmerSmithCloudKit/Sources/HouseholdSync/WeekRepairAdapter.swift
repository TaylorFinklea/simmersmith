#if canImport(CloudKit)
import CloudKit
import Foundation
import GroceryMerge
import HouseholdRecords

// SP-A Phase 4-remainder — bridges the pure ConflictRepair cross-record passes + the audit-prune
// to the household CKSyncEngine for the plain-LWW Week / WeekMeal / WeekChangeBatch manifest
// records. CloudKit has no unique constraint or multi-record transaction, so concurrent edits leave
// transient artifacts the per-record LWW seam can't fix: duplicate (day,slot) meals (a half-applied
// swap), duplicate weeks (one week_start created on two devices), gappy/colliding sortOrder, and
// unbounded audit growth. These run AFTER a fetched batch lands, over the affected sibling/parent
// set, then save/delete the repaired set back through the engine (which syncs it). Each pass reads
// the manifest CKRecords into the minimal GroceryMerge value type its pure pass consumes — repair
// only ever touches slot / sortOrder / the week pointer, or deletes whole records, so the lossy
// projection is safe (full record fidelity stays in the stored CKRecord).
public struct WeekRepairAdapter: Sendable {
    public let engine: HouseholdSyncEngine
    public let zoneID: CKRecordZone.ID

    public init(engine: HouseholdSyncEngine, zoneID: CKRecordZone.ID) {
        self.engine = engine; self.zoneID = zoneID
    }

    private static let weekType = HouseholdRecordType.week.recordTypeName
    private static let mealType = HouseholdRecordType.weekMeal.recordTypeName
    private static let batchType = HouseholdRecordType.weekChangeBatch.recordTypeName

    private func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: zoneID) }
    private func refName(_ value: Any?) -> String { (value as? CKRecord.Reference)?.recordID.recordName ?? "" }

    private func mealRecords(weekID: String) -> [CKRecord] {
        engine.store.records(ofType: Self.mealType).filter { refName($0["week"]) == weekID }
    }
    private func mealValue(_ r: CKRecord) -> WeekMeal {
        WeekMeal(recordName: r.recordID.recordName, weekID: refName(r["week"]),
                 dayName: r["dayName"] as? String ?? "", slot: r["slot"] as? String ?? "",
                 sortOrder: r["sortOrder"] as? Int ?? 0)
    }

    // MARK: slot-swap repair (no DEFERRABLE UNIQUE on CloudKit)

    /// Resolve transient duplicate `(day, slot)` on a week. Re-saves only the meals the pure pass
    /// moved (keeper per collision keeps its slot). `slots` is the slot vocabulary to relocate into.
    @discardableResult
    public func repairSlots(weekID: String, slots: [String]) -> [WeekMeal] {
        applyMealChanges(weekID: weekID, transform: { ConflictRepair.repairDuplicateSlots($0, slots: slots) },
                         field: "slot", value: { $0.slot as CKRecordValue }, current: { $0["slot"] as? String },
                         changed: { $1 != $0.slot })
    }

    // MARK: sort-order reconcile (gap-free, collision-free)

    @discardableResult
    public func reconcileSortOrder(weekID: String) -> [WeekMeal] {
        applyMealChanges(weekID: weekID, transform: ConflictRepair.reconcileSortOrder,
                         field: "sortOrder", value: { $0.sortOrder as CKRecordValue }, current: { $0["sortOrder"] as? Int },
                         changed: { $1 != $0.sortOrder })
    }

    /// Shared driver: project meals → run a pure pass → re-save only the records whose target field
    /// actually changed (avoids sync ping-pong on no-ops).
    private func applyMealChanges<Current: Equatable>(
        weekID: String, transform: ([WeekMeal]) -> [WeekMeal],
        field: String, value: (WeekMeal) -> CKRecordValue, current: (CKRecord) -> Current?,
        changed: (WeekMeal, Current?) -> Bool
    ) -> [WeekMeal] {
        let records = mealRecords(weekID: weekID)
        let byName = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID.recordName, $0) })
        var result: [WeekMeal] = []
        for meal in transform(records.map(mealValue)) {
            guard let rec = byName[meal.recordName], changed(meal, current(rec)) else { continue }
            rec[field] = value(meal)
            engine.save(rec)
            result.append(meal)
        }
        return result
    }

    // MARK: duplicate-week collapse (UNIQUE(household_id, week_start) had no CloudKit equivalent)

    /// Two devices created the same `week_start`: keep the lowest recordName, re-parent the losers'
    /// subtrees onto the keeper, then delete the now-childless loser weeks. The re-parent saves MUST
    /// land server-side BEFORE the loser delete: a WeekMeal/WeekChangeBatch still referencing a loser
    /// with `.deleteSelf` would be cascade-deleted by the SERVER the instant the loser's delete lands
    /// (the server acts on its own view of the references, not our local re-parent) — so this drains
    /// the re-parents first, then plain-deletes the (now childless, both locally and remotely) losers.
    // simmersmith-9zf: `@MainActor` so this async pass runs ON the main actor when awaited from
    // RepairScheduler's `@MainActor` destructive closure. Without it — per SE-0338 — a nonisolated
    // async callee hops OFF the caller's actor, so the store read-modify-writes below (the
    // `engine.save`/`engine.delete` re-parent + delete steps) would run unserialized with the
    // `@MainActor` repositories mutating the same `HouseholdLocalStore` (the exact lost-update this
    // bead closes). The single `await engine.sendUntilDrained()` (a network drain, not a store
    // mutation) still cooperatively yields — harmless.
    @discardableResult
    @MainActor
    public func collapseWeeks() async throws -> [ConflictRepair.WeekCollapse] {
        let weeks = engine.store.records(ofType: Self.weekType)
            .map { Week(recordName: $0.recordID.recordName, weekStart: weekStartKey($0)) }
            .filter { !$0.weekStart.isEmpty }   // never collapse weeks missing a week_start key together
        let collapses = ConflictRepair.collapseDuplicateWeeks(weeks)
        guard !collapses.isEmpty else { return [] }

        for collapse in collapses {
            let losers = Set(collapse.losers)
            let keeperRef = CKRecord.Reference(recordID: id(collapse.keeper), action: .deleteSelf)
            for rec in engine.store.records(ofType: Self.mealType) where losers.contains(refName(rec["week"])) {
                rec["week"] = keeperRef; engine.save(rec)
            }
            for rec in engine.store.records(ofType: Self.batchType) where losers.contains(refName(rec["week"])) {
                rec["week"] = keeperRef; engine.save(rec)
            }
            // String week-keys (plain STRINGs, not CKReferences → no server cascade, but they'd
            // DANGLE on the deleted loser): GroceryItem.weekID, Event.linkedWeekID,
            // EventGroceryItem.mergedIntoWeekID. Re-point onto the keeper so the link survives.
            repointStringKey(type: GroceryCodec.recordType, field: "weekID", losers: losers, keeper: collapse.keeper)
            repointStringKey(type: "Event", field: "linkedWeekID", losers: losers, keeper: collapse.keeper)
            repointStringKey(type: EventGroceryCodec.recordType, field: "mergedIntoWeekID", losers: losers, keeper: collapse.keeper)
        }
        try await engine.sendUntilDrained()   // re-parents LAND before the deletes (kills the cascade race)
        for collapse in collapses { for loser in collapse.losers { engine.delete(id(loser)) } }
        return collapses
    }

    private func repointStringKey(type: String, field: String, losers: Set<String>, keeper: String) {
        for rec in engine.store.records(ofType: type) where losers.contains(rec[field] as? String ?? "") {
            rec[field] = keeper as CKRecordValue; engine.save(rec)
        }
    }

    // MARK: audit prune (keep N newest batches/week; cascade-delete the rest + their events)

    @discardableResult
    public func pruneAudit(weekID: String, keep: Int) -> AuditPruneResult {
        let batches = engine.store.records(ofType: Self.batchType)
            .filter { refName($0["week"]) == weekID }
            .map { WeekChangeBatch(recordName: $0.recordID.recordName, weekID: weekID, createdAt: batchClock($0)) }
        let result = pruneAuditBatches(batches, policy: RetentionPolicy(maxBatchesPerWeek: keep))
        for name in result.prune { engine.deleteCascading(id(name)) }   // sweeps WeekChangeEvent children
        return result
    }

    // weekStart Date → "yyyy-MM-dd" stable grouping key (the manifest stores weekStart as a Date).
    private func weekStartKey(_ r: CKRecord) -> String {
        guard let d = r["weekStart"] as? Date else { return "" }
        return Self.dayFmt.string(from: d)
    }
    // createdAt Date → epoch-MILLISECOND clock for the newest-first prune ordering. Milliseconds
    // (not seconds) so a burst of batches created in the same wall-clock second still orders by
    // creation time; a true same-ms tie falls to pruneAuditBatches' deterministic recordName tiebreak.
    private func batchClock(_ r: CKRecord) -> SyncClock {
        guard let d = r["createdAt"] as? Date else { return 0 }
        return Int(d.timeIntervalSince1970 * 1000)
    }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
#endif
