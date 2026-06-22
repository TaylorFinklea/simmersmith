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
        Prefer small edits (add/swap/remove/rebalance) to a full regenerate — only call generate_week_plan \
        when the user asks for a full reset.
        Be concise. Two or three sentences per reply is plenty.

        Thread: \(title)
        \(planningContext)
        """
    }
}
