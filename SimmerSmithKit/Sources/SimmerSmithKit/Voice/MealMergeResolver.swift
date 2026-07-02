import Foundation

// SP-C bead simmersmith-enx (CRITICAL data-loss) — the assistant tool `weeks_update_meals`
// decodes the model's `meals` array and hands it to `WeekRepository.saveWeekMeals`, which is a
// full REPLACE: any existing `.weekMeal` whose recordName isn't in the passed set gets deleted
// (CloudKit has no trash). If the model sends only the meal it means to change, the rest of the
// week silently vanishes. The voice path had the identical bug, fixed by
// `VoicePlanResolver.merge` (build 141) — this generalizes the same MERGE-by-(day, slot)
// approach for the assistant tool, adding an explicit CLEAR marker the voice path didn't need
// (voice already drops "skip" entries upstream in `resolve`, so it never emits an empty slot).
public enum MealMergeResolver {

    /// MERGE `updates` (the model's `weeks_update_meals` payload) INTO the week's current
    /// meals, keyed by (dayName, slot). Every existing slot the model doesn't mention is left
    /// untouched — this is the fix: the model should only ever send the meals it wants to
    /// add/change/clear, never the whole week.
    ///
    /// An update whose `recipeName` is empty (after trimming) is the CLEAR marker: it removes
    /// that one slot instead of upserting it. `recipeName` is a required field on
    /// `MealUpdateRequest`/the tool's JSON schema, so an empty string is available as an
    /// explicit "clear this slot" signal without adding a new field or touching the schema.
    ///
    /// A non-empty update upserts the slot, preserving the existing meal's `mealId` (never the
    /// update's, which the model typically doesn't know) so it updates the record in place
    /// rather than creating a duplicate.
    public static func fold(updates: [MealUpdateRequest], into existing: [MealUpdateRequest]) -> [MealUpdateRequest] {
        func key(_ m: MealUpdateRequest) -> String { "\(m.dayName)|\(m.slot)" }
        var bySlot: [String: MealUpdateRequest] = [:]
        var order: [String] = []
        for m in existing {
            let k = key(m)
            if bySlot[k] == nil { order.append(k) }
            bySlot[k] = m
        }
        for u in updates {
            let k = key(u)
            let isClear = u.recipeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isClear {
                bySlot.removeValue(forKey: k)
                continue
            }
            let existingId = bySlot[k]?.mealId   // keep the slot's record id so it updates in place
            if bySlot[k] == nil { order.append(k) }
            bySlot[k] = MealUpdateRequest(
                mealId: existingId, dayName: u.dayName, mealDate: u.mealDate, slot: u.slot,
                recipeId: u.recipeId, recipeName: u.recipeName, servings: u.servings,
                scaleMultiplier: u.scaleMultiplier, notes: u.notes, approved: u.approved
            )
        }
        return order.compactMap { bySlot[$0] }
    }
}
