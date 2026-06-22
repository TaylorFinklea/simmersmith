import Foundation

// SP-C AI-3 — Day-rebalance prompt builder (pure, headless-testable).
//
// Faithful Swift port of `app/services/week_planner.py::rebalance_day`. The server's
// rebalance REUSES the week-gen system prompt (`_build_system_prompt`) verbatim and
// only swaps the user prompt: instead of "plan a week", it asks the model to replan
// ONE day's three meals within ±5% of the daily calorie target while honoring every
// rule already in the system prompt. The response shape is identical to week-gen
// (`{recipes, meal_plan}`), so it parses with `MealPlanParser` and applies through
// `WeekRepository.saveWeekMeals` — the same path week-gen uses.
//
// This file therefore carries only the rebalance-specific pieces:
//   • `systemPrompt(...)` — delegates to `WeekGenPrompt.buildSystemPrompt` (so the
//     dietary-goal block, the allergy line, and the ±10% week rule are all present,
//     and the day-scoped user prompt tightens to ±5% on top).
//   • `userPrompt(...)` — the day-scoped replan instruction (faithful port of the
//     `user_prompt` string `rebalance_day` builds, including the optional deficit note).
//   • `applyDayDefaults(...)` — stamps `meal_date` / `day_name` onto any meal the model
//     left them off (port of the `meal.setdefault("meal_date"/"day_name", ...)` pass).
//
// What is intentionally NOT ported here: `_call_ai_provider` (the AIService transport)
// and `_extract_json` (handled by `MealPlanParser.stripCodeFence`). The allergy
// hard-gate the app runs after parsing is `MealPlanParser.enforceAllergyGate` — shared
// with week-gen.

public enum DayRebalancePrompt {

    /// The rebalance system prompt — the SAME `_build_system_prompt` week-gen uses.
    /// Delegates to `WeekGenPrompt.buildSystemPrompt` so the profile block, the
    /// context-enriched sections (allergies / avoids / staples / recents / dietary
    /// goal), and the extra rules are byte-for-byte the week-gen prompt. The day-scoped
    /// `userPrompt` rides on top to narrow the model to one day.
    public static func systemPrompt(
        profileSettings: [String: String],
        weekStart: Date,
        context: PlanningContext?,
        unitSystem: UnitSystem = .us
    ) -> String {
        WeekGenPrompt.buildSystemPrompt(
            profileSettings: profileSettings,
            weekStart: weekStart,
            context: context,
            unitSystem: unitSystem
        )
    }

    /// Build the day-scoped user prompt. Faithful port of the `user_prompt` string in
    /// `rebalance_day`: replan only `dayName` (`targetDateISO`) with three meals within
    /// **±5%** of the daily calorie target, respecting every rule already in the system
    /// prompt, and return exactly 3 `meal_plan` entries all stamped with that date +
    /// day name. An optional `existingDeficitNote` is appended verbatim (the server's
    /// `existing_deficit_note`).
    ///
    /// - Parameters:
    ///   - dayName: the weekday label being replanned (e.g. "Wednesday").
    ///   - targetDateISO: that day's ISO `yyyy-MM-dd` date (the app formats the domain
    ///     `Date`; use `WeekGenPrompt.isoDay` to derive it from a week start + offset).
    ///   - existingDeficitNote: optional extra guidance (e.g. "The day currently runs
    ///     400 kcal under target."). Appended only when non-empty.
    public static func userPrompt(
        dayName: String,
        targetDateISO: String,
        existingDeficitNote: String = ""
    ) -> String {
        var prompt = "Replan only \(dayName) (\(targetDateISO)) with three meals "
            + "(breakfast, lunch, dinner) that land within ±5% of the daily calorie "
            + "target and respect every rule already stated in the system prompt. "
            + "Return a JSON object with `recipes` for the new meals and a "
            + "`meal_plan` array containing exactly 3 entries, all for "
            + "meal_date \"\(targetDateISO)\" and day_name \"\(dayName)\"."
        let trimmedNote = existingDeficitNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            prompt += " \(trimmedNote)"
        }
        return prompt
    }

    /// Stamp the target date + day name onto any rebalanced meal the model left them
    /// off. Faithful port of the `meal.setdefault("meal_date", target_date.isoformat())`
    /// / `meal.setdefault("day_name", day_name)` pass in `rebalance_day`: a slot that
    /// already carries a non-empty value keeps it; an empty one is backfilled. Returns a
    /// new result; the input is unchanged.
    public static func applyDayDefaults(
        _ result: MealPlanResult,
        dayName: String,
        targetDateISO: String
    ) -> MealPlanResult {
        let patched = result.mealPlan.map { slot -> MealPlanSlot in
            var s = slot
            if s.mealDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s.mealDate = targetDateISO
            }
            if s.dayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                s.dayName = dayName
            }
            return s
        }
        return MealPlanResult(recipes: result.recipes, mealPlan: patched)
    }
}
