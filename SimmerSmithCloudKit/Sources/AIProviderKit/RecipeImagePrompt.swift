import Foundation

// SP-C AI-4 — Recipe image-gen prompt builder (pure, headless-testable).
//
// Faithful port of `app/services/recipe_image_ai.py::_build_prompt`. The server
// composes a single text prompt from the recipe's name + cuisine + the top-5
// ingredients; empty fields collapse out. Both image providers (OpenAI
// `gpt-image-1` and Gemini `gemini-2.5-flash-image-preview`) share this one
// prompt so variety stays provider-driven, not prompt-driven.
//
// The shape (matching the server, period-joined then a trailing period):
//   "A photographic, top-down shot of {name}[. a {cuisine} dish].
//    plated on a wooden table, soft natural light, no text, no watermarks[.
//    Visible ingredients: i1, i2, …]."

public enum RecipeImagePrompt {

    /// Build the image-gen prompt for a recipe. Ports `_build_prompt`:
    ///   • `name` falls back to "a meal" when empty/blank.
    ///   • `cuisine` adds "a {cuisine} dish" only when present.
    ///   • up to the first 5 non-blank ingredients are listed; an empty list
    ///     drops the "Visible ingredients:" clause entirely.
    /// The parts are joined with ". " and a final "." is appended, exactly as the
    /// server does, so the on-device prompt is byte-for-byte the server's output.
    public static func build(
        name: String,
        cuisine: String = "",
        ingredients: [String] = []
    ) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "a meal" : trimmedName
        let trimmedCuisine = cuisine.trimmingCharacters(in: .whitespacesAndNewlines)

        var topIngredients: [String] = []
        for ing in ingredients.prefix(5) {
            let label = ing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty {
                topIngredients.append(label)
            }
        }

        var parts: [String] = ["A photographic, top-down shot of \(resolvedName)"]
        if !trimmedCuisine.isEmpty {
            parts.append("a \(trimmedCuisine) dish")
        }
        parts.append("plated on a wooden table, soft natural light, no text, no watermarks")
        if !topIngredients.isEmpty {
            parts.append("Visible ingredients: " + topIngredients.joined(separator: ", "))
        }
        return parts.joined(separator: ". ") + "."
    }
}
