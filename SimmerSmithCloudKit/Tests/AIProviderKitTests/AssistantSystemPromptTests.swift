import Foundation
import Testing
@testable import AIProviderKit

// bead simmersmith-48y — the assistant's system prompt used to call `build(...)` with
// `planningContext` left empty: no date, no allergies/avoids, no week context. This
// verifies `renderPlanningContext` puts allergies FIRST (mirroring
// `WeekGenPrompt.buildSystemPrompt`'s "Preference signals" ordering) and that `build`
// embeds the rendered block verbatim.

@Suite("AssistantSystemPrompt")
struct AssistantSystemPromptTests {

    @Test("allergies render ahead of avoids/likes/cuisines")
    func allergiesRenderFirst() throws {
        let context = PlanningContext(
            hardAvoids: ["cilantro"],
            strongLikes: ["garlic"],
            likedCuisines: ["Thai"],
            dislikedCuisines: ["German"],
            allergies: ["peanut", "shellfish"]
        )
        let rendered = AssistantSystemPrompt.renderPlanningContext(
            context, activeWeekSummary: "", todayISO: "2026-07-14"
        )
        let allergyRange = try #require(rendered.range(of: "HARD ALLERGIES"))
        let avoidRange = try #require(rendered.range(of: "MUST AVOID"))
        let likesRange = try #require(rendered.range(of: "Strongly likes"))
        #expect(allergyRange.lowerBound < avoidRange.lowerBound)
        #expect(avoidRange.lowerBound < likesRange.lowerBound)
        #expect(rendered.contains("peanut, shellfish"))
    }

    @Test("empty context still carries today's date")
    func emptyContextKeepsToday() {
        let rendered = AssistantSystemPrompt.renderPlanningContext(
            PlanningContext(), activeWeekSummary: "", todayISO: "2026-07-14"
        )
        #expect(rendered.contains("Today: 2026-07-14"))
        #expect(!rendered.contains("HARD ALLERGIES"))
    }

    @Test("the active week summary is appended verbatim")
    func activeWeekSummaryAppended() {
        let summary = "Active week — id: week-1, starts 2026-07-13, status: staging.\n- Monday dinner: Tacos"
        let rendered = AssistantSystemPrompt.renderPlanningContext(
            PlanningContext(allergies: ["peanut"]), activeWeekSummary: summary, todayISO: "2026-07-14"
        )
        #expect(rendered.contains(summary))
    }

    @Test("build embeds the rendered planning context verbatim under the thread line")
    func buildEmbedsPlanningContext() {
        let planningContext = AssistantSystemPrompt.renderPlanningContext(
            PlanningContext(allergies: ["peanut"]),
            activeWeekSummary: "Active week — id: week-1, starts 2026-07-13, status: staging.",
            todayISO: "2026-07-14"
        )
        let prompt = AssistantSystemPrompt.build(
            threadTitle: "Weekly Planning", planningContext: planningContext, unitSystem: .us
        )
        #expect(prompt.contains("HARD ALLERGIES"))
        #expect(prompt.contains("peanut"))
        #expect(prompt.contains("Today: 2026-07-14"))
        #expect(prompt.contains("week-1"))
    }
}
