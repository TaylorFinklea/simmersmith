import Foundation
import SimmerSmithKit
import AIProviderKit

/// SP-C voice week-planning — layer 2 fallback (cloud parse). When on-device parse isn't
/// available (ineligible hardware / AI disabled) or it errors, send the transcript to the BYO
/// cloud LLM for a ONE-SHOT structured parse and rejoin the same resolve → review → apply
/// pipeline. Reuses `AIService.generate(AIRequest(wantsStructuredJSON:))` — the seam week /
/// recipe / event generation already use — NOT the assistant tool-loop (which would commit
/// before the review screen). Nothing persists here.
enum CloudParseService {

    static func parse(transcript: String, using aiSvc: AIService) async throws -> ParsedWeeklyPlan {
        let request = AIRequest(
            feature: .companionDraft,
            systemPrompt: systemPrompt,
            prompt: transcript,
            wantsStructuredJSON: true
        )
        let response = try await aiSvc.generate(request)
        // Reuse the shipping extractor (strips <think> tags + code fences, then braces) — a
        // reasoning-enabled open model can leak think tags despite the prompt.
        let json = BYOKeyProvider.extractJSONObject(response.text)
        return try SimmerSmithJSONCoding.makeDecoder().decode(ParsedWeeklyPlan.self, from: Data(json.utf8))
    }

    // snake_case keys → SimmerSmithJSONCoding's convertFromSnakeCase maps raw_dish → rawDish, etc.
    private static let systemPrompt = """
    You EXTRACT meals from the user's text into JSON — you do NOT plan or complete a week. \
    Output ONLY a JSON object of this exact shape, no prose, no markdown fences:
    {"entries":[{"day":"Monday","slot":"dinner","raw_dish":"tacos","intent":"recipe"}]}
    Rules:
    - Output exactly one entry per meal the user EXPLICITLY states. Never add days, meals, or \
    slots they did not say. If they mention none, return {"entries":[]}.
    - day: "Monday"…"Sunday", or "today"/"tomorrow"/"tonight" exactly as said.
    - slot: "breakfast" | "lunch" | "dinner".
    - raw_dish: the dish exactly as spoken.
    - intent: "eatOut" for ordering out / restaurants / takeout / pizza, "leftovers" for \
    leftovers, "skip" to skip a meal, otherwise "recipe".
    Example — input "Tuna for lunch on Tuesday" → \
    {"entries":[{"day":"Tuesday","slot":"lunch","raw_dish":"tuna","intent":"recipe"}]}
    """
}
