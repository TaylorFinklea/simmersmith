import Foundation

/// Cross-record repair duties beyond per-field merge (SP-A §5.3 / §6). These run
/// after a batch of CKSyncEngine changes lands, over the affected sibling/parent
/// set — the per-record resolver can't see siblings. Pure functions returning the
/// repaired set so the caller enqueues the writes/deletes.
public enum ConflictRepair {

    // MARK: - Grocery dedupe (semantic keeper + EventGroceryItem repointing — M68)

    public struct GroceryDedupeResult: Equatable {
        public var keepers: [GroceryItem]             // survivors (rolled-up), to SAVE
        public var tombstoned: [GroceryItem]          // losers, isUserRemoved=true, to SAVE (NOT delete)
        public var repointedLinks: [EventGroceryItem] // links whose merged_into moved
    }

    /// Port of `dedupe_week_grocery` (grocery.py:739-856). Losers are TOMBSTONED
    /// (`isUserRemoved = true`), never hard-deleted — a hard delete breaks idempotency
    /// (a peer that hasn't seen the dedup re-rolls the loser's quantity into the keeper →
    /// double count) and loses the sticky tombstone the resolver relies on. The input is
    /// filtered to live (non-tombstoned) rows for the same reason (grocery.py:763).
    ///
    /// Keeper policy verbatim: prefer the earliest-created auto-aggregated row
    /// (`source_meals` populated AND not user-added), else the earliest-created row. The
    /// keeper absorbs the loser's quantities (rounded), merged `source_meals`, and any
    /// sticky user investment it lacks (overrides + check state), then every
    /// `EventGroceryItem.mergedIntoGroceryItemID` off the loser is repointed onto the
    /// keeper (M68) so a later unmerge subtracts from the surviving row.
    public static func dedupeGrocery(
        items: [GroceryItem], eventLinks: [EventGroceryItem]
    ) -> GroceryDedupeResult {
        let live = items.filter { !$0.isUserRemoved }   // grocery.py:763 — tombstones don't dedupe

        var linksByTarget: [String: [EventGroceryItem]] = [:]
        for link in eventLinks {
            if let target = link.mergedIntoGroceryItemID {
                linksByTarget[target, default: []].append(link)
            }
        }

        // Group by (normalized_name, unit), preserving created order within each group.
        var order: [String] = []
        var groups: [String: [GroceryItem]] = [:]
        for item in live.sorted(by: { ($0.createdAt, $0.recordName) < ($1.createdAt, $1.recordName) }) {
            let key = "\(item.normalizedName.lowercased())\u{1}\(item.unit.lowercased())"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(item)
        }

        var keepers: [GroceryItem] = []
        var tombstoned: [GroceryItem] = []
        var repointed: [String: EventGroceryItem] = [:]   // by recordName

        for key in order {
            let group = groups[key]!
            guard group.count > 1 else { keepers.append(group[0]); continue }
            var keeper = Self.keeper(of: group)
            for loser in group where loser.recordName != keeper.recordName {
                keeper.totalQuantity = Self.roundedSum(keeper.totalQuantity, loser.totalQuantity)
                keeper.eventQuantity = Self.roundedSum(keeper.eventQuantity, loser.eventQuantity)
                if !loser.sourceMeals.trimmingCharacters(in: .whitespaces).isEmpty {
                    keeper.sourceMeals = Self.mergeSourceMeals(keeper.sourceMeals, loser.sourceMeals)
                }
                // Promote user investment the keeper lacks.
                if keeper.quantityOverride == nil { keeper.quantityOverride = loser.quantityOverride }
                if (keeper.unitOverride ?? "").isEmpty, let u = loser.unitOverride, !u.isEmpty { keeper.unitOverride = u }
                if (keeper.notesOverride ?? "").isEmpty, let n = loser.notesOverride, !n.isEmpty { keeper.notesOverride = n }
                if loser.check.isChecked && !keeper.check.isChecked { keeper.check = loser.check }
                // Downgrade a user-added keeper if a non-user-added duplicate exists.
                if keeper.isUserAdded && !loser.isUserAdded { keeper.isUserAdded = false }
                // Repoint event links off the loser onto the keeper (M68).
                for var link in linksByTarget[loser.recordName] ?? [] {
                    link.mergedIntoGroceryItemID = keeper.recordName
                    repointed[link.recordName] = link
                    linksByTarget[keeper.recordName, default: []].append(link)
                }
                // TOMBSTONE the loser (sticky, monotonic) — never hard-delete.
                var dead = loser
                dead.isUserRemoved = true
                tombstoned.append(dead)
            }
            keepers.append(keeper)
        }

        return GroceryDedupeResult(
            keepers: keepers.sorted { $0.recordName < $1.recordName },
            tombstoned: tombstoned.sorted { $0.recordName < $1.recordName },
            repointedLinks: repointed.values.sorted { $0.recordName < $1.recordName }
        )
    }

