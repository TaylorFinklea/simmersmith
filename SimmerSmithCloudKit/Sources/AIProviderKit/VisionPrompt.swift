import Foundation

// SP-D vision port — multimodal (image) prompt builders + structured-output
// schemas/parsers (pure, headless-testable).
//
// Faithful port of `app/services/vision_ai.py`'s two JSON contracts:
//   • `identify_ingredient` — a photo of an ingredient → name + confidence +
//     common names + cuisine uses + recipe-match search terms.
//   • `check_cooking_progress` — a mid-cook photo + the current recipe step →
//     a verdict + a short tip.
//
// What is intentionally NOT ported here: `_run_vision_provider`'s HTTP transport
// (that's `BYOKeyProvider.generateWithImage` in Providers.swift) and the
// image-bytes validation (`_validate_image`) — the app layer already resizes/
// JPEG-compresses before calling, mirroring the existing Fly client's contract.

public enum VisionPrompt {

    // MARK: - (a) Identify ingredient

    /// Mirrors `vision_ai._INGREDIENT_SYSTEM` verbatim.
    public static let identifyIngredientSystemPrompt =
        "You are a culinary expert. The user shows you a photo of an ingredient. " +
        "Identify it precisely (single ingredient if clear, otherwise the most " +
        "prominent one). Return ONLY a valid JSON object."

    /// Mirrors `vision_ai._ingredient_user_prompt()`.
    public static func identifyIngredientPrompt() -> String {
        let schema = """
        {"name": "...", "confidence": "high|medium|low", \
        "common_names": ["..."], \
        "cuisine_uses": [{"country": "...", "dish": "..."}], \
        "recipe_match_terms": ["..."], \
        "notes": "..."}
        """
        return """
        Identify the ingredient in this photo.

        Rules:
        - `name` is the most common English name (e.g., 'habanero pepper', 'Thai basil').
        - `confidence` reflects how certain you are: 'high' if obvious, 'medium' if narrowed but ambiguous, 'low' if you can only guess.
        - `common_names` lists alternate names across regions/languages (max 4).
        - `cuisine_uses` lists 2–4 (country, dish) pairs showing how it's used.
        - `recipe_match_terms` lists 2–6 short search keywords (e.g., 'jalapeno', 'chili pepper'). Useful for matching against a recipe library.
        - `notes` is one short sentence with handling or substitution tips. Empty if nothing notable.

        Return ONLY JSON matching:
        \(schema)
        """
    }

    // MARK: - (b) Cook check

    /// Mirrors `vision_ai._COOK_CHECK_SYSTEM` verbatim.
    public static let cookCheckSystemPrompt =
        "You are a calm, helpful cooking coach. The user shows you a photo of " +
        "their dish mid-cook and tells you the recipe step they are on. Reply with " +
        "a single short tip and a verdict. Return ONLY a valid JSON object."

    /// Mirrors `vision_ai._cook_check_user_prompt`. `recipeContext` is the recipe's
    /// cuisine (mirrors the server route's `recipe.cuisine or ""`).
    public static func cookCheckPrompt(
        recipeTitle: String,
        stepText: String,
        recipeContext: String
    ) -> String {
        let schema = #"{"verdict": "on_track|needs_more_time|concerning", "tip": "...", "suggested_minutes_remaining": 0}"#
        let trimmedTitle = recipeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStep = stepText.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextBlock = recipeContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextLine = contextBlock.isEmpty ? "" : "Recipe context: \(contextBlock)\n"
        return """
        Recipe: \(trimmedTitle.isEmpty ? "(untitled)" : trimmedTitle)
        Current step: \(trimmedStep.isEmpty ? "(no step text)" : trimmedStep)
        \(contextLine)
        Look at the photo and judge whether the cook is on track for this step.

        Rules:
        - `verdict` must be one of: 'on_track', 'needs_more_time', 'concerning'.
        - `tip` is one or two short sentences in plain, encouraging English.
        - `suggested_minutes_remaining` is a non-negative integer (0 if it's done).

        Return ONLY JSON matching:
        \(schema)
        """
    }
}

// MARK: - Wire shapes (Codable mirror of the prompt response structures)

