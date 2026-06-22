import Foundation

// SP-C AI-2 — Recipe-AI prompt builders (pure, headless-testable).
//
// Ports the INTENT of `app/services/recipe_ai.py` (variation / suggestion /
// companion) + `app/services/recipe_search_ai.py` (extraction-shaped output) to
// BYO-key LLM prompts. The server's recipe_ai.py is a deterministic RULE-ENGINE
// (preset ingredient-swap tables, a saved-recipe scorer, a static companion
// library); on-device with the user's own model we let the LLM produce the
// variation/suggestion/companion directly, but we PRESERVE the server's intent:
//   • Variation: the per-goal guidance notes + the goal→preset keyword routing
//     (`resolve_variation_preset`) become the LLM's instructions, and we keep the
//     server's `title_prefix` + `extra_tags` conventions.
//   • Suggestion: the per-goal meal-type + rationale-note intent
//     (`resolve_suggestion_preset` / `build_suggestion_draft`).
//   • Companion: 2-3 sides/sauces with the server's option ids
//     (`vegetable-side` / `starch-side` / `sauce`) and a flavor-profile lean
//     inferred from the anchor recipe (`_infer_companion_library_key`).
//   • Extraction + web-search: the single-recipe JSON schema + "pick one, cite the
//     source" framing from `recipe_search_ai._build_input`.
//
// What is intentionally NOT ported: `_call_*` transport (BYOKeyProvider/AIService),
// the DB reads (the app-layer gather supplies the recipe text), and the rule-engine
// swap tables (the LLM does the substitutions; the notes guide it).
//
// All builders are pure: they take the recipe/goal context and the unit system and
// return strings. The matching parsers live in `RecipeAISchema`.

public enum RecipeAIPrompt {

    // MARK: - Shared single-recipe JSON schema (mirrors recipe_search_ai schema_hint)

    /// The JSON object every recipe-AI prompt asks the model to return for a single
    /// recipe. Field set mirrors `recipe_search_ai.py::_build_input`'s `schema_hint`
    /// plus the `tags`/`category` fields the import path uses. Kept as one constant so
    /// every feature's instruction block stays consistent.
    static let recipeSchemaHint = """
    {
      "name": "Recipe Name",
      "source_url": "https://... (empty string if not from a web page)",
      "source_label": "site or source name (empty string if none)",
      "cuisine": "e.g. Italian",
      "meal_type": "breakfast | lunch | dinner | snack | dessert",
      "servings": 4,
      "prep_minutes": 15,
      "cook_minutes": 30,
      "tags": ["optional", "descriptive", "tags"],
      "ingredients": [
        {"ingredient_name": "all-purpose flour", "quantity": 1.5, "unit": "cup", "prep": "sifted", "category": "Pantry"}
      ],
      "steps": [
        {"instruction": "Step 1 description"},
        {"instruction": "Step 2 description"}
      ],
      "notes": "short note (rationale / why-this-pick / serving tip)"
    }
    """

