import Foundation

// SP-D seasonal-produce port — prompt builder + structured-output schema/parser
// (pure, headless-testable).
//
// Faithful port of `app/services/seasonal_ai.py`'s JSON contract: one AI call per
// (region, year, month), returning 5–8 in-season produce items with a short
// "why now" reason and a 1–5 peak score.
//
// What is intentionally NOT ported here: `seasonal_produce`'s module-level cache
// (that lives in `AIService.fetchSeasonalProduce`, the app-side "service" analog)
// and the DB/settings reads (the app layer resolves the region).

public enum SeasonalPrompt {

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Build the seasonal-produce prompt for `region` in `month`/`year`. Mirrors
    /// `seasonal_ai._build_prompt` verbatim (rule text + schema hint).
    public static func build(region: String, year: Int, month: Int) -> String {
        let schemaHint = #"{"items": [{"name": "...", "why_now": "...", "peak_score": 1-5}]}"#
        let monthName = (1...12).contains(month) ? monthNames[month - 1] : "this month"
        return """
        List 5–8 produce items that are in peak season right now for the region described below. Bias toward fresh fruit + vegetables a home cook would actually buy at a grocery store or farmers' market. Return ONLY a JSON object.

        Region: \(region)
        Month: \(monthName) \(year)

        Rules:
        - 5–8 items. Each `name` is a short common name (e.g., 'asparagus').
        - `why_now` is one short sentence about *why* it's at peak now.
        - `peak_score` is 1–5: 5 = absolute peak, 1 = barely available.
        - Order best-first by `peak_score`.

        Return ONLY a JSON object matching:
        \(schemaHint)
        """
    }
}

// MARK: - Wire shapes

/// Mirrors `seasonal_ai.InSeasonItem` (the app layer maps this onto the domain
/// `InSeasonItem` in SimmerSmithKit — AIProviderKit stays dependency-free).
public struct SeasonalAIItem: Codable, Sendable, Equatable {
    public var name: String
    public var whyNow: String
    public var peakScore: Int

    enum CodingKeys: String, CodingKey {
        case name
        case whyNow = "why_now"
        case peakScore = "peak_score"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        whyNow = try c.decodeIfPresent(String.self, forKey: .whyNow) ?? ""
        peakScore = try c.decodeIfPresent(Int.self, forKey: .peakScore) ?? 3
    }

    public init(name: String, whyNow: String = "", peakScore: Int = 3) {
        self.name = name
        self.whyNow = whyNow
        self.peakScore = peakScore
    }
}

/// The `{"items": [...]}` envelope. Not public — only the parsed, filtered
/// `[SeasonalAIItem]` crosses the module boundary.
private struct SeasonalAIResponse: Codable {
    var items: [SeasonalAIItem]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([SeasonalAIItem].self, forKey: .items) ?? []
    }
}

// MARK: - Errors

public enum SeasonalAIParseError: Error, Equatable {
    /// The response was not valid JSON even after stripping a markdown fence.
    case invalidJSON
}

// MARK: - Parser

public enum SeasonalAIParser {
    /// Parse the `{"items": [...]}` envelope. Reuses `RecipeAIParser.extractJSONObject`
    /// for fence/prose salvage. Blank names are dropped, `peak_score` is clamped to
    /// 1...5 (the server instead rejects the WHOLE response via a pydantic `ge`/`le`
    /// constraint on any out-of-range item — clamping is more resilient on-device and
    /// keeps an otherwise-good response usable), and the result is capped at 8 items
    /// (mirrors `seasonal_ai._parse_response`).
    public static func parse(_ raw: String) throws -> [SeasonalAIItem] {
        let json = RecipeAIParser.extractJSONObject(raw)
        guard let data = json.data(using: .utf8) else { throw SeasonalAIParseError.invalidJSON }
        let decoded: SeasonalAIResponse
        do {
            decoded = try JSONDecoder().decode(SeasonalAIResponse.self, from: data)
        } catch {
            throw SeasonalAIParseError.invalidJSON
        }
        let items: [SeasonalAIItem] = decoded.items.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return SeasonalAIItem(
                name: name,
                whyNow: entry.whyNow.trimmingCharacters(in: .whitespacesAndNewlines),
                peakScore: min(5, max(1, entry.peakScore))
            )
        }
        return Array(items.prefix(8))
    }
}
