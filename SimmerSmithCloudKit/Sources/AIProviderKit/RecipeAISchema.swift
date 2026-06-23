import Foundation

// SP-C AI-2 — Recipe-AI structured-output schemas + parsers (pure, headless-testable).
//
// The companion to `RecipeAIPrompt`: each prompt instructs the model to return a
// fixed JSON shape; this file is the Codable mirror of those shapes plus parsers
// that tolerate the same markdown-fence wrapping the server's `_extract_json` /
// `extract_json_object` handled, apply lenient field defaults, and THROW on
// malformed / empty input.
//
// AIProviderKit has NO dependency on SimmerSmithKit (it must unit-test headlessly),
// so these are AIProviderKit-local WIRE shapes — `RecipeAIRecipe` / `RecipeAIOption`
// / `RecipeAIVariationResult` etc. The app layer (AppState+Recipes) maps them onto
// the domain `RecipeDraft` / `RecipeAIDraft` / `RecipeAIOptions` the same way the
// week-gen path maps `MealPlanRecipe` onto `saveWeekMeals`.
//
// FIDELITY: the field set + the single-recipe extraction shape mirror
// `app/services/recipe_search_ai.py::_AIRecipe`; the variation/suggestion/companion
// wrappers carry the `rationale` (+ `label`/`option_id`) the server's
// `recipe_ai.py::build_*_draft` returns alongside the draft.

// MARK: - Wire shapes (Codable mirror of the prompt response structures)

/// One ingredient line in a model-generated recipe. Mirrors the server's
/// `_AIIngredient` (recipe_search_ai.py) plus the optional `category`/`notes` the
/// extraction/variation prompts also request.
public struct RecipeAIIngredient: Codable, Sendable, Equatable {
    public var ingredientName: String
    public var quantity: Double?
    public var unit: String
    public var prep: String
    public var category: String
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case ingredientName = "ingredient_name"
        case quantity, unit, prep, category, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ingredientName = try c.decodeIfPresent(String.self, forKey: .ingredientName) ?? ""
        quantity = try RecipeAIIngredient.decodeFlexibleDouble(c, forKey: .quantity)
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        prep = try c.decodeIfPresent(String.self, forKey: .prep) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public init(
        ingredientName: String,
        quantity: Double? = nil,
        unit: String = "",
        prep: String = "",
        category: String = "",
        notes: String = ""
    ) {
        self.ingredientName = ingredientName
        self.quantity = quantity
        self.unit = unit
        self.prep = prep
        self.category = category
        self.notes = notes
    }

    /// Models sometimes return `"2"` instead of `2.0`; accept either (mirrors the
    /// week-gen `decodeFlexibleDouble`).
    private static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// One cooking step in a model-generated recipe. The prompt asks for `instruction`;
/// `step_number` (when present) is tolerated but the parser re-numbers by position
/// (matching `recipe_search_ai._to_recipe_payload`, which uses `enumerate`).
public struct RecipeAIStep: Codable, Sendable, Equatable {
    public var instruction: String
    public var stepNumber: Int?

    enum CodingKeys: String, CodingKey {
        case instruction
        case stepNumber = "step_number"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        stepNumber = try c.decodeIfPresent(Int.self, forKey: .stepNumber)
    }

    public init(instruction: String, stepNumber: Int? = nil) {
        self.instruction = instruction
        self.stepNumber = stepNumber
    }
}

/// The single-recipe shape every recipe-AI prompt returns inside its envelope.
/// Mirrors `recipe_search_ai.py::_AIRecipe` (the canonical recipe-AI wire shape)
/// with the extraction/variation prompts' extra `tags` field.
public struct RecipeAIRecipe: Codable, Sendable, Equatable {
    public var name: String
    public var sourceUrl: String
    public var sourceLabel: String
    public var cuisine: String
    public var mealType: String
    public var servings: Double?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var tags: [String]
    public var ingredients: [RecipeAIIngredient]
    public var steps: [RecipeAIStep]
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case name, cuisine, servings, tags, ingredients, steps, notes
        case sourceUrl = "source_url"
        case sourceLabel = "source_label"
        case mealType = "meal_type"
        case prepMinutes = "prep_minutes"
        case cookMinutes = "cook_minutes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        sourceUrl = try c.decodeIfPresent(String.self, forKey: .sourceUrl) ?? ""
        sourceLabel = try c.decodeIfPresent(String.self, forKey: .sourceLabel) ?? ""
        cuisine = try c.decodeIfPresent(String.self, forKey: .cuisine) ?? ""
        mealType = try c.decodeIfPresent(String.self, forKey: .mealType) ?? ""
        servings = RecipeAIRecipe.flexibleDouble(c, forKey: .servings)
        prepMinutes = try c.decodeIfPresent(Int.self, forKey: .prepMinutes)
        cookMinutes = try c.decodeIfPresent(Int.self, forKey: .cookMinutes)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        ingredients = try c.decodeIfPresent([RecipeAIIngredient].self, forKey: .ingredients) ?? []
        steps = try c.decodeIfPresent([RecipeAIStep].self, forKey: .steps) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public init(
        name: String,
        sourceUrl: String = "",
        sourceLabel: String = "",
        cuisine: String = "",
        mealType: String = "",
        servings: Double? = nil,
        prepMinutes: Int? = nil,
        cookMinutes: Int? = nil,
        tags: [String] = [],
        ingredients: [RecipeAIIngredient] = [],
        steps: [RecipeAIStep] = [],
        notes: String = ""
    ) {
        self.name = name
        self.sourceUrl = sourceUrl
        self.sourceLabel = sourceLabel
        self.cuisine = cuisine
        self.mealType = mealType
        self.servings = servings
        self.prepMinutes = prepMinutes
        self.cookMinutes = cookMinutes
        self.tags = tags
        self.ingredients = ingredients
        self.steps = steps
        self.notes = notes
    }

