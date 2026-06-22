import Foundation

// SP-C AI-3 — Event-menu structured-output schema + parser (pure, headless-testable).
//
// The companion to `EventMenuPrompt`: the prompt instructs the model to return
// `{menu: [...], coverage_summary: "..."}` — the exact shape
// `app/services/event_ai.py::_build_prompt` documents. This file is the Codable
// mirror of that shape (`EventMenuResponse`), a parser that tolerates the same
// markdown-fence / prose wrapping the server's `extract_json_object` handled, and
// the name→guest-id coverage resolution `event_ai._resolve_coverage` performs.
//
// AIProviderKit has NO dependency on SimmerSmithKit (it must unit-test headlessly),
// so these are AIProviderKit-local WIRE shapes — `EventMenuDish` etc. The app layer
// (AppState+Events) maps `EventMenuResult.dishes` onto `EventRepository.addEventMeal`
// per dish the way `event_ai.generate_event_menu` builds `meal_dicts` for
// `replace_event_meals`.
//
// FIDELITY: the field set mirrors `event_ai._AIMeal` / `_AIIngredient` / `_AIResponse`;
// the `compatibleGuests` → guest-id resolution mirrors `_resolve_coverage` (drop names
// the AI invented; case-insensitive trimmed match against the attendee roster).

// MARK: - Wire shapes (Codable mirror of the prompt response structure)

/// One ingredient line on an event dish. Mirrors `event_ai._AIIngredient`.
public struct EventMenuIngredient: Codable, Sendable, Equatable {
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
        quantity = try EventMenuIngredient.decodeFlexibleDouble(c, forKey: .quantity)
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
    /// week-gen / recipe-AI flexible decode).
    private static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// One dish in a generated event menu. Mirrors `event_ai._AIMeal`: a meal `role`,
/// a `recipeName`, party-sized `servings`, free-text `notes`, the AI-declared
/// `compatibleGuests` (guest *names* the dish is explicitly safe for; empty = works
/// for everyone), and the dish's `ingredients`.
public struct EventMenuDish: Codable, Sendable, Equatable {
    public var role: String
    public var recipeName: String
    public var servings: Double?
    public var notes: String
    public var compatibleGuests: [String]
    public var ingredients: [EventMenuIngredient]

    enum CodingKeys: String, CodingKey {
        case role, servings, notes, ingredients
        case recipeName = "recipe_name"
        case compatibleGuests = "compatible_guests"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        recipeName = try c.decodeIfPresent(String.self, forKey: .recipeName) ?? ""
        servings = try EventMenuDish.decodeFlexibleDouble(c, forKey: .servings)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        compatibleGuests = try c.decodeIfPresent([String].self, forKey: .compatibleGuests) ?? []
        ingredients = try c.decodeIfPresent([EventMenuIngredient].self, forKey: .ingredients) ?? []
    }

    public init(
        role: String,
        recipeName: String,
        servings: Double? = nil,
        notes: String = "",
        compatibleGuests: [String] = [],
        ingredients: [EventMenuIngredient] = []
    ) {
        self.role = role
        self.recipeName = recipeName
        self.servings = servings
        self.notes = notes
        self.compatibleGuests = compatibleGuests
        self.ingredients = ingredients
    }

    private static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// The full parsed event-menu response: the dishes + the coverage summary.
/// Mirrors `event_ai._AIResponse` (`menu` + `coverage_summary`).
public struct EventMenuResponse: Codable, Sendable, Equatable {
    public var menu: [EventMenuDish]
    public var coverageSummary: String

    enum CodingKeys: String, CodingKey {
        case menu
        case coverageSummary = "coverage_summary"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        menu = try c.decodeIfPresent([EventMenuDish].self, forKey: .menu) ?? []
        coverageSummary = try c.decodeIfPresent(String.self, forKey: .coverageSummary) ?? ""
    }

