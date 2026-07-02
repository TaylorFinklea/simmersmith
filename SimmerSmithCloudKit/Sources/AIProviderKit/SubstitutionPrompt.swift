import Foundation

// SP-D substitution port — prompt builder + structured-output schema/parser
// (pure, headless-testable).
//
// Faithful port of `app/services/substitution_ai.py`'s JSON contract: given a
// recipe, a target ingredient, and the household's ingredient preferences, ask
// for 3-5 substitutes that keep the dish functional and flavor-coherent while
// avoiding anything the household has flagged AVOID/dislike/allergy.
//
// What is intentionally NOT ported here: `_preference_note` (the app layer
// projects `IngredientPreference` rows into already-rendered "- AVOID: …" /
// "- PREFERS: …" bullet lines, the same way `RecipeAIPrompt` takes pre-rendered
// ingredient/step strings — AIProviderKit has no dependency on SimmerSmithKit)
// and `_ingredient_line` (the app reuses its existing `renderIngredient` helper).

public enum SubstitutionPrompt {
    public static let minSuggestions = 3
    public static let maxSuggestions = 5

    /// Build the substitution prompt. Mirrors `substitution_ai._build_prompt`.
    ///
    /// - Parameters:
    ///   - allIngredients: the recipe's ingredients, each pre-rendered as
    ///     "quantity unit name (prep)" (mirrors `_ingredient_line`).
    ///   - targetIngredientLine: the target ingredient, same rendering.
    ///   - preferenceNotes: pre-rendered "- AVOID: …" / "- PREFERS: …" bullets for
    ///     the household's active ingredient preferences (mirrors `_preference_note`).
    public static func build(
        recipeName: String,
        cuisine: String,
        mealType: String,
        allIngredients: [String],
        targetIngredientLine: String,
        hint: String = "",
        preferenceNotes: [String] = [],
        unit: UnitSystem = .us
    ) -> String {
        let ingredientsBlock = allIngredients.map { "- \($0)" }.joined(separator: "\n")
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        let hintLine = trimmedHint.isEmpty ? "" : "\nUser hint: \(trimmedHint)"
        let prefsBlock = preferenceNotes.isEmpty
            ? ""
            : "\n\nUser ingredient preferences:\n\(preferenceNotes.joined(separator: "\n"))"
        let schemaHint = #"{"suggestions": [{"name": "", "reason": "", "quantity": "", "unit": ""}]}"#

        return """
        \(WeekGenPrompt.unitSystemDirective(unit))

        You are a cooking assistant helping a home cook substitute a single ingredient in a recipe. Propose \(minSuggestions)-\(maxSuggestions) substitutes that keep the dish functional (texture, binding, moisture) and flavor-coherent.

        Recipe: \(recipeName)
        Cuisine: \(cuisine.isEmpty ? "unspecified" : cuisine)
        Meal type: \(mealType.isEmpty ? "unspecified" : mealType)

        All ingredients:
        \(ingredientsBlock)

        Ingredient to substitute: \(targetIngredientLine)\(hintLine)\(prefsBlock)

        Rules:
        - Do not suggest anything the user has flagged as AVOID/dislike/allergy.
        - Keep quantities realistic — substitutes are not always 1:1. Use the `quantity` and `unit` fields when a ratio adjustment is needed.
        - `reason` should be one short sentence. Explain *why* the swap works.
        - Prefer common pantry items over exotic ones.
        - Return \(minSuggestions)-\(maxSuggestions) options ordered best-first.

        Return ONLY a JSON object matching this schema:
        \(schemaHint)
        """
    }
}

// MARK: - Wire shapes

/// Mirrors `substitution_ai._AISuggestion` (the app layer maps this onto the
/// domain `SubstitutionSuggestion` in SimmerSmithKit).
public struct SubstitutionAISuggestion: Codable, Sendable, Equatable {
    public var name: String
    public var reason: String
    public var quantity: String
    public var unit: String

    enum CodingKeys: String, CodingKey { case name, reason, quantity, unit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        quantity = try c.decodeIfPresent(String.self, forKey: .quantity) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
    }

    public init(name: String, reason: String = "", quantity: String = "", unit: String = "") {
        self.name = name
        self.reason = reason
        self.quantity = quantity
        self.unit = unit
    }
}

/// The `{"suggestions": [...]}` envelope. Not public — only the parsed, filtered
/// `[SubstitutionAISuggestion]` crosses the module boundary.
private struct SubstitutionAIResponse: Codable {
    var suggestions: [SubstitutionAISuggestion]

    enum CodingKeys: String, CodingKey { case suggestions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        suggestions = try c.decodeIfPresent([SubstitutionAISuggestion].self, forKey: .suggestions) ?? []
    }
}

// MARK: - Errors

public enum SubstitutionAIParseError: Error, Equatable {
    /// The response was not valid JSON even after stripping a markdown fence.
    case invalidJSON
}

// MARK: - Parser

public enum SubstitutionAIParser {
    /// Parse the `{"suggestions": [...]}` envelope. Reuses
    /// `RecipeAIParser.extractJSONObject` for fence/prose salvage (mirrors
    /// `substitution_ai._parse_ai_response`'s use of the shared `extract_json_object`).
    /// Throws `.invalidJSON` on non-JSON; an empty/missing `suggestions` array is NOT
    /// an error — mirrors the server, which returns `[]` rather than raising when the
    /// model proposes nothing.
    public static func parse(_ raw: String) throws -> [SubstitutionAISuggestion] {
        let json = RecipeAIParser.extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else { throw SubstitutionAIParseError.invalidJSON }
        let decoded: SubstitutionAIResponse
        do {
            decoded = try JSONDecoder().decode(SubstitutionAIResponse.self, from: data)
        } catch {
            throw SubstitutionAIParseError.invalidJSON
        }
        // Filter blank names + cap at MAX_SUGGESTIONS (mirrors substitution_ai.py:157-168).
        let suggestions: [SubstitutionAISuggestion] = decoded.suggestions.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return SubstitutionAISuggestion(
                name: name,
                reason: entry.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                quantity: entry.quantity.trimmingCharacters(in: .whitespacesAndNewlines),
                unit: entry.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return Array(suggestions.prefix(SubstitutionPrompt.maxSuggestions))
    }
}
