import Foundation
import Testing
@testable import AIProviderKit

// SP-D seasonal-produce port — prompt builder + structured-output parser.
//
// Verifies fidelity to `app/services/seasonal_ai.py`: the prompt embeds the
// region/month + schema, and the parser round-trips a sample response while
// filtering blank names, clamping peak_score to 1...5, and capping at 8 items.

@Test("seasonal prompt embeds the region, month name + year, and schema")
func seasonalPromptStructure() {
    let prompt = SeasonalPrompt.build(region: "Pacific Northwest", year: 2026, month: 7)
    #expect(prompt.contains("Region: Pacific Northwest"))
    #expect(prompt.contains("Month: July 2026"))
    #expect(prompt.contains("\"peak_score\""))
    #expect(prompt.contains("5–8 produce items"))
}

@Test("seasonal prompt falls back to 'this month' for an out-of-range month")
func seasonalPromptInvalidMonth() {
    let prompt = SeasonalPrompt.build(region: "United States", year: 2026, month: 13)
    #expect(prompt.contains("Month: this month 2026"))
}

@Test("SeasonalAIParser round-trips a full items response")
func seasonalParserRoundTrip() throws {
    let raw = """
    {"items": [
      {"name": "asparagus", "why_now": "Spring harvest peak.", "peak_score": 5},
      {"name": "strawberries", "why_now": "Early summer sweetness.", "peak_score": 4}
    ]}
    """
    let items = try SeasonalAIParser.parse(raw)
    #expect(items.count == 2)
    #expect(items[0].name == "asparagus")
    #expect(items[0].whyNow == "Spring harvest peak.")
    #expect(items[0].peakScore == 5)
    #expect(items[1].name == "strawberries")
}

@Test("SeasonalAIParser filters out blank names")
func seasonalParserFiltersBlankNames() throws {
    let raw = """
    {"items": [
      {"name": "", "why_now": "x", "peak_score": 3},
      {"name": "corn", "why_now": "Peak summer sweet corn.", "peak_score": 5}
    ]}
    """
    let items = try SeasonalAIParser.parse(raw)
    #expect(items.count == 1)
    #expect(items[0].name == "corn")
}

@Test("SeasonalAIParser clamps peak_score to 1...5")
func seasonalParserClampsPeakScore() throws {
    let raw = """
    {"items": [
      {"name": "figs", "why_now": "x", "peak_score": 9},
      {"name": "kale", "why_now": "y", "peak_score": -2}
    ]}
    """
    let items = try SeasonalAIParser.parse(raw)
    #expect(items[0].peakScore == 5)
    #expect(items[1].peakScore == 1)
}

@Test("SeasonalAIParser caps the result at 8 items")
func seasonalParserCapsAtEight() throws {
    let entries = (1...12).map { "{\"name\": \"item\($0)\", \"peak_score\": 3}" }.joined(separator: ",")
    let raw = "{\"items\": [\(entries)]}"
    let items = try SeasonalAIParser.parse(raw)
    #expect(items.count == 8)
    #expect(items.first?.name == "item1")
}

@Test("SeasonalAIParser salvages a fenced/prose-wrapped response")
func seasonalParserFenced() throws {
    let raw = """
    Here's the list:
    ```json
    {"items": [{"name": "peaches", "why_now": "Summer stone fruit.", "peak_score": 4}]}
    ```
    """
    let items = try SeasonalAIParser.parse(raw)
    #expect(items.count == 1)
    #expect(items[0].name == "peaches")
}

@Test("SeasonalAIParser throws invalidJSON on non-JSON input")
func seasonalParserInvalidJSON() {
    #expect(throws: SeasonalAIParseError.invalidJSON) {
        _ = try SeasonalAIParser.parse("not json")
    }
}

@Test("SeasonalAIParser returns an empty list for a missing items key rather than throwing")
func seasonalParserMissingItemsKey() throws {
    let items = try SeasonalAIParser.parse("{}")
    #expect(items.isEmpty)
}
