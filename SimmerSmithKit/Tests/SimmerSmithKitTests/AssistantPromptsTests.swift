import Testing
import Foundation
@testable import SimmerSmithKit

// SP-C — AssistantPrompts: customizable assistant suggestion chips.

@Test("render substitutes {day} and {recipe}")
func renderTokens() {
    #expect(AssistantPrompts.render("Make {day} higher protein", day: "Friday", recipe: nil)
            == "Make Friday higher protein")
    #expect(AssistantPrompts.render("Make {recipe} lower carb", day: nil, recipe: "Lasagna")
            == "Make Lasagna lower carb")
}

@Test("render falls back when a token has no value")
func renderFallback() {
    #expect(AssistantPrompts.render("Swap {day} dinner", day: nil, recipe: nil) == "Swap today dinner")
    #expect(AssistantPrompts.render("Swap {day} dinner", day: "", recipe: nil) == "Swap today dinner")
    #expect(AssistantPrompts.render("Make {recipe} lighter", day: nil, recipe: nil) == "Make this recipe lighter")
}

@Test("resolve uses defaults when there is no override")
func resolveDefaults() {
    let out = AssistantPrompts.resolve(pageType: "week", overrides: [], day: "Friday", recipe: nil)
    #expect(out == [
        "Swap Friday dinner for something lighter",
        "Make Friday higher protein",
        "Replan Friday to hit my macros",
    ])
}

@Test("resolve uses the override when present, with tokens substituted")
func resolveOverride() {
    let out = AssistantPrompts.resolve(
        pageType: "week",
        overrides: ["Plan {day} for me", "  ", "Keep it cheap"],
        day: "Monday", recipe: nil
    )
    #expect(out == ["Plan Monday for me", "Keep it cheap"])  // blank dropped
}

@Test("resolve returns empty for an unknown page type")
func resolveUnknown() {
    #expect(AssistantPrompts.resolve(pageType: "settings", overrides: [], day: nil, recipe: nil).isEmpty)
}

@Test("resolve treats an all-blank override as empty (falls back to defaults)")
func resolveBlankOverride() {
    let out = AssistantPrompts.resolve(pageType: "grocery", overrides: ["", "   "], day: nil, recipe: nil)
    #expect(out == AssistantPrompts.context(for: "grocery")!.defaults)
}

@Test("encode/decode round-trips the override map")
func codecRoundTrip() {
    let map = ["week": ["a {day}", "b"], "grocery": ["c"]]
    let restored = AssistantPrompts.decode(AssistantPrompts.encode(map))
    #expect(restored == map)
}

@Test("decode of garbage is empty, not a crash")
func decodeGarbage() {
    #expect(AssistantPrompts.decode("not json").isEmpty)
    #expect(AssistantPrompts.decode("").isEmpty)
}

@Test("every context has a non-empty default set and a unique pageType")
func contextsWellFormed() {
    let types = AssistantPrompts.contexts.map(\.pageType)
    #expect(Set(types).count == types.count)
    for ctx in AssistantPrompts.contexts {
        #expect(!ctx.defaults.isEmpty)
        #expect(!ctx.title.isEmpty)
    }
}
