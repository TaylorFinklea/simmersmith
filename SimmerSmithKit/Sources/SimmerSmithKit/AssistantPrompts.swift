import Foundation

/// The customizable AI-assistant suggestion chips, per screen ("page type").
///
/// The assistant overlay shows up to a few tappable suggestion chips in its intro state,
/// templated to the current screen (e.g. the focused day on the Week tab). Users can
/// override the chip text per screen in Settings; an override falls back to the built-in
/// defaults when empty. Prompt text may contain tokens (`{day}`, `{recipe}`) that are
/// substituted with the current context at display time.
///
/// Pure value logic — no store, no UI — so it unit-tests headlessly. The per-screen
/// override map is persisted as one JSON value in the private-plane `assistant_prompts`
/// setting (see `AppState.saveAssistantPrompts`).
public struct AssistantPromptContext: Identifiable, Sendable, Equatable {
    /// Matches `AIPageContext.pageType`.
    public let pageType: String
    /// Human label for the Settings list ("Week", "Recipe", …).
    public let title: String
    /// Short hint shown under the editor when the screen supports a token, else nil.
    public let tokenHint: String?
    /// Built-in prompt templates used when the user has no override for this screen.
    public let defaults: [String]

    public var id: String { pageType }

    public init(pageType: String, title: String, tokenHint: String?, defaults: [String]) {
        self.pageType = pageType
        self.title = title
        self.tokenHint = tokenHint
        self.defaults = defaults
    }
}

public enum AssistantPrompts {

    /// The private-plane setting key the override map is stored under.
    public static let settingKey = "assistant_prompts"

    /// Customizable screens, in Settings-list order. Page types not listed here (e.g.
    /// "settings") are not customizable and show no chips.
    public static let contexts: [AssistantPromptContext] = [
        AssistantPromptContext(
            pageType: "week",
            title: "Week",
            tokenHint: "{day} — the day you're viewing",
            defaults: [
                "Swap {day} dinner for something lighter",
                "Make {day} higher protein",
                "Replan {day} to hit my macros",
            ]
        ),
        AssistantPromptContext(
            pageType: "recipe_detail",
            title: "Recipe",
            tokenHint: "{recipe} — the recipe you're viewing",
            defaults: [
                "Make {recipe} lower carb",
                "Can I substitute the cream?",
                "Add this to the week",
            ]
        ),
        AssistantPromptContext(
            pageType: "recipes",
            title: "Recipes",
            tokenHint: nil,
            defaults: [
                "Find me a quick weeknight dinner",
                "What should I cook with salmon?",
            ]
        ),
        AssistantPromptContext(
            pageType: "grocery",
            title: "Grocery",
            tokenHint: nil,
            defaults: [
                "What else do I need this week?",
                "What can I skip?",
            ]
        ),
    ]

    public static func context(for pageType: String) -> AssistantPromptContext? {
        contexts.first { $0.pageType == pageType }
    }

    /// Substitute `{day}` / `{recipe}` tokens. Absent values get a natural fallback so a
    /// template like "Make {day} higher protein" still reads on the week overview.
    public static func render(_ template: String, day: String?, recipe: String?) -> String {
        let dayValue = (day?.isEmpty == false) ? day! : "today"
        let recipeValue = (recipe?.isEmpty == false) ? recipe! : "this recipe"
        return template
            .replacingOccurrences(of: "{day}", with: dayValue)
            .replacingOccurrences(of: "{recipe}", with: recipeValue)
    }

    /// The chips to show for a screen: the user's override (when non-empty) else the
    /// built-in defaults, with tokens substituted and blank/whitespace entries dropped.
    public static func resolve(pageType: String, overrides: [String], day: String?, recipe: String?) -> [String] {
        guard let ctx = context(for: pageType) else { return [] }
        let cleanedOverrides = overrides
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let base = cleanedOverrides.isEmpty ? ctx.defaults : cleanedOverrides
        return base
            .map { render($0, day: day, recipe: recipe).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Persistence codec (one JSON value: pageType -> [template])

    public static func encode(_ map: [String: [String]]) -> String {
        guard let data = try? JSONEncoder().encode(map),
              let string = String(data: data, encoding: .utf8) else { return "" }
        return string
    }

    public static func decode(_ value: String) -> [String: [String]] {
        guard let data = value.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return map
    }
}
