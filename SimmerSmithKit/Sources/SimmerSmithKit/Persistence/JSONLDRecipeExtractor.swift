import Foundation

// SP-C AI-2 — JSONLDRecipeExtractor: deterministic schema.org Recipe extraction.
//
// Mirrors the server's app/services/recipe_import/parser.py JSON-LD path, on-device,
// with no API key required. Given page HTML:
//   1. Find every <script type="application/ld+json"> block.
//   2. JSON-parse each (unescaping HTML entities first).
//   3. Walk for schema.org `Recipe` nodes — handling top-level arrays, `@graph`,
//      and a `@type` that is a string or an array containing "Recipe".
//   4. Map the first Recipe node → RecipeDraft:
//        name, recipeIngredient[] → ingredients (raw lines, unresolved),
//        recipeInstructions (string | [string] | HowToStep | HowToSection) → steps,
//        prepTime/cookTime (ISO-8601 PT#H#M) → prep/cookMinutes,
//        recipeYield → servings, recipeCuisine → cuisine, keywords → tags.
// Returns nil when no Recipe node is present (caller falls back to LLM extraction).

public enum JSONLDRecipeExtractor {

    /// Extract a `RecipeDraft` from page HTML, or nil if no schema.org Recipe is found.
    /// `sourceURL` (when provided) is stamped onto the draft and used for the name fallback.
    public static func extract(fromHTML html: String, sourceURL: String? = nil) -> RecipeDraft? {
        let nodes = recipeNodes(inHTML: html)
        guard let node = nodes.first else { return nil }
        return draft(from: node, sourceURL: sourceURL)
    }

    // MARK: - Block scan + JSON parse

    /// All `<script type="application/ld+json">` payloads on the page, JSON-parsed.
    static func recipeNodes(inHTML html: String) -> [[String: Any]] {
        var nodes: [[String: Any]] = []
        for block in ldJSONBlocks(inHTML: html) {
            let unescaped = block.replacingHTMLEntities()
            guard let data = unescaped.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { continue }
            nodes.append(contentsOf: recipeNodes(fromJSONLD: parsed))
        }
        return nodes
    }

