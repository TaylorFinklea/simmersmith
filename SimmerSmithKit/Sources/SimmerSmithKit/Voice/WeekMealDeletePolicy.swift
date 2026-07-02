import Foundation

// simmersmith-eky (HIGH data-loss) — WeekRepository.saveWeekMeals is a full-REPLACE write:
// any existing `.weekMeal` whose recordName isn't in the caller's `meals` payload gets deleted.
// Every WeekView mutator builds `meals` from a possibly-stale `displayedWeek` snapshot, so a
// concurrent partner add the snapshot never saw was silently deleted. BASELINE-AWARE DELETE
// fixes this: a store meal is deleted only if the caller's SOURCE snapshot both knew about it
// (it's in `known`) AND the caller's desired set dropped it. An id the caller never saw (not in
// `known`) is never a deletion candidate, no matter what `desired` contains — a concurrent add is
// always kept.
public enum WeekMealDeletePolicy {

    /// The store record names to delete, given the store's current meal ids (`existing`), the
    /// caller's desired post-write set (`desired`), and the meal ids present in the caller's
    /// source snapshot (`known`). Only ids the caller both knew about and dropped are deleted;
    /// an `existing` id absent from `known` (a concurrent write the caller's snapshot never saw)
    /// is always preserved.
    public static func toDelete(existing: Set<String>, desired: Set<String>, known: Set<String>) -> Set<String> {
        existing.subtracting(desired).intersection(known)
    }
}