    /// Render a `RecipeContext` into the plain-text block the variation / companion /
    /// refine prompts show the model. Mirrors how the server's payloads carry name,
    /// meal type, cuisine, ingredients, and ordered steps.
    static func recipeBlock(_ recipe: RecipeContext) -> String {
        var lines: [String] = []
        lines.append("Name: \(recipe.name)")
        if !recipe.mealType.isEmpty { lines.append("Meal type: \(recipe.mealType)") }
        if !recipe.cuisine.isEmpty { lines.append("Cuisine: \(recipe.cuisine)") }
        if let servings = recipe.servings { lines.append("Servings: \(formatNumber(servings))") }
        if let prep = recipe.prepMinutes { lines.append("Prep minutes: \(prep)") }
        if let cook = recipe.cookMinutes { lines.append("Cook minutes: \(cook)") }
        if !recipe.tags.isEmpty { lines.append("Tags: \(recipe.tags.joined(separator: ", "))") }

        if recipe.ingredients.isEmpty {
            lines.append("Ingredients: (none provided)")
        } else {
            lines.append("Ingredients:")
            for ing in recipe.ingredients { lines.append("- \(ing)") }
        }
        if recipe.steps.isEmpty {
            lines.append("Steps: (none provided)")
        } else {
            lines.append("Steps:")
            for (i, step) in recipe.steps.enumerated() { lines.append("\(i + 1). \(step)") }
        }
        if !recipe.notes.isEmpty { lines.append("Notes: \(recipe.notes)") }
        return lines.joined(separator: "\n")
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - (a) EXTRACTION (raw text / HTML → RecipeDraft)

    /// Build the prompt to EXTRACT a structured recipe from unstructured text (a
    /// pasted recipe, OCR output, or page text when JSON-LD is absent). Mirrors the
    /// import intent: clean the text into the canonical single-recipe JSON. `unit`
    /// locks the output unit system the way the server's `unit_system_directive` does.
    public static func extractionPrompt(
        rawText: String,
        unit: UnitSystem = .us
    ) -> String {
        """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are a recipe parser. Extract the recipe from the text below into a single \
        structured JSON object. Use ONLY what the text contains — do not invent \
        ingredients, steps, or times. Split combined ingredient lines into separate \
        entries (name, quantity, unit, prep). Keep the cooking steps in order and \
        strip any list numbers from the instruction text. If a field is unknown, use \
        an empty string (or omit numeric fields). Leave `source_url`/`source_label` \
        empty unless the text states them.

        Return ONLY a JSON object matching this schema:
        \(recipeSchemaHint)

        Recipe text:
        \"\"\"
        \(rawText.trimmingCharacters(in: .whitespacesAndNewlines))
        \"\"\"
        """
    }

    // MARK: - (b) VARIATION (recipe + goal → varied recipe + rationale)

    /// Build the prompt to produce a VARIATION of `recipe` toward `goal` (e.g.
    /// "vegetarian", "low-carb", "spicier", "quick"). Ports `recipe_ai`'s per-goal
    /// guidance: a recognized goal injects the server's guidance note + title prefix +
    /// tags intent; an unrecognized goal falls through to a general "honor the goal,
    /// keep the dish recognizable" instruction. The model returns
    /// `{rationale, recipe}` — the rationale mirrors the server's variation summary.
    public static func variationPrompt(
        recipe: RecipeContext,
        goal: String,
        unit: UnitSystem = .us
    ) -> String {
        let preset = VariationGoal.resolve(goal)
        let guidance = preset?.guidanceNote
            ?? "Honor the requested goal while keeping the dish recognizable and balanced."
        let titleHint = preset.map {
            "Prefix the new recipe name with \"\($0.titlePrefix)\" (unless it already starts that way)."
        } ?? "Give the variation a clear name that signals the change."
        let tagHint = preset.map {
            "Add these tags (plus the original recipe's tags): \($0.extraTags.joined(separator: ", "))."
        } ?? "Add a tag describing the goal."

        return """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are a recipe developer. Create a VARIATION of the recipe below toward this \
        goal: \(goal.trimmingCharacters(in: .whitespacesAndNewlines)).

        Guidance: \(guidance) Swap only what the goal requires, keep the rest of the \
        dish intact, and keep quantities/steps realistic. \(titleHint) \(tagHint)

        In `rationale`, write 1-2 sentences naming the key swaps you made and why.

        Original recipe:
        \(recipeBlock(recipe))

        Return ONLY a JSON object with this shape (the recipe matches the recipe schema):
        {
          "rationale": "what changed and why",
          "recipe": \(recipeSchemaHint)
        }
        """
    }

    // MARK: - (c) SUGGESTION (goal / meal name → a new recipe + rationale)

    /// Build the prompt to SUGGEST a brand-new recipe for `goal` (e.g. "weeknight
    /// dinner", "breakfast", "lunchbox", "kid-friendly", or a specific meal name).
    /// Ports `build_suggestion_draft`'s intent: the resolved goal sets the target meal
    /// type + a rationale note; the model proposes one recipe. The optional
    /// `recentNames` mirror the server's saved-recipe context (so the suggestion
    /// avoids repeating what the household already has).
    public static func suggestionPrompt(
        goal: String,
        recentNames: [String] = [],
        unit: UnitSystem = .us
    ) -> String {
        let preset = SuggestionGoal.resolve(goal)
        let mealTypeHint = preset.map { "Target meal type: \($0.mealType)." }
            ?? "Pick the most fitting meal type for the request."
        let note = preset?.rationaleNote
            ?? "Propose a reliable recipe that matches the request."

        var avoidLine = ""
        let trimmedRecent = recentNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !trimmedRecent.isEmpty {
            avoidLine = "\n\nThe household already has these recipes — propose something "
                + "different for variety:\n" + trimmedRecent.map { "- \($0)" }.joined(separator: "\n")
        }

        return """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are a recipe developer. Suggest ONE new recipe for this request: \
        \(goal.trimmingCharacters(in: .whitespacesAndNewlines)).

        \(mealTypeHint) \(note) Make it practical to cook at home, with realistic \
        ingredients (quantities + units) and clear, ordered steps.\(avoidLine)

        In `rationale`, write 1-2 sentences on why this recipe fits the request.

        Return ONLY a JSON object with this shape (the recipe matches the recipe schema):
        {
          "rationale": "why this recipe fits",
          "recipe": \(recipeSchemaHint)
        }
        """
    }

    // MARK: - (d) COMPANION (recipe → 2-3 side/sauce options)

    /// Build the prompt to produce COMPANION drafts (sides + a sauce) for `recipe`.
    /// Ports `build_companion_drafts`: exactly three options keyed `vegetable-side`,
    /// `starch-side`, and `sauce`, biased toward the anchor recipe's flavor profile
    /// (the server infers a cuisine library key from the recipe; here we hand the
    /// model the recipe and the same option contract and let it match the cuisine).
    public static func companionPrompt(
        recipe: RecipeContext,
        unit: UnitSystem = .us
    ) -> String {
        """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are a recipe developer building COMPANION dishes for a main recipe. \
        Propose exactly three companions that round out the plate WITHOUT competing \
        with the main: one vegetable side, one starch side, and one sauce/drizzle. \
        Match the main recipe's cuisine and flavor profile, keep each companion simple \
        (about 10 min prep, 15 min cook), and don't duplicate the main's core \
        ingredients. For each, give a one-sentence `rationale` for why it fits.

        Use exactly these `option_id` values: "vegetable-side", "starch-side", "sauce".

        Main recipe:
        \(recipeBlock(recipe))

        Return ONLY a JSON object with this shape (each `recipe` matches the recipe schema):
        {
          "rationale": "one sentence on the overall pairing approach",
          "options": [
            {"option_id": "vegetable-side", "label": "Vegetable Side", "rationale": "why it fits", "recipe": \(recipeSchemaHint)},
            {"option_id": "starch-side", "label": "Starch Side", "rationale": "why it fits", "recipe": { ... }},
            {"option_id": "sauce", "label": "Sauce / Drizzle", "rationale": "why it fits", "recipe": { ... }}
          ]
        }
        """
    }

    // MARK: - (e) REFINE (draft + instruction → refined recipe)

    /// Build the prompt to REFINE an in-flight `draft` per a user `instruction` (e.g.
    /// "more garlic", "make it dairy-free", "halve the servings"). Mirrors the
    /// server's `refine_recipe_draft` intent: apply the instruction, change as little
    /// else as possible, and return the full refined recipe. `contextHint` carries any
    /// extra app-side context (optional, mirrors the method's `contextHint` arg).
    public static func refinePrompt(
        draft: RecipeContext,
        instruction: String,
        contextHint: String = "",
        unit: UnitSystem = .us
    ) -> String {
        var hintLine = ""
        let trimmedHint = contextHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHint.isEmpty {
            hintLine = "\n\nAdditional context: \(trimmedHint)"
        }
        return """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are refining a recipe draft. Apply this instruction: \
        \(instruction.trimmingCharacters(in: .whitespacesAndNewlines)). Change only \
        what the instruction requires — keep the recipe's name, structure, and \
        unrelated ingredients/steps intact unless the instruction implies otherwise. \
        Return the COMPLETE refined recipe (all ingredients and steps, not just the \
        changes).\(hintLine)

        In `rationale`, write one sentence describing the change you made.

        Current draft:
        \(recipeBlock(draft))

        Return ONLY a JSON object with this shape (the recipe matches the recipe schema):
        {
          "rationale": "the change you made",
          "recipe": \(recipeSchemaHint)
        }
        """
    }

    // MARK: - Web-search input (mirrors recipe_search_ai._build_input)

    /// Build the input for the provider web-search path: find ONE real recipe on the
    /// web for `query` and extract it, citing the real `source_url`/`source_label`.
    /// Faithful port of `recipe_search_ai.py::_build_input`. (The web-search TOOL
    /// wiring lives on BYOKeyProvider; this is the pure prompt text it sends.)
    public static func webSearchInput(
        query: String,
        unit: UnitSystem = .us
    ) -> String {
        """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are a recipe finder. Use web search to find the BEST recipe that matches \
        this request: \(query.trimmingCharacters(in: .whitespacesAndNewlines))

        Pick exactly ONE recipe — the one you'd recommend after looking at a handful \
        of options. Prefer recipes from reputable sources (NYT Cooking, Serious Eats, \
        Bon Appétit, King Arthur, AllRecipes high-rated, food blogs with established \
        readership) over content farms.

        Then extract the full recipe — title, ingredients with quantities + units, \
        ordered steps, prep/cook minutes, servings, cuisine, meal type — into a single \
        JSON object. The `source_url` must be the real URL of the recipe you picked, \
        and `source_label` is the site name (e.g., 'NYT Cooking', 'Serious Eats').

        In `notes`, write 1-2 sentences explaining why this recipe stood out.

        Return ONLY a JSON object matching this schema:
        \(recipeSchemaHint)
        """
    }
}

// MARK: - RecipeContext (app → prompt input)

/// A recipe rendered for a prompt. The app maps a domain `RecipeDraft` (or a saved
/// recipe) onto this dependency-free value so the builders stay in AIProviderKit and
/// unit-test without SimmerSmithKit. Ingredients/steps are pre-rendered strings (the
/// app decides the exact rendering, e.g. "2 cup flour, sifted").
public struct RecipeContext: Sendable, Equatable {
    public var name: String
    public var mealType: String
    public var cuisine: String
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var tags: [String]
    public var ingredients: [String]
    public var steps: [String]
    public var notes: String

