import Foundation
import Testing
import SimmerSmithKit
@testable import SimmerSmith

// recipes_save / weeks_update_meals used to swallow the decode error and report a flat
// "Could not read the recipe payload." `ToolRegistry.decodeReason` turns the thrown
// DecodingError into a field-level reason so the failure is diagnosable on-device.

private func decodeReason<T: Decodable>(_ type: T.Type, from json: String) -> String {
    do {
        _ = try SimmerSmithJSONCoding.makeDecoder().decode(T.self, from: Data(json.utf8))
        return "<no error>"
    } catch {
        return ToolRegistry.decodeReason(error)
    }
}

@Test("a missing required field names that field")
func missingFieldReason() {
    // RecipeDraft requires `name`; everything else defaults.
    let reason = decodeReason(RecipeDraft.self, from: #"{"cuisine":"italian"}"#)
    #expect(reason.contains("name"))
    #expect(reason.contains("missing"))
}

@Test("a wrong-type field names that field")
func typeMismatchReason() {
    // The model sometimes emits steps as plain strings; RecipeStep expects objects.
    let reason = decodeReason(RecipeDraft.self, from: #"{"name":"X","steps":["preheat oven"]}"#)
    #expect(reason.contains("wrong type"))
}

@Test("a non-decoding error falls back to a readable message")
func nonDecodingFallback() {
    struct Boom: LocalizedError { var errorDescription: String? { "kaboom" } }
    #expect(ToolRegistry.decodeReason(Boom()) == "kaboom")
}
