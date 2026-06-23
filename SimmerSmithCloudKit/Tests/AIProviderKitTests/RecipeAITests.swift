import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-2 — recipe-AI prompt builders + structured-output parsers.
//
// Verifies, for each feature (extraction / variation / suggestion / companion /
// refine / web-search):
//   • the builder embeds the recipe/goal context + the JSON response contract
//     (fidelity to recipe_ai.py + recipe_search_ai.py intent), and
//   • the matching parser round-trips a sample response, while malformed / empty
//     input throws.

private func sampleRecipe() -> RecipeContext {
    RecipeContext(
        name: "Chicken Alfredo",
        mealType: "dinner",
        cuisine: "Italian",
        servings: 4,
        prepMinutes: 15,
        cookMinutes: 25,
        tags: ["pasta", "weeknight"],
        ingredients: ["1 lb fettuccine", "2 chicken breasts, cubed", "1 cup heavy cream", "1/2 cup parmesan, grated"],
        steps: ["Cook the pasta.", "Sear the chicken.", "Build the cream sauce and toss."],
        notes: "Family favorite."
    )
}

// MARK: - (a) Extraction

@Test("extraction prompt embeds the raw text, the schema, and a units directive")
func extractionPromptStructure() {
    let prompt = RecipeAIPrompt.extractionPrompt(
        rawText: "Grandma's Pancakes\n2 cups flour\nMix and cook.",
        unit: .us
    )
    #expect(prompt.contains("UNIT SYSTEM — US CUSTOMARY ONLY"))
    #expect(prompt.contains("You are a recipe parser."))
    // Source text is embedded verbatim.
    #expect(prompt.contains("Grandma's Pancakes"))
    #expect(prompt.contains("2 cups flour"))
    // Don't-hallucinate guard + the recipe JSON contract.
    #expect(prompt.contains("do not invent"))
    #expect(prompt.contains("\"ingredient_name\""))
    #expect(prompt.contains("\"steps\""))
}

@Test("extraction prompt honors the metric unit system")
func extractionPromptMetric() {
    let prompt = RecipeAIPrompt.extractionPrompt(rawText: "x", unit: .metric)
    #expect(prompt.contains("UNIT SYSTEM — METRIC ONLY"))
}

@Test("parseRecipe round-trips a single-recipe extraction response")
func parseRecipeRoundTrip() throws {
    let raw = """
    {
      "name": "Buttermilk Pancakes",
      "cuisine": "American",
      "meal_type": "breakfast",
      "servings": "4",
      "prep_minutes": 10,
      "cook_minutes": 15,
      "tags": ["breakfast", "easy"],
      "ingredients": [
        {"ingredient_name": "all-purpose flour", "quantity": 2, "unit": "cup", "prep": "sifted", "category": "Pantry"},
        {"ingredient_name": "buttermilk", "quantity": "1.5", "unit": "cup"}
      ],
      "steps": [{"instruction": "Whisk the dry ingredients."}, {"instruction": "Fold in the wet, then griddle."}],
      "notes": "Rest the batter 5 minutes."
    }
    """
    let recipe = try RecipeAIParser.parseRecipe(raw)
    #expect(recipe.name == "Buttermilk Pancakes")
    #expect(recipe.mealType == "breakfast")
    #expect(recipe.servings == 4)            // string "4" coerced to Double
    #expect(recipe.prepMinutes == 10)
    #expect(recipe.tags == ["breakfast", "easy"])
    #expect(recipe.ingredients.count == 2)
    #expect(recipe.ingredients[0].quantity == 2)
    #expect(recipe.ingredients[1].quantity == 1.5)  // string "1.5" coerced
    #expect(recipe.steps.count == 2)
    #expect(recipe.steps[1].instruction == "Fold in the wet, then griddle.")
}

@Test("parseRecipe tolerates a markdown code fence and salvages a wrapped object")
func parseRecipeFenceAndSalvage() throws {
    let fenced = """
    ```json
    {"name": "Toast", "ingredients": [{"ingredient_name": "bread"}]}
    ```
    """
    #expect(try RecipeAIParser.parseRecipe(fenced).name == "Toast")

    let wrapped = "Here is the recipe you asked for:\n{\"name\": \"Toast\", \"steps\": []}\nHope it helps!"
    #expect(try RecipeAIParser.parseRecipe(wrapped).name == "Toast")
}

@Test("parseRecipe throws on non-JSON and on a nameless recipe")
func parseRecipeMalformed() {
    #expect(throws: RecipeAIParseError.invalidJSON) {
        _ = try RecipeAIParser.parseRecipe("not json at all")
    }
    #expect(throws: RecipeAIParseError.emptyRecipe) {
        _ = try RecipeAIParser.parseRecipe(#"{"name": "  ", "ingredients": []}"#)
    }
}

// MARK: - (b) Variation