    public init(
        name: String,
        mealType: String = "",
        cuisine: String = "",
        servings: Double? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        tags: [String] = [],
        ingredients: [String] = [],
        steps: [String] = [],
        notes: String = ""
    ) {
        self.name = name
        self.mealType = mealType
        self.cuisine = cuisine
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.tags = tags
        self.ingredients = ingredients
        self.steps = steps
        self.notes = notes
    }
}

// MARK: - Goal routing (ports recipe_ai's preset resolution)

/// The six variation presets from `recipe_ai.VARIATION_PRESETS`, reduced to the
/// prompt-relevant fields (guidance note, title prefix, tags). `resolve` ports
/// `resolve_variation_preset`'s keyword map; an unrecognized goal returns nil (the
/// builder then uses a general instruction rather than the server's hard fallback to
/// the pantry preset — the LLM can honor an arbitrary goal directly).
public struct VariationGoal: Sendable, Equatable {
    public let key: String
    public let titlePrefix: String
    public let extraTags: [String]
    public let guidanceNote: String

    static let presets: [VariationGoal] = [
        VariationGoal(key: "low_carb", titlePrefix: "Low-Carb", extraTags: ["low-carb"],
            guidanceNote: "Reduce starch-heavy ingredients and keep the same flavor profile where possible."),
        VariationGoal(key: "dairy_free", titlePrefix: "Dairy-Free", extraTags: ["dairy-free"],
            guidanceNote: "Replace dairy with neutral, easy-to-find alternatives and keep the texture balanced."),
        VariationGoal(key: "gluten_free", titlePrefix: "Gluten-Free", extraTags: ["gluten-free"],
            guidanceNote: "Replace wheat-based ingredients with common gluten-free alternatives."),
        VariationGoal(key: "vegetarian", titlePrefix: "Vegetarian", extraTags: ["vegetarian"],
            guidanceNote: "Replace meat with satisfying vegetarian protein and umami-friendly ingredients."),
        VariationGoal(key: "kid_friendly", titlePrefix: "Kid-Friendly", extraTags: ["kid-friendly"],
            guidanceNote: "Tone down heat, simplify flavors, and keep textures approachable."),
        VariationGoal(key: "pantry_friendly", titlePrefix: "Pantry-Friendly", extraTags: ["pantry-friendly"],
            guidanceNote: "Favor shelf-stable or freezer-friendly swaps that are easier to keep on hand."),
    ]

