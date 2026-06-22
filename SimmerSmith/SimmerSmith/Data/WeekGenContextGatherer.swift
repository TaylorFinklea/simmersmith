#if canImport(CloudKit)
import Foundation
import SimmerSmithKit
import AIProviderKit

// SP-C AI-1 — on-device planning-context gather.
//
// Swift mirror of `app/services/week_planner.py::gather_planning_context`, but the
// inputs come from the new CloudKit household store + the private plane (NOT Fly):
//   • pantry staples         → PantryRepository.pantryItems (active items)
//   • dietary goal           → ProfileRepository.dietaryGoal (private plane)
//   • avoids + ALLERGIES     → ingredientPreferences (choiceMode "avoid"/"allergy")
//   • recent meal names      → WeekRepository.weeks (last few, deduped)
//   • term aliases           → AliasRepository.aliases (household shorthand)
// Every field degrades gracefully on empties — the server handled empties, so does this.
//
// The catalog avoid/allergy split mirrors the Python: choiceMode == "allergy" feeds
// BOTH the emphasized allergy line AND hard_avoids (defense in depth), and is the
// source of truth for the post-parse allergy hard-gate.
//
// Pure transform (`build(...)`) takes already-gathered domain values so it is unit-
// testable; `AppState.gatherWeekGenContext()` supplies them from the live repos.

enum WeekGenContextGatherer {

    /// The number of recent weeks to scan for meal-history dedup (matches the
    /// server's `list_weeks(..., limit=4)`).
    static let recentWeekLimit = 4
    /// The cap on recent-meal names injected into the prompt (matches the server's
    /// `recent_meal_names[:60]`).
    static let recentMealCap = 60

    /// Build a `PlanningContext` from the gathered domain values. `excludeWeekId`
    /// drops the week being (re)generated from the recent-meal history, mirroring
    /// the Python's `exclude_week_id` guard.
    static func build(
        pantryStaples: [String],
        dietaryGoal: DietaryGoal?,
        ingredientPreferences: [IngredientPreference],
        recentWeeks: [WeekSnapshot],
        termAliases: [String: String],
        excludeWeekId: String? = nil
    ) -> PlanningContext {
        // Catalog avoid / allergy split (active prefs only).
        var catalogAvoids: [String] = []
        var allergies: [String] = []
        for pref in ingredientPreferences where pref.active {
            guard pref.choiceMode == "avoid" || pref.choiceMode == "allergy" else { continue }
            let name = pref.baseIngredientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if pref.choiceMode == "allergy" {
                allergies.append(name)
            } else {
                catalogAvoids.append(name)
            }
        }

        // Allergies are merged into hard_avoids too (the server does this so the
        // generic MUST AVOID block covers them even if the allergy line is ignored).
        let mergedAvoids = dedupePreservingOrder(catalogAvoids + allergies)
        let dedupedAllergies = dedupePreservingOrder(allergies)

        // Recent meal names: scan recent weeks (newest first), dedup by name, drop the
        // excluded week, cap at 60.
        var seen = Set<String>()
        var recentMeals: [String] = []
        for week in recentWeeks.prefix(recentWeekLimit) {
            if let excludeWeekId, week.weekId == excludeWeekId { continue }
            for meal in week.meals {
                let name = meal.recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !seen.contains(name) {
                    seen.insert(name)
                    recentMeals.append(name)
                }
            }
        }
        if recentMeals.count > recentMealCap {
            recentMeals = Array(recentMeals.prefix(recentMealCap))
        }

        // Dietary goal → context value (only when a positive calorie target is set).
        var goalContext: DietaryGoalContext?
        if let goal = dietaryGoal, goal.dailyCalories > 0 {
            goalContext = DietaryGoalContext(
                goalType: goal.goalType.rawValue,
                dailyCalories: goal.dailyCalories,
                proteinG: goal.proteinG,
                carbsG: goal.carbsG,
                fatG: goal.fatG,
                fiberG: goal.fiberG,
                notes: goal.notes
            )
        }

        return PlanningContext(
            hardAvoids: mergedAvoids,
            strongLikes: [],        // AI: preference-signal context deferred (later AI slice)
            likedCuisines: [],      // AI: preference-signal context deferred
            dislikedCuisines: [],   // AI: preference-signal context deferred
            brands: [],             // AI: preference-signal context deferred
            staples: pantryStaples.sorted(),
            recentMeals: recentMeals,
            rules: [],              // AI: preference-signal context deferred
            dietaryGoal: goalContext,
            allergies: dedupedAllergies,
            termAliases: termAliases
        )
    }

    private static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in items where !seen.contains(item) {
            seen.insert(item)
            out.append(item)
        }
        return out
    }
}
#endif