@Test("variation prompt injects the recognized goal's guidance, prefix, and tags")
func variationPromptRecognizedGoal() {
    let prompt = RecipeAIPrompt.variationPrompt(recipe: sampleRecipe(), goal: "make it vegetarian")
    // Server guidance note for the vegetarian preset.
    #expect(prompt.contains("Replace meat with satisfying vegetarian protein"))
    #expect(prompt.contains("Vegetarian"))     // title prefix
    #expect(prompt.contains("vegetarian"))      // extra tag
    // Recipe context is present.
    #expect(prompt.contains("Name: Chicken Alfredo"))
    #expect(prompt.contains("1 lb fettuccine"))
    // Envelope contract.
    #expect(prompt.contains("\"rationale\""))
    #expect(prompt.contains("\"recipe\""))
}

@Test("variation prompt falls through to a general instruction for an arbitrary goal")
func variationPromptArbitraryGoal() {
    let prompt = RecipeAIPrompt.variationPrompt(recipe: sampleRecipe(), goal: "make it spicier")
    #expect(prompt.contains("make it spicier"))
    #expect(prompt.contains("keeping the dish recognizable"))
    // No preset matched, so no preset guidance note leaks in.
    #expect(!prompt.contains("Replace meat with satisfying vegetarian protein"))
}

@Test("parseVariation round-trips a {rationale, recipe} envelope")
func parseVariationRoundTrip() throws {
    let raw = """
    {
      "rationale": "Swapped chicken for tofu and cream for cashew cream.",
      "recipe": {
        "name": "Vegetarian Chicken Alfredo",
        "cuisine": "Italian",
        "tags": ["pasta", "vegetarian"],
        "ingredients": [{"ingredient_name": "extra-firm tofu", "quantity": 14, "unit": "oz"}],
        "steps": [{"instruction": "Press and cube the tofu."}]
      }
    }
    """
    let result = try RecipeAIParser.parseVariation(raw)
    #expect(result.rationale.contains("tofu"))
    #expect(result.recipe.name == "Vegetarian Chicken Alfredo")
    #expect(result.recipe.tags.contains("vegetarian"))
    #expect(result.recipe.ingredients.first?.ingredientName == "extra-firm tofu")
}

@Test("parseVariation throws when the recipe has no name")
func parseVariationMalformed() {
    #expect(throws: RecipeAIParseError.emptyRecipe) {
        _ = try RecipeAIParser.parseVariation(#"{"rationale": "x", "recipe": {"name": ""}}"#)
    }
    #expect(throws: RecipeAIParseError.invalidJSON) {
        _ = try RecipeAIParser.parseVariation("nope")
    }
}

// MARK: - (c) Suggestion

@Test("suggestion prompt sets the resolved meal type, note, and avoid-list")
func suggestionPromptStructure() {
    let prompt = RecipeAIPrompt.suggestionPrompt(
        goal: "easy weeknight dinner",
        recentNames: ["Chicken Alfredo", "Taco Night"]
    )
    #expect(prompt.contains("Target meal type: dinner."))
    #expect(prompt.contains("comes together on a weeknight"))
    // Avoid list embeds the household's recent recipes.
    #expect(prompt.contains("- Chicken Alfredo"))
    #expect(prompt.contains("- Taco Night"))
    #expect(prompt.contains("\"rationale\""))
}

@Test("suggestion prompt handles an arbitrary meal-name goal without a preset")
func suggestionPromptArbitrary() {
    let prompt = RecipeAIPrompt.suggestionPrompt(goal: "shakshuka")
    #expect(prompt.contains("shakshuka"))
    #expect(prompt.contains("Pick the most fitting meal type"))
}

@Test("parseVariation round-trips a suggestion envelope (same shape)")
func parseSuggestionRoundTrip() throws {
    let raw = #"{"rationale": "A fast skillet dinner.", "recipe": {"name": "Sheet Pan Gnocchi", "meal_type": "dinner"}}"#
    let result = try RecipeAIParser.parseVariation(raw)
    #expect(result.recipe.name == "Sheet Pan Gnocchi")
    #expect(result.recipe.mealType == "dinner")
}

// MARK: - (d) Companion

@Test("companion prompt fixes the three option ids and the side/sauce contract")
func companionPromptStructure() {
    let prompt = RecipeAIPrompt.companionPrompt(recipe: sampleRecipe())
    #expect(prompt.contains("exactly three companions"))
    #expect(prompt.contains("\"vegetable-side\""))
    #expect(prompt.contains("\"starch-side\""))
    #expect(prompt.contains("\"sauce\""))
    #expect(prompt.contains("Name: Chicken Alfredo"))
    #expect(prompt.contains("\"options\""))
}