/// Mirrors `vision_ai.CuisineUse`.
public struct VisionAICuisineUse: Codable, Sendable, Equatable {
    public var country: String
    public var dish: String

    enum CodingKeys: String, CodingKey { case country, dish }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? ""
        dish = try c.decodeIfPresent(String.self, forKey: .dish) ?? ""
    }

    public init(country: String, dish: String) {
        self.country = country
        self.dish = dish
    }
}

/// Mirrors `vision_ai.IngredientIdentification`.
public struct VisionAIIdentification: Codable, Sendable, Equatable {
    public var name: String
    public var confidence: String
    public var commonNames: [String]
    public var cuisineUses: [VisionAICuisineUse]
    public var recipeMatchTerms: [String]
    public var notes: String

    enum CodingKeys: String, CodingKey {
        case name, confidence, notes
        case commonNames = "common_names"
        case cuisineUses = "cuisine_uses"
        case recipeMatchTerms = "recipe_match_terms"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        confidence = try c.decodeIfPresent(String.self, forKey: .confidence) ?? ""
        commonNames = try c.decodeIfPresent([String].self, forKey: .commonNames) ?? []
        cuisineUses = try c.decodeIfPresent([VisionAICuisineUse].self, forKey: .cuisineUses) ?? []
        recipeMatchTerms = try c.decodeIfPresent([String].self, forKey: .recipeMatchTerms) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    public init(
        name: String,
        confidence: String,
        commonNames: [String] = [],
        cuisineUses: [VisionAICuisineUse] = [],
        recipeMatchTerms: [String] = [],
        notes: String = ""
    ) {
        self.name = name
        self.confidence = confidence
        self.commonNames = commonNames
        self.cuisineUses = cuisineUses
        self.recipeMatchTerms = recipeMatchTerms
        self.notes = notes
    }
}

/// Mirrors `vision_ai.CookCheckTip`.
public struct VisionAICookCheck: Codable, Sendable, Equatable {
    public var verdict: String
    public var tip: String
    public var suggestedMinutesRemaining: Int

    enum CodingKeys: String, CodingKey {
        case verdict, tip
        case suggestedMinutesRemaining = "suggested_minutes_remaining"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decodeIfPresent(String.self, forKey: .verdict) ?? ""
        tip = try c.decodeIfPresent(String.self, forKey: .tip) ?? ""
        suggestedMinutesRemaining = try c.decodeIfPresent(Int.self, forKey: .suggestedMinutesRemaining) ?? 0
    }

    public init(verdict: String, tip: String, suggestedMinutesRemaining: Int = 0) {
        self.verdict = verdict
        self.tip = tip
        self.suggestedMinutesRemaining = suggestedMinutesRemaining
    }
}

// MARK: - Errors

public enum VisionAIParseError: Error, Equatable {
    /// The response was not valid JSON even after stripping a markdown fence.
    case invalidJSON
    /// The JSON parsed but the identification carried no name (an unusable result).
    case emptyResult
}

// MARK: - Parser

public enum VisionAIParser {
    /// Parse an ingredient-identification response. Reuses
    /// `RecipeAIParser.extractJSONObject` for fence/prose salvage (mirrors
    /// `vision_ai.identify_ingredient`'s use of the shared `extract_json_object`).
    public static func parseIdentification(_ raw: String) throws -> VisionAIIdentification {
        let json = RecipeAIParser.extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else { throw VisionAIParseError.invalidJSON }
        let decoded: VisionAIIdentification
        do {
            decoded = try JSONDecoder().decode(VisionAIIdentification.self, from: data)
        } catch {
            throw VisionAIParseError.invalidJSON
        }
        guard !decoded.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VisionAIParseError.emptyResult
        }
        return decoded
    }

    /// Parse a cook-check response. Mirrors `vision_ai.check_cooking_progress`.
    public static func parseCookCheck(_ raw: String) throws -> VisionAICookCheck {
        let json = RecipeAIParser.extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else { throw VisionAIParseError.invalidJSON }
        do {
            return try JSONDecoder().decode(VisionAICookCheck.self, from: data)
        } catch {
            throw VisionAIParseError.invalidJSON
        }
    }
}