    /// Models sometimes return `"4"` instead of `4` for servings; accept either
    /// (mirrors the ingredient-quantity flexible decode).
    private static func flexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// A single companion option (side / sauce). Mirrors the `(option_id, label,
/// rationale, recipe)` tuple `recipe_ai.build_companion_drafts` returns; the app maps
/// it onto `RecipeAIDraftOption`.
public struct RecipeAIOption: Codable, Sendable, Equatable {
    public var optionId: String
    public var label: String
    public var rationale: String
    public var recipe: RecipeAIRecipe

    enum CodingKeys: String, CodingKey {
        case label, rationale, recipe
        case optionId = "option_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        optionId = try c.decodeIfPresent(String.self, forKey: .optionId) ?? ""
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        recipe = try c.decode(RecipeAIRecipe.self, forKey: .recipe)
    }

    public init(optionId: String, label: String, rationale: String, recipe: RecipeAIRecipe) {
        self.optionId = optionId
        self.label = label
        self.rationale = rationale
        self.recipe = recipe
    }
}

// MARK: - Envelope shapes (one per feature)

/// Variation / suggestion envelope: a single drafted recipe + a `rationale`
/// explaining the goal-driven changes. Mirrors `build_variation_draft` /
/// `build_suggestion_draft`, which return `(draft, rationale, label)`.
public struct RecipeAIVariationResponse: Codable, Sendable, Equatable {
    public var rationale: String
    public var recipe: RecipeAIRecipe

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        recipe = try c.decode(RecipeAIRecipe.self, forKey: .recipe)
    }

    enum CodingKeys: String, CodingKey { case rationale, recipe }

    public init(rationale: String, recipe: RecipeAIRecipe) {
        self.rationale = rationale
        self.recipe = recipe
    }
}

/// Companion envelope: 2-3 side/sauce options + an overall `rationale`. Mirrors
/// `build_companion_drafts`, which returns `(options, rationale, label)`.
public struct RecipeAICompanionResponse: Codable, Sendable, Equatable {
    public var rationale: String
    public var options: [RecipeAIOption]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        options = try c.decodeIfPresent([RecipeAIOption].self, forKey: .options) ?? []
    }

    enum CodingKeys: String, CodingKey { case rationale, options }

    public init(rationale: String, options: [RecipeAIOption]) {
        self.rationale = rationale
        self.options = options
    }
}

// MARK: - Errors

public enum RecipeAIParseError: Error, Equatable {
    /// The response was not valid JSON even after stripping a markdown fence.
    case invalidJSON
    /// The JSON parsed but the recipe carried no name (an unusable draft).
    case emptyRecipe
    /// The companion response parsed but carried no options.
    case noOptions
}

// MARK: - Parser

public enum RecipeAIParser {

    /// Strip a leading/trailing markdown code fence (```/```json) AND, when the model
    /// wraps prose around the JSON, slice out the first balanced `{...}` object —
    /// mirroring `assistant_ai.extract_json_object` (which the server's recipe-search
    /// path runs before `json.loads`). Returns the inner text when no fence/object
    /// salvage is needed.
    public static func extractJSONObject(_ raw: String) -> String {
        let fenced = stripCodeFence(raw)
        let trimmed = fenced.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        // Salvage the first balanced top-level object the way the server does, so a
        // model that prefaces the JSON with a sentence still parses.
        guard let start = trimmed.firstIndex(of: "{") else { return trimmed }
        var depth = 0
        var inString = false
        var escaped = false
        var idx = start
        while idx < trimmed.endIndex {
            let ch = trimmed[idx]
            if escaped {
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(trimmed[start...idx])
                    }
                }
            }
            idx = trimmed.index(after: idx)
        }
        return String(trimmed[start...])
    }

    /// Strip a leading/trailing markdown code fence, mirroring
    /// `week_planner._extract_json` (reused verbatim by the recipe-AI path).
    public static func stripCodeFence(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        if !lines.isEmpty { lines.removeFirst() }
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n")
    }

    private static func decode<T: Decodable>(_ type: T.Type, from raw: String) throws -> T {
        let json = extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else { throw RecipeAIParseError.invalidJSON }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RecipeAIParseError.invalidJSON
        }
    }

    /// Parse a bare `RecipeAIRecipe` — used by EXTRACTION (text/HTML import) and the
    /// web-search path, which both return a single recipe object. Throws
    /// `.invalidJSON` on non-JSON and `.emptyRecipe` when no name survives.
    public static func parseRecipe(_ raw: String) throws -> RecipeAIRecipe {
        let recipe = try decode(RecipeAIRecipe.self, from: raw)
        guard !recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecipeAIParseError.emptyRecipe
        }
        return recipe
    }

    /// Parse a VARIATION / SUGGESTION / REFINE envelope (`{rationale, recipe}`).
    /// Throws `.invalidJSON` on non-JSON and `.emptyRecipe` when the recipe has no name.
    public static func parseVariation(_ raw: String) throws -> RecipeAIVariationResponse {
        let response = try decode(RecipeAIVariationResponse.self, from: raw)
        guard !response.recipe.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecipeAIParseError.emptyRecipe
        }
        return response
    }

    /// Parse a COMPANION envelope (`{rationale, options: [...]}`). Throws
    /// `.invalidJSON` on non-JSON and `.noOptions` when the options array is empty.
    public static func parseCompanion(_ raw: String) throws -> RecipeAICompanionResponse {
        let response = try decode(RecipeAICompanionResponse.self, from: raw)
        guard !response.options.isEmpty else { throw RecipeAIParseError.noOptions }
        return response
    }
}