@Test("parseCompanion round-trips a {rationale, options[]} envelope")
func parseCompanionRoundTrip() throws {
    let raw = """
    {
      "rationale": "Three Italian-leaning companions to round out the plate.",
      "options": [
        {"option_id": "vegetable-side", "label": "Vegetable Side", "rationale": "Bright greens.",
         "recipe": {"name": "Garlic Broccolini", "ingredients": [{"ingredient_name": "broccolini"}]}},
        {"option_id": "starch-side", "label": "Starch Side", "rationale": "Soft starch.",
         "recipe": {"name": "Parmesan Polenta"}},
        {"option_id": "sauce", "label": "Sauce / Drizzle", "rationale": "Fresh finish.",
         "recipe": {"name": "Gremolata"}}
      ]
    }
    """
    let result = try RecipeAIParser.parseCompanion(raw)
    #expect(result.options.count == 3)
    #expect(result.options[0].optionId == "vegetable-side")
    #expect(result.options[0].recipe.name == "Garlic Broccolini")
    #expect(result.options[2].optionId == "sauce")
}

@Test("parseCompanion throws when options are empty or input is malformed")
func parseCompanionMalformed() {
    #expect(throws: RecipeAIParseError.noOptions) {
        _ = try RecipeAIParser.parseCompanion(#"{"rationale": "x", "options": []}"#)
    }
    #expect(throws: RecipeAIParseError.invalidJSON) {
        _ = try RecipeAIParser.parseCompanion("<html>")
    }
}

// MARK: - (e) Refine

@Test("refine prompt embeds the instruction, the draft, and the context hint")
func refinePromptStructure() {
    let prompt = RecipeAIPrompt.refinePrompt(
        draft: sampleRecipe(),
        instruction: "add more garlic",
        contextHint: "user is cooking for guests"
    )
    #expect(prompt.contains("add more garlic"))
    #expect(prompt.contains("Change only what the instruction requires"))
    #expect(prompt.contains("Return the COMPLETE refined recipe"))
    #expect(prompt.contains("Name: Chicken Alfredo"))
    #expect(prompt.contains("Additional context: user is cooking for guests"))
}

@Test("refine prompt omits the context line when no hint is given")
func refinePromptNoHint() {
    let prompt = RecipeAIPrompt.refinePrompt(draft: sampleRecipe(), instruction: "halve it")
    #expect(!prompt.contains("Additional context:"))
}

// MARK: - Web search

@Test("web-search input ports the 'pick one, cite the source' framing")
func webSearchInputStructure() {
    let prompt = RecipeAIPrompt.webSearchInput(query: "best crispy waffles")
    #expect(prompt.contains("You are a recipe finder."))
    #expect(prompt.contains("best crispy waffles"))
    #expect(prompt.contains("Pick exactly ONE recipe"))
    #expect(prompt.contains("source_url"))
    #expect(prompt.contains("reputable sources"))
}

@Test("parseRecipe round-trips a web-search recipe with its cited source")
func parseWebSearchRecipe() throws {
    let raw = """
    {
      "name": "Yeast-Raised Waffles",
      "source_url": "https://www.seriouseats.com/waffles",
      "source_label": "Serious Eats",
      "ingredients": [{"ingredient_name": "flour", "quantity": 2, "unit": "cup"}],
      "steps": [{"instruction": "Mix and rest overnight."}],
      "notes": "Highest-rated waffle for crisp edges."
    }
    """
    let recipe = try RecipeAIParser.parseRecipe(raw)
    #expect(recipe.name == "Yeast-Raised Waffles")
    #expect(recipe.sourceUrl == "https://www.seriouseats.com/waffles")
    #expect(recipe.sourceLabel == "Serious Eats")
}

// MARK: - Goal routing (ports recipe_ai's preset resolution)

@Test("variation goal resolution mirrors resolve_variation_preset's keyword map")
func variationGoalRouting() {
    #expect(VariationGoal.resolve("low carb please")?.key == "low_carb")
    #expect(VariationGoal.resolve("DAIRY-FREE version")?.key == "dairy_free")
    #expect(VariationGoal.resolve("for the kids")?.key == "kid_friendly")
    #expect(VariationGoal.resolve("pantry friendly")?.key == "pantry_friendly")
    // Arbitrary goal: no preset (LLM honors it directly).
    #expect(VariationGoal.resolve("make it spicier") == nil)
}

@Test("suggestion goal resolution mirrors resolve_suggestion_preset's keyword map")
func suggestionGoalRouting() {
    #expect(SuggestionGoal.resolve("weeknight dinner")?.key == "weeknight_dinner")
    #expect(SuggestionGoal.resolve("breakfast ideas")?.key == "breakfast_rotation")
    #expect(SuggestionGoal.resolve("lunchbox friendly")?.key == "lunchbox_friendly")
    #expect(SuggestionGoal.resolve("kid friendly")?.key == "kid_friendly_dinner")
    #expect(SuggestionGoal.resolve("shakshuka") == nil)
}

@Test("normalizeGoal collapses non-alphanumerics like recipe_ai._normalized_goal")
func normalizeGoalPort() {
    #expect(normalizeGoal("Low-Carb!!!") == "low carb")
    #expect(normalizeGoal("  Kid_Friendly  ") == "kid friendly")
    #expect(normalizeGoal("VEGETARIAN") == "vegetarian")
}
