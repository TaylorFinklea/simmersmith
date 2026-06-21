import Foundation

// SP-C AI-1 — Week-gen prompt builder (pure, headless-testable).
//
// Faithful Swift port of `app/services/week_planner.py::_build_system_prompt`
// (plus `ai.unit_system_directive` and the visible-profile field selection).
// FIDELITY to the server is the bar: a degraded prompt produces worse plans, so
// the section ordering, the exact constraint phrasings, the ±10% calorie rule,
// the recipe-reuse cap, the allergy emphasis line, and the response-shape block
// all match the Python. Reviews scrutinize this against the authority.
//
// What is intentionally NOT ported here:
//   • `_call_ai_provider` — that is the BYOKeyProvider / AIService transport.
//   • `gather_planning_context` — that reads the DB; the app-layer gather mirrors
//     it against the CloudKit/private-plane stores and produces a `PlanningContext`.

public enum WeekGenPrompt {

    /// The seven weekday labels, Monday-first, matching `week_planner.DAYS`.
    public static let days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// The three meal slots per day, matching `week_planner.SLOTS`.
    public static let slots = ["breakfast", "lunch", "dinner"]

    /// The visible profile keys, in the exact order `_build_system_prompt` iterates
    /// them. The app-layer gather supplies values for whichever of these it has.
    public static let profileKeys = [
        "household_name", "household_adults", "household_kids",
        "dietary_constraints", "cuisine_preferences", "budget_notes",
        "food_principles", "convenience_rules", "breakfast_strategy",
        "lunch_strategy", "snack_strategy", "leftovers_policy",
        "planning_avoids",
    ]

    /// Prompt fragment that locks AI-produced recipes to the user's preferred unit
    /// system. Injected near the top of the system prompt so the rule outranks any
    /// unit hints the LLM picked up. Faithful port of `ai.unit_system_directive`.
    public static func unitSystemDirective(_ system: UnitSystem) -> String {
        switch system {
        case .metric:
            return "UNIT SYSTEM — METRIC ONLY. All ingredient quantities must use "
                + "metric units (g, kg, ml, l). All temperatures must be in °C. "
                + "Convert any imperial values from your sources before returning. "
                + "Do not mix systems."
        case .us:
            return "UNIT SYSTEM — US CUSTOMARY ONLY. All ingredient quantities must use "
                + "US customary units (cups, tbsp, tsp, oz, lb, fl oz). All temperatures "
                + "must be in °F. Convert any metric values from your sources before "
                + "returning. Do not mix systems."
        }
    }

