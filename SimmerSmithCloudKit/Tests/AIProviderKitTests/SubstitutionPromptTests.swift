import Foundation
import Testing
@testable import AIProviderKit

// SP-D substitution port — prompt builder + structured-output parser.
//
// Verifies fidelity to `app/services/substitution_ai.py`: the prompt embeds the
// recipe/target ingredient/hint/preferences + schema, and the parser round-trips
// a sample response while filtering blank names and capping at MAX_SUGGESTIONS.

@Test("substitution prompt embeds recipe context, target ingredient, hint, preferences, and schema")
func substitutionPromptStructure() {
    let prompt = SubstitutionPrompt.build(
        recipeName: "Chicken Alfredo",
        cuisine: "Italian",
        mealType: "dinner",
        allIngredients: ["1 lb fettuccine", "1 cup heavy cream"],
        targetIngredientLine: "1 cup heavy cream",
        hint: "something dairy-free",
        preferenceNotes: ["- AVOID: peanuts (allergy)"],
        unit: .us
    )
    #expect(prompt.contains("UNIT SYSTEM — US CUSTOMARY ONLY"))
    #expect(prompt.contains("Recipe: Chicken Alfredo"))
    #expect(prompt.contains("Cuisine: Italian"))
    #expect(prompt.contains("Meal type: dinner"))
    #expect(prompt.contains("- 1 lb fettuccine"))
    #expect(prompt.contains("Ingredient to substitute: 1 cup heavy cream"))
    #expect(prompt.contains("User hint: something dairy-free"))
    #expect(prompt.contains("User ingredient preferences:\n- AVOID: peanuts (allergy)"))
    #expect(prompt.contains("\"suggestions\""))
    #expect(prompt.contains("3-5 substitutes"))
}

@Test("substitution prompt omits hint/preferences lines when absent, and defaults blank cuisine/mealType to 'unspecified'")
func substitutionPromptOmitsOptionalLines() {
    let prompt = SubstitutionPrompt.build(
        recipeName: "Mystery Dish",
        cuisine: "",
        mealType: "",
        allIngredients: ["salt"],
        targetIngredientLine: "salt"
    )
    #expect(!prompt.contains("User hint:"))
    #expect(!prompt.contains("User ingredient preferences:"))
    #expect(prompt.contains("Cuisine: unspecified"))
    #expect(prompt.contains("Meal type: unspecified"))
}

@Test("SubstitutionAIParser round-trips a full suggestions response")
func substitutionParserRoundTrip() throws {
    let raw = """
    {"suggestions": [
      {"name": "coconut cream", "reason": "Rich and dairy-free.", "quantity": "1", "unit": "cup"},
      {"name": "cashew cream", "reason": "Neutral, blends smoothly.", "quantity": "", "unit": ""}
    ]}
    """
    let suggestions = try SubstitutionAIParser.parse(raw)
    #expect(suggestions.count == 2)
    #expect(suggestions[0].name == "coconut cream")
    #expect(suggestions[0].reason == "Rich and dairy-free.")
    #expect(suggestions[0].quantity == "1")
    #expect(suggestions[0].unit == "cup")
    #expect(suggestions[1].name == "cashew cream")
}

@Test("SubstitutionAIParser filters out blank names")
func substitutionParserFiltersBlankNames() throws {
    let raw = """
    {"suggestions": [
      {"name": "  ", "reason": "x"},
      {"name": "oat milk", "reason": "Mild flavor."}
    ]}
    """
    let suggestions = try SubstitutionAIParser.parse(raw)
    #expect(suggestions.count == 1)
    #expect(suggestions[0].name == "oat milk")
}

@Test("SubstitutionAIParser caps the result at MAX_SUGGESTIONS (5)")
func substitutionParserCapsAtFive() throws {
    let entries = (1...8).map { "{\"name\": \"sub\($0)\"}" }.joined(separator: ",")
    let raw = "{\"suggestions\": [\(entries)]}"
    let suggestions = try SubstitutionAIParser.parse(raw)
    #expect(suggestions.count == SubstitutionPrompt.maxSuggestions)
    #expect(suggestions.first?.name == "sub1")
}

@Test("SubstitutionAIParser salvages a fenced/prose-wrapped response")
func substitutionParserFenced() throws {
    let raw = """
    Sure:
    ```json
    {"suggestions": [{"name": "buttermilk", "reason": "Tangy, similar acidity."}]}
    ```
    """
    let suggestions = try SubstitutionAIParser.parse(raw)
    #expect(suggestions.count == 1)
    #expect(suggestions[0].name == "buttermilk")
}

@Test("SubstitutionAIParser returns an empty list (not an error) when suggestions is empty")
func substitutionParserEmptyIsNotAnError() throws {
    let suggestions = try SubstitutionAIParser.parse(#"{"suggestions": []}"#)
    #expect(suggestions.isEmpty)
}

@Test("SubstitutionAIParser throws invalidJSON on non-JSON input")
func substitutionParserInvalidJSON() {
    #expect(throws: SubstitutionAIParseError.invalidJSON) {
        _ = try SubstitutionAIParser.parse("nope")
    }
}