    /// Port of `resolve_variation_preset`'s keyword map (normalized substring match).
    /// Returns nil for goals the server would have defaulted to pantry — on BYO-key
    /// the LLM can take an arbitrary goal, so the builder honors it directly.
    public static func resolve(_ goal: String) -> VariationGoal? {
        let normalized = normalizeGoal(goal)
        let keywordMap: [(String, String)] = [
            ("low carb", "low_carb"),
            ("dairy free", "dairy_free"),
            ("gluten free", "gluten_free"),
            ("vegetarian", "vegetarian"),
            ("kid friendly", "kid_friendly"),
            ("kids", "kid_friendly"),
            ("pantry", "pantry_friendly"),
        ]
        for (phrase, key) in keywordMap where normalized.contains(phrase) {
            return presets.first { $0.key == key }
        }
        return nil
    }
}

/// The five suggestion presets from `recipe_ai.SUGGESTION_PRESETS`, reduced to the
/// prompt-relevant fields. `resolve` ports `resolve_suggestion_preset`'s keyword map;
/// an unrecognized goal returns nil (the builder picks a general framing).
public struct SuggestionGoal: Sendable, Equatable {
    public let key: String
    public let mealType: String
    public let rationaleNote: String

    static let presets: [SuggestionGoal] = [
        SuggestionGoal(key: "weeknight_dinner", mealType: "dinner",
            rationaleNote: "Favor a reliable dinner idea that comes together on a weeknight."),
        SuggestionGoal(key: "breakfast_rotation", mealType: "breakfast",
            rationaleNote: "Keep breakfast ideas moving without losing what already works."),
        SuggestionGoal(key: "lunchbox_friendly", mealType: "lunch",
            rationaleNote: "Lean toward something that travels well as a portable lunch."),
        SuggestionGoal(key: "pantry_reset", mealType: "dinner",
            rationaleNote: "Bias toward easy, pantry-friendly ingredients."),
        SuggestionGoal(key: "kid_friendly_dinner", mealType: "dinner",
            rationaleNote: "Keep it family-usable: soften the edges and keep flavors approachable."),
    ]

    /// Port of `resolve_suggestion_preset`'s keyword map (normalized substring match).
    public static func resolve(_ goal: String) -> SuggestionGoal? {
        let normalized = normalizeGoal(goal)
        let keywordMap: [(String, String)] = [
            ("weeknight", "weeknight_dinner"),
            ("dinner", "weeknight_dinner"),
            ("breakfast", "breakfast_rotation"),
            ("lunchbox", "lunchbox_friendly"),
            ("lunch", "lunchbox_friendly"),
            ("portable", "lunchbox_friendly"),
            ("pantry", "pantry_reset"),
            ("kid", "kid_friendly_dinner"),
            ("family", "kid_friendly_dinner"),
        ]
        for (phrase, key) in keywordMap where normalized.contains(phrase) {
            return presets.first { $0.key == key }
        }
        return nil
    }
}

/// Port of `recipe_ai._normalized_goal`: lowercase, collapse non-alphanumerics to
/// single spaces, trim. Shared by both goal resolvers.
func normalizeGoal(_ goal: String) -> String {
    let lowered = goal.lowercased()
    let collapsed = lowered.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    }
    let joined = String(collapsed)
    return joined.split(separator: " ").joined(separator: " ")
}
