import Foundation
import Testing
@testable import AIProviderKit

// SP-D vision port — prompt builders + structured-output parsers.
//
// Verifies fidelity to `app/services/vision_ai.py`'s two JSON contracts
// (identify_ingredient / check_cooking_progress): the prompts embed the rules +
// schema, and the parsers round-trip a sample response while malformed/empty
// input throws.

// MARK: - (a) Identify ingredient

@Test("identify-ingredient system prompt matches vision_ai._INGREDIENT_SYSTEM")
func identifySystemPrompt() {
    #expect(VisionPrompt.identifyIngredientSystemPrompt.contains("culinary expert"))
    #expect(VisionPrompt.identifyIngredientSystemPrompt.contains("Return ONLY a valid JSON object."))
}

@Test("identify-ingredient user prompt embeds the rules + schema")
func identifyIngredientPromptStructure() {
    let prompt = VisionPrompt.identifyIngredientPrompt()
    #expect(prompt.contains("Identify the ingredient in this photo."))
    #expect(prompt.contains("`confidence`"))
    #expect(prompt.contains("\"cuisine_uses\""))
    #expect(prompt.contains("\"recipe_match_terms\""))
}

@Test("parseIdentification round-trips a full identification response")
func parseIdentificationRoundTrip() throws {
    let raw = """
    {
      "name": "habanero pepper",
      "confidence": "high",
      "common_names": ["Scotch bonnet-like", "habanero"],
      "cuisine_uses": [{"country": "Mexico", "dish": "salsa"}, {"country": "Jamaica", "dish": "jerk sauce"}],
      "recipe_match_terms": ["habanero", "hot pepper"],
      "notes": "Handle with gloves."
    }
    """
    let result = try VisionAIParser.parseIdentification(raw)
    #expect(result.name == "habanero pepper")
    #expect(result.confidence == "high")
    #expect(result.commonNames == ["Scotch bonnet-like", "habanero"])
    #expect(result.cuisineUses.count == 2)
    #expect(result.cuisineUses[0].country == "Mexico")
    #expect(result.cuisineUses[0].dish == "salsa")
    #expect(result.recipeMatchTerms == ["habanero", "hot pepper"])
    #expect(result.notes == "Handle with gloves.")
}

@Test("parseIdentification salvages a fenced/prose-wrapped response")
func parseIdentificationFenced() throws {
    let raw = """
    Sure, here you go:
    ```json
    {"name": "Thai basil", "confidence": "medium"}
    ```
    """
    let result = try VisionAIParser.parseIdentification(raw)
    #expect(result.name == "Thai basil")
    #expect(result.confidence == "medium")
}

@Test("parseIdentification throws invalidJSON on non-JSON input")
func parseIdentificationInvalidJSON() {
    #expect(throws: VisionAIParseError.invalidJSON) {
        _ = try VisionAIParser.parseIdentification("not json at all")
    }
}

@Test("parseIdentification throws emptyResult when name is blank")
func parseIdentificationEmptyResult() {
    #expect(throws: VisionAIParseError.emptyResult) {
        _ = try VisionAIParser.parseIdentification(#"{"name": "", "confidence": "low"}"#)
    }
}

// MARK: - (b) Cook check

@Test("cook-check system prompt matches vision_ai._COOK_CHECK_SYSTEM")
func cookCheckSystemPrompt() {
    #expect(VisionPrompt.cookCheckSystemPrompt.contains("calm, helpful cooking coach"))
    #expect(VisionPrompt.cookCheckSystemPrompt.contains("Return ONLY a valid JSON object."))
}

@Test("cook-check prompt embeds recipe title, step text, and context")
func cookCheckPromptStructure() {
    let prompt = VisionPrompt.cookCheckPrompt(
        recipeTitle: "Roast Chicken",
        stepText: "Sear the skin side down for 5 minutes.",
        recipeContext: "French"
    )
    #expect(prompt.contains("Recipe: Roast Chicken"))
    #expect(prompt.contains("Current step: Sear the skin side down for 5 minutes."))
    #expect(prompt.contains("Recipe context: French"))
    #expect(prompt.contains("'on_track', 'needs_more_time', 'concerning'"))
}

@Test("cook-check prompt falls back to placeholders for blank title/step, and omits the context line when blank")
func cookCheckPromptBlankFallbacks() {
    let prompt = VisionPrompt.cookCheckPrompt(recipeTitle: "  ", stepText: "", recipeContext: "  ")
    #expect(prompt.contains("Recipe: (untitled)"))
    #expect(prompt.contains("Current step: (no step text)"))
    #expect(!prompt.contains("Recipe context:"))
}

@Test("parseCookCheck round-trips a full cook-check response")
func parseCookCheckRoundTrip() throws {
    let raw = #"{"verdict": "needs_more_time", "tip": "Give it 5 more minutes.", "suggested_minutes_remaining": 5}"#
    let result = try VisionAIParser.parseCookCheck(raw)
    #expect(result.verdict == "needs_more_time")
    #expect(result.tip == "Give it 5 more minutes.")
    #expect(result.suggestedMinutesRemaining == 5)
}

@Test("parseCookCheck defaults suggestedMinutesRemaining to 0 when absent")
func parseCookCheckDefaultsMinutes() throws {
    let raw = #"{"verdict": "on_track", "tip": "Looking great."}"#
    let result = try VisionAIParser.parseCookCheck(raw)
    #expect(result.suggestedMinutesRemaining == 0)
}

@Test("parseCookCheck throws invalidJSON on non-JSON input")
func parseCookCheckInvalidJSON() {
    #expect(throws: VisionAIParseError.invalidJSON) {
        _ = try VisionAIParser.parseCookCheck("nope")
    }
}