    public init(menu: [EventMenuDish], coverageSummary: String = "") {
        self.menu = menu
        self.coverageSummary = coverageSummary
    }
}

/// The validated result the app maps onto `EventRepository.addEventMeal` per dish.
/// `dishes` carries each menu entry plus the resolved `constraintCoverage` (guest
/// *ids*, not names) — the analog of the `meal_dicts` `event_ai.generate_event_menu`
/// builds for `replace_event_meals`.
public struct EventMenuResult: Sendable, Equatable {
    /// A menu dish with its AI names already resolved to attendee guest-ids.
    public struct Dish: Sendable, Equatable {
        public var role: String
        public var recipeName: String
        public var servings: Double?
        public var notes: String
        /// Guest *ids* the dish is explicitly compatible with (resolved from the AI's
        /// `compatibleGuests` names against the attendee roster; the analog of the
        /// server's `constraint_coverage`).
        public var constraintCoverage: [String]
        public var ingredients: [EventMenuIngredient]
        /// Position in the menu (the server's `sort_order`).
        public var sortOrder: Int

        public init(
            role: String,
            recipeName: String,
            servings: Double?,
            notes: String,
            constraintCoverage: [String],
            ingredients: [EventMenuIngredient],
            sortOrder: Int
        ) {
            self.role = role
            self.recipeName = recipeName
            self.servings = servings
            self.notes = notes
            self.constraintCoverage = constraintCoverage
            self.ingredients = ingredients
            self.sortOrder = sortOrder
        }
    }

    public var dishes: [Dish]
    public var coverageSummary: String

    public init(dishes: [Dish], coverageSummary: String) {
        self.dishes = dishes
        self.coverageSummary = coverageSummary
    }
}

// MARK: - Errors

public enum EventMenuParseError: Error, Equatable {
    /// The response was not valid JSON even after stripping a markdown fence.
    case invalidJSON
    /// The JSON parsed but carried no dishes (an unusable menu).
    case emptyMenu
}

// MARK: - Parser + coverage resolution

public enum EventMenuParser {

    /// Parse a raw provider response into an `EventMenuResponse`. Tolerates the same
    /// markdown-fence / leading-prose wrapping `assistant_ai.extract_json_object`
    /// handled (reuses `RecipeAIParser.extractJSONObject`). Throws `.invalidJSON` on
    /// non-JSON and `.emptyMenu` when the menu carries no dishes.
    public static func parse(_ raw: String) throws -> EventMenuResponse {
        let json = RecipeAIParser.extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else { throw EventMenuParseError.invalidJSON }
        let response: EventMenuResponse
        do {
            response = try JSONDecoder().decode(EventMenuResponse.self, from: data)
        } catch {
            throw EventMenuParseError.invalidJSON
        }
        guard !response.menu.isEmpty else { throw EventMenuParseError.emptyMenu }
        return response
    }

    /// Map the AI-returned `compatibleGuests` *names* back to attendee guest-ids,
    /// dropping names the AI invented or vague catch-alls like "everyone". Faithful
    /// port of `event_ai._resolve_coverage`: a case-insensitive, trimmed match against
    /// the `nameToGuestId` roster; unknown names are dropped silently.
    public static func resolveCoverage(
        _ compatibleNames: [String],
        nameToGuestId: [String: String]
    ) -> [String] {
        // Normalize the lookup keys the way `_describe_guests` does (trimmed + lowercased).
        var normalizedLookup: [String: String] = [:]
        for (name, id) in nameToGuestId {
            normalizedLookup[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = id
        }
        var resolved: [String] = []
        for raw in compatibleNames {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let id = normalizedLookup[key] { resolved.append(id) }
        }
        return resolved
    }

    /// Parse + resolve coverage in one pass — the order the app uses: parse first so a
    /// malformed response is a parse error, then resolve each dish's compatible-guest
    /// names to ids and stamp the menu position (`sortOrder`). Mirrors the
    /// `meal_dicts` build in `event_ai.generate_event_menu`, including the
    /// `servings or attendee_count` fallback.
    public static func parseAndResolve(
        _ raw: String,
        nameToGuestId: [String: String],
        attendeeCount: Int
    ) throws -> EventMenuResult {
        let response = try parse(raw)
        let fallbackServings = Double(max(attendeeCount, 1))
        let dishes = response.menu.enumerated().map { index, dish -> EventMenuResult.Dish in
            EventMenuResult.Dish(
                role: dish.role,
                recipeName: dish.recipeName,
                servings: dish.servings ?? fallbackServings,
                notes: dish.notes,
                constraintCoverage: resolveCoverage(dish.compatibleGuests, nameToGuestId: nameToGuestId),
                ingredients: dish.ingredients,
                sortOrder: index
            )
        }
        return EventMenuResult(dishes: dishes, coverageSummary: response.coverageSummary)
    }
}
