import Foundation

/// Cross-record repair duties beyond per-field merge (SP-A §5.3 / §6). These run
/// after a batch of CKSyncEngine changes lands, over the affected sibling/parent
/// set — the per-record resolver can't see siblings. Pure functions returning the
/// repaired set so the caller enqueues the writes/deletes.
public enum ConflictRepair {

    // MARK: - Grocery dedupe (semantic keeper + EventGroceryItem repointing — M68)

    public struct GroceryDedupeResult: Equatable {
        public var keepers: [GroceryItem]            // survivors (rolled-up)
        public var deletedRecordNames: [String]      // losers to delete
        public var repointedLinks: [EventGroceryItem] // links whose merged_into moved
    }

    /// Port of `dedupe_week_grocery` (grocery.py:739-855), keeper policy verbatim:
    /// prefer the auto-aggregated row with `source_meals` populated, else the
    /// earliest-created — then **repoint every `EventGroceryItem.mergedIntoGroceryItemID`
    /// onto the keeper** (the M68 fix, grocery.py:768-780) so a later unmerge
    /// subtracts from the surviving row, not a deleted one. A structural
    /// "lower recordName" rule would strand these pointers — that was the bug the
    /// adversarial review caught.
    public static func dedupeGrocery(
        items: [GroceryItem], eventLinks: [EventGroceryItem]
    ) -> GroceryDedupeResult {
        // group by the collapse key (normalized_name, unit)
        var groups: [String: [GroceryItem]] = [:]
        for item in items {
            groups["\(item.normalizedName.lowercased())\u{1}\(item.unit.lowercased())", default: []].append(item)
        }

        var keepers: [GroceryItem] = []
        var deleted: [String] = []
        var loserToKeeper: [String: String] = [:]   // loser recordName → keeper recordName

        for (_, group) in groups {
            guard group.count > 1 else { keepers.append(contentsOf: group); continue }
            var keeper = Self.keeper(of: group)
            for loser in group where loser.recordName != keeper.recordName {
                // roll the loser's auto + event portion into the keeper
                keeper.totalQuantity = Self.sum(keeper.totalQuantity, loser.totalQuantity)
                keeper.eventQuantity = Self.sum(keeper.eventQuantity, loser.eventQuantity)
                deleted.append(loser.recordName)
                loserToKeeper[loser.recordName] = keeper.recordName
            }
            keepers.append(keeper)
        }

        // repoint every event link off a deleted row onto its keeper
        var repointed: [EventGroceryItem] = []
        for var link in eventLinks {
            if let target = link.mergedIntoGroceryItemID, let keeper = loserToKeeper[target] {
                link.mergedIntoGroceryItemID = keeper
                repointed.append(link)
            }
        }

        return GroceryDedupeResult(
            keepers: keepers.sorted { $0.recordName < $1.recordName },
            deletedRecordNames: deleted.sorted(),
            repointedLinks: repointed.sorted { $0.recordName < $1.recordName }
        )
    }

    static func keeper(of group: [GroceryItem]) -> GroceryItem {
        let autoAggregated = group.filter { !$0.isUserAdded && !$0.isEventOnly && !$0.sourceMeals.isEmpty }
        if let k = autoAggregated.min(by: { ($0.createdAt, $0.recordName) < ($1.createdAt, $1.recordName) }) {
            return k
        }
        return group.min(by: { ($0.createdAt, $0.recordName) < ($1.createdAt, $1.recordName) })!
    }

    static func sum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (x?, nil): return x
        case let (nil, y?): return y
        case let (x?, y?): return x + y
        }
    }

    // MARK: - Duplicate slot repair (the swap had no DEFERRABLE equivalent)

    /// Ensure no two meals share a `(weekID, dayName, slot)`. Keeper per collision =
    /// lowest `(sortOrder, recordName)`; the rest move to a free slot from the
    /// vocabulary, else a deterministic synthetic slot (never two-in-one-slot).
    public static func repairDuplicateSlots(_ meals: [WeekMeal], slots: [String]) -> [WeekMeal] {
        var occupied: [String: Set<String>] = [:]   // "week\u1day" → used slots
        func dayKey(_ m: WeekMeal) -> String { "\(m.weekID)\u{1}\(m.dayName)" }

        var byCollision: [String: [WeekMeal]] = [:]  // "week\u1day\u1slot" → meals
        for m in meals { byCollision["\(dayKey(m))\u{1}\(m.slot)", default: []].append(m) }

        var result: [WeekMeal] = []
        for (_, group) in byCollision {
            let ordered = group.sorted { ($0.sortOrder, $0.recordName) < ($1.sortOrder, $1.recordName) }
            for (idx, var meal) in ordered.enumerated() {
                if idx == 0 {
                    occupied[dayKey(meal), default: []].insert(meal.slot)
                    result.append(meal)
                    continue
                }
                let used = occupied[dayKey(meal)] ?? []
                if let free = slots.first(where: { !used.contains($0) }) {
                    meal.slot = free
                } else {
                    meal.slot = "\(meal.slot)#\(meal.recordName)"   // deterministic, unique
                }
                occupied[dayKey(meal), default: []].insert(meal.slot)
                result.append(meal)
            }
        }
        return result.sorted { $0.recordName < $1.recordName }
    }

    // MARK: - Duplicate week collapse (UNIQUE(household_id, week_start))

    public struct WeekCollapse: Equatable { public let keeper: String; public let losers: [String] }

    /// Two devices creating the same `week_start` → keeper = lowest recordName; the
    /// caller re-parents losers' subtrees onto the keeper, then deletes losers.
    public static func collapseDuplicateWeeks(_ weeks: [Week]) -> [WeekCollapse] {
        var byStart: [String: [Week]] = [:]
        for w in weeks { byStart[w.weekStart, default: []].append(w) }
        var out: [WeekCollapse] = []
        for (_, group) in byStart where group.count > 1 {
            let names = group.map(\.recordName).sorted()
            out.append(WeekCollapse(keeper: names[0], losers: Array(names.dropFirst())))
        }
        return out.sorted { $0.keeper < $1.keeper }
    }

    // MARK: - Sort-order reconcile + dangling-ref null

    /// Gap-free, collision-free `sortOrder` over a sibling set, stable on
    /// `(sortOrder, recordName)`.
    public static func reconcileSortOrder(_ meals: [WeekMeal]) -> [WeekMeal] {
        meals.sorted { ($0.sortOrder, $0.recordName) < ($1.sortOrder, $1.recordName) }
            .enumerated()
            .map { idx, meal in var m = meal; m.sortOrder = idx; return m }
    }

    /// Client-enforced SET NULL: drop a soft reference whose target no longer exists.
    public static func nullingDangling(_ ref: String?, existing: Set<String>) -> String? {
        guard let ref else { return nil }
        return existing.contains(ref) ? ref : nil
    }
}