    /// Keeper-pick (grocery.py:798-805): earliest-created auto-aggregated row (source_meals
    /// populated, not user-added), else the earliest-created row. recordName breaks ties.
    static func keeper(of group: [GroceryItem]) -> GroceryItem {
        let auto = group.filter { !$0.isUserAdded && !$0.sourceMeals.trimmingCharacters(in: .whitespaces).isEmpty }
        if let k = auto.min(by: { ($0.createdAt, $0.recordName) < ($1.createdAt, $1.recordName) }) {
            return k
        }
        return group.min(by: { ($0.createdAt, $0.recordName) < ($1.createdAt, $1.recordName) })!
    }

    static func roundedSum(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case (nil, nil): return nil
        case let (x?, nil): return x
        case let (nil, y?): return y
        case let (x?, y?): return ((x + y) * 100).rounded() / 100   // round(…, 2) like prod
        }
    }

    /// Concatenate + dedupe + sort `source_meals` entries (grocery.py:821-827).
    static func mergeSourceMeals(_ a: String, _ b: String) -> String {
        let parts = (a + ";" + b)
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(parts).sorted().joined(separator: "; ")
    }

    // MARK: - Duplicate slot repair (the swap had no DEFERRABLE equivalent)

    /// Ensure no two meals share a `(weekID, dayName, slot)`. Keeper per collision =
    /// lowest `(sortOrder, recordName)`; the rest move to a free slot from the
    /// vocabulary, else a deterministic synthetic slot (never two-in-one-slot).
    public static func repairDuplicateSlots(_ meals: [WeekMeal], slots: [String]) -> [WeekMeal] {
        func dayKey(_ m: WeekMeal) -> String { "\(m.weekID)\u{1}\(m.dayName)" }

        var byCollision: [String: [WeekMeal]] = [:]  // "week\u1day\u1slot" → meals
        for m in meals { byCollision["\(dayKey(m))\u{1}\(m.slot)", default: []].append(m) }

        // PRE-SEED `occupied` with every KEEPER's slot (each group's idx-0 keeper; a singleton's
        // sole member). Building it lazily during relocation is order-dependent (Swift dict
        // iteration is unordered): a loser could be relocated onto a slot a not-yet-visited
        // singleton/keeper already holds — creating a NEW duplicate. Seeding up front fixes that.
        var occupied: [String: Set<String>] = [:]   // "week\u1day" → settled slots
        for (_, group) in byCollision {
            let keeper = group.min { ($0.sortOrder, $0.recordName) < ($1.sortOrder, $1.recordName) }!
            occupied[dayKey(keeper), default: []].insert(keeper.slot)
        }

        var result: [WeekMeal] = []
        for (_, group) in byCollision {
            let ordered = group.sorted { ($0.sortOrder, $0.recordName) < ($1.sortOrder, $1.recordName) }
            for (idx, var meal) in ordered.enumerated() {
                if idx == 0 { result.append(meal); continue }   // keeper — slot already seeded
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

    public struct WeekCollapse: Equatable, Sendable { public let keeper: String; public let losers: [String] }

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