    /// Extract the raw text inside each `application/ld+json` script tag.
    static func ldJSONBlocks(inHTML html: String) -> [String] {
        let pattern = "<script[^>]*type=[\"']application/ld\\+json[\"'][^>]*>(.*?)</script>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return ns.substring(with: match.range(at: 1))
        }
    }

    /// Recursively collect schema.org Recipe nodes — handles arrays, `@graph`, and a
    /// `@type` that is a string or an array containing "Recipe". Mirrors the server's
    /// `recipe_nodes_from_json_ld`.
    static func recipeNodes(fromJSONLD payload: Any) -> [[String: Any]] {
        if let array = payload as? [Any] {
            return array.flatMap { recipeNodes(fromJSONLD: $0) }
        }
        guard let dict = payload as? [String: Any] else { return [] }

        var nodes: [[String: Any]] = []
        if let graph = dict["@graph"] {
            nodes.append(contentsOf: recipeNodes(fromJSONLD: graph))
        }
        if typeContainsRecipe(dict["@type"]) {
            nodes.append(dict)
        }
        return nodes
    }

    private static func typeContainsRecipe(_ raw: Any?) -> Bool {
        let types: [Any]
        if let array = raw as? [Any] {
            types = array
        } else if let single = raw {
            types = [single]
        } else {
            return false
        }
        return types.contains { ($0 as? String)?.lowercased() == "recipe" }
    }

    // MARK: - Node → RecipeDraft

    static func draft(from node: [String: Any], sourceURL: String?) -> RecipeDraft {
        let steps = instructionSteps(from: node["recipeInstructions"])
        let ingredients = ingredientList(from: node["recipeIngredient"])
        let summary = steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.instruction)" }
            .joined(separator: "\n")

        let host = sourceURL.flatMap { URL(string: $0)?.host }?
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")

        return RecipeDraft(
            name: firstNonEmpty(node["name"], nameFromURL(sourceURL), "Imported recipe"),
            cuisine: firstNonEmpty(node["recipeCuisine"]),
            servings: parseServings(node["recipeYield"]),
            prepMinutes: parseDurationMinutes(node["prepTime"]),
            cookMinutes: parseDurationMinutes(node["cookTime"]),
            tags: normalizeKeywords(node["keywords"]),
            instructionsSummary: summary,
            source: "url_import",
            sourceLabel: sourceLabel(from: node, host: host ?? ""),
            sourceUrl: sourceURL ?? "",
            ingredients: ingredients,
            steps: steps
        )
    }

    // MARK: - Ingredients

    static func ingredientList(from value: Any?) -> [RecipeIngredient] {
        let items = asArray(value)
        var seen = Set<String>()
        var result: [RecipeIngredient] = []
        for item in items {
            let line = cleanText(item)
            guard !line.isEmpty else { continue }
            let key = line.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(RecipeIngredient(ingredientName: line, resolutionStatus: "unresolved"))
        }
        return result
    }

    // MARK: - Instructions (string | [string] | HowToStep | HowToSection)

    static func instructionSteps(from value: Any?) -> [RecipeStep] {
        let raw = collectInstructions(value)
        return raw.enumerated().map { index, item in
            RecipeStep(
                sortOrder: index + 1,
                instruction: item.instruction,
                substeps: item.substeps.enumerated().map { subIndex, sub in
                    RecipeStep(sortOrder: subIndex + 1, instruction: sub)
                }
            )
        }
    }

    private struct RawStep { var instruction: String; var substeps: [String] = [] }

    /// Mirror of the server's `extract_instruction_steps`: handles a plain string,
    /// an array (recursing), and dicts that are either a HowToStep (`text`/`name`)
    /// or a HowToSection (`itemListElement` of nested steps).
    private static func collectInstructions(_ value: Any?) -> [RawStep] {
        if let text = value as? String {
            let cleaned = cleanText(text)
            return cleaned.isEmpty ? [] : [RawStep(instruction: cleaned)]
        }
        if let array = value as? [Any] {
            return array.flatMap { collectInstructions($0) }
        }
        if let dict = value as? [String: Any] {
            if let list = dict["itemListElement"] {
                let nested = collectInstructions(list)
                let title = firstNonEmpty(dict["name"], dict["text"])
                if !title.isEmpty, !nested.isEmpty {
                    // HowToSection with a heading: keep the heading as a step with
                    // the nested steps as substeps.
                    return [RawStep(instruction: title, substeps: nested.map(\.instruction))]
                }
                return nested
            }
            let text = firstNonEmpty(dict["text"], dict["name"])
            return text.isEmpty ? [] : [RawStep(instruction: text)]
        }
        return []
    }

    // MARK: - Source label

    private static func sourceLabel(from node: [String: Any], host: String) -> String {
        let publisherName = (node["publisher"] as? [String: Any])?["name"]
        let authorName = (node["author"] as? [String: Any])?["name"]
        return firstNonEmpty(publisherName, authorName, host)
    }

    private static func nameFromURL(_ urlString: String?) -> String {
        guard let urlString, let url = URL(string: urlString) else { return "" }
        let slug = url.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "-", with: " ")
        return slug.isEmpty ? "" : slug.capitalized
    }

    // MARK: - Scalar parsers (mirror common.py)

    /// Parse an ISO-8601 duration (`PT#H#M`, also `P#DT#H#M`) → minutes, or nil.
    static func parseDurationMinutes(_ value: Any?) -> Int? {
        let text = cleanText(value)
        guard !text.isEmpty else { return nil }
        let pattern = "^P(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:\\d+S)?)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        func group(_ i: Int) -> Int {
            let r = match.range(at: i)
            guard r.location != NSNotFound else { return 0 }
            return Int((text as NSString).substring(with: r)) ?? 0
        }
        let total = group(1) * 24 * 60 + group(2) * 60 + group(3)
        return total == 0 ? nil : total
    }

    /// Parse `recipeYield` (string, number, or array) → a servings count, or nil.
    static func parseServings(_ value: Any?) -> Double? {
        var v = value
        if let array = v as? [Any] {
            v = array.first { !cleanText($0).isEmpty }
        }
        if let number = v as? NSNumber, !(v is Bool) {
            return number.doubleValue
        }
        let text = cleanText(v)
        guard !text.isEmpty else { return nil }
        guard let regex = try? NSRegularExpression(pattern: "\\d+(?:\\.\\d+)?"),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        return Double((text as NSString).substring(with: match.range))
    }

    static func normalizeKeywords(_ value: Any?) -> [String] {
        var parts: [String] = []
        if let string = value as? String {
            parts = string.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        } else if let array = value as? [Any] {
            parts = array.map { cleanText($0) }
        }
        var seen = Set<String>()
        var result: [String] = []
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Shared helpers

    private static func asArray(_ value: Any?) -> [Any] {
        if let array = value as? [Any] { return array }
        if let value { return [value] }
        return []
    }

    /// First value whose cleaned text is non-empty; recurses into arrays.
    static func firstNonEmpty(_ values: Any?...) -> String {
        for value in values {
            if let array = value as? [Any] {
                let nested = firstNonEmptyArray(array)
                if !nested.isEmpty { return nested }
            }
            let text = cleanText(value)
            if !text.isEmpty { return text }
        }
        return ""
    }

    private static func firstNonEmptyArray(_ values: [Any]) -> String {
        for value in values {
            if let nested = value as? [Any] {
                let r = firstNonEmptyArray(nested)
                if !r.isEmpty { return r }
            }
            let text = cleanText(value)
            if !text.isEmpty { return text }
        }
        return ""
    }

    /// Strip tags + entities, collapse whitespace. Mirrors `clean_text`.
    static func cleanText(_ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        var text: String
        if let number = value as? NSNumber, !(value is Bool) {
            // Avoid "1.0" for integral yields.
            if number.doubleValue == number.doubleValue.rounded() {
                text = String(number.intValue)
            } else {
                text = number.stringValue
            }
        } else {
            text = String(describing: value)
        }
        text = text.replacingHTMLEntities()
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    /// Decode the small set of HTML entities recipe JSON-LD commonly carries.
    func replacingHTMLEntities() -> String {
        var s = self
        let map: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#34;", "\""),
            ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#160;", " "),
            ("&frac12;", "½"), ("&frac14;", "¼"), ("&frac34;", "¾"),
        ]
        for (entity, replacement) in map {
            s = s.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric decimal entities (&#NNN;).
        if s.contains("&#") {
            s = s.decodingNumericEntities()
        }
        return s
    }

    func decodingNumericEntities() -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#(\\d+);") else { return self }
        let ns = NSMutableString(string: self)
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).reversed()
        for match in matches {
            let codeRange = match.range(at: 1)
            let code = (self as NSString).substring(with: codeRange)
            if let scalarValue = UInt32(code), let scalar = Unicode.Scalar(scalarValue) {
                ns.replaceCharacters(in: match.range, with: String(scalar))
            }
        }
        return ns as String
    }
}