    /// Build the system prompt for a week starting `weekStart`. Faithful port of
    /// `_build_system_prompt(user_settings, week_start, context)`.
    ///
    /// - Parameters:
    ///   - profileSettings: the visible profile settings map (AI-secret keys already
    ///     excluded by the caller, mirroring `visible_profile_settings`).
    ///   - weekStart: the Monday the plan begins on. Day labels are derived from it.
    ///   - context: the gathered planning context, or nil to omit the enriched
    ///     sections + extra rules (matching the Python's `context is None` branch).
    ///   - unitSystem: the user's unit system (defaults to `.us` like the server).
    public static func buildSystemPrompt(
        profileSettings: [String: String],
        weekStart: Date,
        context: PlanningContext?,
        unitSystem: UnitSystem = .us
    ) -> String {
        // Profile block — title-cased label + value for each non-empty visible key,
        // in the fixed key order.
        var profileLines: [String] = []
        for key in profileKeys {
            let val = (profileSettings[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty {
                profileLines.append("- \(titleCase(key.replacingOccurrences(of: "_", with: " "))): \(val)")
            }
        }
        let profileBlock = profileLines.isEmpty ? "(no preferences set)" : profileLines.joined(separator: "\n")

        // Optional context sections (alias preamble → preference signals → staples →
        // recent meals → dietary goal).
        var contextSections = ""
        if let context {
            var sections: [String] = []

            // Household shorthand dictionary — top of the context block so the AI sees
            // alias expansions BEFORE it interprets the user's prompt.
            if !context.termAliases.isEmpty {
                let aliasLines = context.termAliases
                    .sorted { $0.key < $1.key }
                    .map { "- \($0.key) → \($0.value)" }
                sections.append(
                    "Household shorthand (treat each term as if the user typed the expansion):\n"
                        + aliasLines.joined(separator: "\n")
                )
            }

            // Preference signals.
            var prefLines: [String] = []
            if !context.allergies.isEmpty {
                // Allergies get their own line above the generic avoids so the AI treats
                // them as HARD constraints, not preferences.
                prefLines.append(
                    "- HARD ALLERGIES — NEVER include these or any dish containing them: "
                        + context.allergies.joined(separator: ", ")
                )
            }
            if !context.hardAvoids.isEmpty {
                prefLines.append("- MUST AVOID: \(context.hardAvoids.joined(separator: ", "))")
            }
            if !context.strongLikes.isEmpty {
                prefLines.append("- Strongly likes: \(context.strongLikes.joined(separator: ", "))")
            }
            if !context.brands.isEmpty {
                prefLines.append("- Preferred brands: \(context.brands.joined(separator: ", "))")
            }
            if !context.likedCuisines.isEmpty {
                prefLines.append("- Liked cuisines: \(context.likedCuisines.joined(separator: ", "))")
            }
            if !context.dislikedCuisines.isEmpty {
                prefLines.append("- Disliked cuisines: \(context.dislikedCuisines.joined(separator: ", "))")
            }
            if !prefLines.isEmpty {
                sections.append("Preference signals:\n" + prefLines.joined(separator: "\n"))
            }

            // Pantry staples.
            if !context.staples.isEmpty {
                sections.append(
                    "Pantry staples (always available, use freely):\n"
                        + context.staples.joined(separator: ", ")
                )
            }

            // Recent meal history.
            if !context.recentMeals.isEmpty {
                sections.append(
                    "Recent meals (avoid repeating these for variety):\n"
                        + context.recentMeals.joined(separator: ", ")
                )
            }

            // Dietary goal (only when a positive calorie target is set).
            if let goal = context.dietaryGoal, goal.dailyCalories > 0 {
                var goalLines: [String] = []
                var target = "- Daily target: \(goal.dailyCalories) calories,"
                    + " \(goal.proteinG)g protein, \(goal.carbsG)g carbs, \(goal.fatG)g fat"
                if let fiber = goal.fiberG, fiber != 0 {
                    target += ", \(fiber)g fiber"
                }
                goalLines.append(target)
                goalLines.append("- Goal type: \(goal.goalType)")
                let trimmedNotes = goal.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedNotes.isEmpty {
                    goalLines.append("- Notes: \(trimmedNotes)")
                }
                sections.append("Dietary goal (per-person, per-day):\n" + goalLines.joined(separator: "\n"))
            }

            if !sections.isEmpty {
                contextSections = "\n\n" + sections.joined(separator: "\n\n")
            }
        }

        // Enhanced rules — only present when context is present.
        var extraRules = ""
        if let context {
            var extraLines: [String] = []
            if !context.hardAvoids.isEmpty {
                extraLines.append("- NEVER include ingredients from the MUST AVOID list")
            }
            if !context.strongLikes.isEmpty || !context.likedCuisines.isEmpty {
                extraLines.append("- Favor ingredients and cuisines the household strongly likes")
            }
            if !context.dislikedCuisines.isEmpty {
                extraLines.append("- Avoid cuisines the household dislikes unless specifically requested")
            }
            if !context.recentMeals.isEmpty {
                extraLines.append("- Avoid repeating any meal from the recent meals list above")
            }
            extraLines.append("- A single recipe may appear at most 3 times in one week (e.g., leftovers)")
            if !context.staples.isEmpty {
                extraLines.append("- Leverage pantry staples when possible to reduce grocery costs")
            }
            if let goal = context.dietaryGoal, goal.dailyCalories > 0 {
                extraLines.append(
                    "- Design each day so the three meals together land within ±10% of the daily calorie target"
                )
                extraLines.append(
                    "- Prioritize recipes that help hit the protein target (especially at dinner)"
                )
            }
            if !extraLines.isEmpty {
                extraRules = "\n" + extraLines.joined(separator: "\n")
            }
        }

        // Day labels + the example dates embedded in the response-shape block.
        let dates = (0..<7).map { isoDay(weekStart, offsetDays: $0) }
        let dayLabels = (0..<7).map { "\(days[$0]) (\(dates[$0]))" }

        let unitsDirective = unitSystemDirective(unitSystem)

        return """
        You are SimmerSmith, an AI meal planning assistant.

        \(unitsDirective)

        Generate a complete 7-day meal plan based on the user's request and their profile.

        User profile:
        \(profileBlock)\(contextSections)

        Week: \(dayLabels[0]) through \(dayLabels[6])

        Return ONLY valid JSON with this exact structure:
        {
          "recipes": [
            {
              "name": "Recipe Name",
              "meal_type": "dinner",
              "cuisine": "Italian",
              "servings": 4,
              "prep_minutes": 15,
              "cook_minutes": 30,
              "ingredients": [
                {"ingredient_name": "chicken breast", "quantity": 2.0, "unit": "lb", "prep": "cubed", "category": "protein"}
              ],
              "steps": [
                {"instruction": "Step 1 description"},
                {"instruction": "Step 2 description"}
              ]
            }
          ],
          "meal_plan": [
            {"day_name": "Monday", "meal_date": "\(dates[0])", "slot": "breakfast", "recipe_name": "Recipe Name"},
            {"day_name": "Monday", "meal_date": "\(dates[0])", "slot": "lunch", "recipe_name": "Recipe Name"},
            {"day_name": "Monday", "meal_date": "\(dates[0])", "slot": "dinner", "recipe_name": "Recipe Name"}
          ]
        }

        Rules:
        - Generate 3 meals per day (breakfast, lunch, dinner) for all 7 days = 21 meals total
        - Each recipe_name in meal_plan must match exactly one recipe in the recipes array
        - Recipes can be reused across multiple meals (e.g., leftovers)
        - Include realistic ingredients with quantities and units
        - Include clear, numbered cooking steps
        - Respect the user's dietary constraints and preferences
        - Vary cuisines and cooking styles across the week\(extraRules)
        """
    }

    /// The default user prompt when the caller supplies none — matches the server's
    /// `user_prompt or "Plan a balanced, varied week of meals."`.
    public static let defaultUserPrompt = "Plan a balanced, varied week of meals."

    // MARK: - Helpers

    /// Title-case each whitespace-separated word (mirrors Python `str.title()` for the
    /// label keys, which are simple lowercase words joined by spaces).
    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    /// `(weekStart + offsetDays).isoformat()` in UTC day granularity (yyyy-MM-dd),
    /// matching the server's date-only `week_start` arithmetic.
    static func isoDay(_ weekStart: Date, offsetDays: Int) -> String {
        let day = Calendar.utc.date(byAdding: .day, value: offsetDays, to: weekStart) ?? weekStart
        return Self.isoDayFormatter.string(from: day)
    }

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

extension Calendar {
    /// A UTC-pinned Gregorian calendar for date-only week arithmetic (matches the
    /// server's date math, which has no timezone).
    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}
