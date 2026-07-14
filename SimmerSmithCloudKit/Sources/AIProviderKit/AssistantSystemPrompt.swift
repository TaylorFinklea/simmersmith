import Foundation

/// SP-C AI-5 — the assistant's system prompt, ported from
/// `app/services/assistant_ai.py`'s `build_planning_system_prompt`.
///
/// The on-device assistant is a tool-calling agent: it READS and MODIFIES the user's
/// data through tools rather than emitting structured JSON (unlike the AI-1 week-gen /
/// AI-2 recipe drafts, which use the strict-JSON path). The prompt locks in that
/// behavior — call the tool, don't narrate; report tool failures verbatim; end with a
/// short natural-language summary; prefer small edits over a full regenerate.
public enum AssistantSystemPrompt {
    /// Build the assistant system prompt. Faithful port of
    /// `build_planning_system_prompt(thread_title, planning_context, user_settings)`.
    ///
    /// - Parameters:
    ///   - threadTitle: the thread's title; defaults to "Weekly Planning" when empty.
    ///   - planningContext: an optional context block (household preferences, the
    ///     current week summary, …) appended verbatim, matching the server.
    ///   - unitSystem: the user's unit system → the leading units directive (reuses
    ///     `WeekGenPrompt.unitSystemDirective`, the port of `ai.unit_system_directive`).
    public static func build(
        threadTitle: String,
        planningContext: String = "",
        unitSystem: UnitSystem = .us
    ) -> String {
        let unitsDirective = WeekGenPrompt.unitSystemDirective(unitSystem)
        let title = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Weekly Planning"
            : threadTitle
        return """
        You are SimmerSmith's Planning Assistant, a conversational agent that helps \
        a single user plan their week of meals.
        \(unitsDirective)
        You have tools that can READ and MODIFY the user's current week in real time. \
        When the user asks for a change, CALL THE TOOL rather than describing what you would do. \
        Do not claim to have done something you haven't called a tool for.
        When a tool returns ok=false, tell the user the tool's detail verbatim and propose a recovery.
        After you call tools, end your turn with a short, natural-language summary of what changed. \
        Do NOT wrap your final reply in JSON or markdown fences.
        Prefer small edits to a full regenerate: use weeks_update_meals to add, swap, remove, or rebalance \
        meals, and only call weeks_apply_ai_draft (which replaces the whole week) when the user asks for a \
        full reset or a brand-new plan. weeks_update_meals is MERGE-ONLY — send only the (day_name, slot) \
        entries you want to add or change; every slot you omit is left untouched, so do NOT resend the whole \
        week. Echo day_name and slot VERBATIM (exact casing) as they appear in weeks_get / weeks_get_current \
        results — the merge key is case-sensitive, and a casing drift silently creates a duplicate slot \
        instead of updating the existing one.
        Be concise. Two or three sentences per reply is plenty.

        Thread: \(title)
        \(planningContext)
        """
    }

    /// Render a gathered `PlanningContext` into the `planningContext` block `build(...)`
    /// appends verbatim. Bead simmersmith-48y: the assistant previously called `build`
    /// with this left empty, so the model had no date, no allergies/avoids, and no idea
    /// which week it was looking at — it could only discover a week id via
    /// `weeks_get_current`, which itself defaulted to `appState.currentWeek`, so a turn
    /// started while the user browsed "next week" silently edited the wrong one.
    ///
    /// Mirrors `WeekGenPrompt.buildSystemPrompt`'s "Preference signals" section
    /// ordering — allergies FIRST and phrased as a hard constraint, ahead of the
    /// generic avoids/likes/cuisines — so the assistant sees the same safety framing
    /// week-gen does. This block is defense in depth for steering the model away from
    /// a doomed write; the actual invariant is enforced at the `ToolRegistry` executor
    /// (`weeks_update_meals` / `recipes_save`), not here.
    ///
    /// - Parameters:
    ///   - context: the gathered household context (allergies/avoids/likes/cuisines).
    ///   - activeWeekSummary: a short description of the week the user is currently
    ///     looking at (id + a few key facts), or "" when none is resolvable yet.
    ///   - todayISO: today's date as "yyyy-MM-dd", so the model can reason about
    ///     relative requests ("push Tuesday's dinner to tomorrow") without a tool call.
    public static func renderPlanningContext(
        _ context: PlanningContext,
        activeWeekSummary: String,
        todayISO: String
    ) -> String {
        var sections: [String] = []

        var prefLines: [String] = []
        if !context.allergies.isEmpty {
            prefLines.append(
                "HARD ALLERGIES — NEVER include these or any dish containing them, and NEVER "
                    + "save a recipe or meal containing them: " + context.allergies.joined(separator: ", ")
            )
        }
        if !context.hardAvoids.isEmpty {
            prefLines.append("MUST AVOID: " + context.hardAvoids.joined(separator: ", "))
        }
        if !context.strongLikes.isEmpty {
            prefLines.append("Strongly likes: " + context.strongLikes.joined(separator: ", "))
        }
        if !context.brands.isEmpty {
            prefLines.append("Preferred brands: " + context.brands.joined(separator: ", "))
        }
        if !context.likedCuisines.isEmpty {
            prefLines.append("Liked cuisines: " + context.likedCuisines.joined(separator: ", "))
        }
        if !context.dislikedCuisines.isEmpty {
            prefLines.append("Disliked cuisines: " + context.dislikedCuisines.joined(separator: ", "))
        }
        if !prefLines.isEmpty {
            sections.append("Household preferences:\n" + prefLines.joined(separator: "\n"))
        }

        sections.append("Today: \(todayISO)")

        if !activeWeekSummary.isEmpty {
            sections.append(activeWeekSummary)
        }

        return sections.joined(separator: "\n\n")
    }
}
