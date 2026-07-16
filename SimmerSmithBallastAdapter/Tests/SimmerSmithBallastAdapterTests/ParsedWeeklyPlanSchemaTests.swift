import BallastCore
import BallastMock
import SimmerSmithKit
import Testing
@testable import SimmerSmithBallastAdapter

@Suite("ParsedWeeklyPlanSchema")
struct ParsedWeeklyPlanSchemaTests {
    @Test("decodes snake_case wire JSON and canonicalizes intent only at mapping")
    func decodeAndMap() throws {
        let schema = ParsedWeeklyPlanSchema(transcript: "Tuesday lunch leftovers")
        let payload = try schema.decode(
            #"{"entries":[{"day":"Tuesday","slot":"lunch","raw_dish":"leftovers","intent":"LEFTOVERS","evidence":"Tuesday lunch leftovers"}]}"#
        )

        #expect(schema.validate(payload).isEmpty)
        #expect(payload.entries[0].rawDish == "leftovers")
        #expect(payload.toParsed() == ParsedWeeklyPlan(entries: [
            ParsedMealEntry(day: "Tuesday", slot: "lunch", rawDish: "leftovers", intent: "leftovers")
        ]))
    }

    @Test("well-formed semantic failures drive a repair before success")
    func semanticFailureRepairs() async throws {
        let invalid = #"{"entries":[{"day":"Funday","slot":"brunch","raw_dish":"tacos","intent":"invent","evidence":"Tuesday dinner tacos"}]}"#
        let valid = #"{"entries":[{"day":"Tuesday","slot":"dinner","raw_dish":"tacos","intent":"recipe","evidence":"Tuesday dinner tacos"}]}"#
        let generator = RepairingGenerator(
            provider: MockProvider(script: [.text(invalid), .text(valid)]),
            maxRepairs: 2
        )

        let outcome = try await generator.run(
            ParsedWeeklyPlanSchema(transcript: "Tuesday dinner tacos"),
            prompt: "extract meals",
            instructions: nil
        )

        guard case let .ok(payload, attempts, _) = outcome else {
            Issue.record("expected repaired payload")
            return
        }
        #expect(attempts == 2)
        #expect(payload.toParsed().entries[0].day == "Tuesday")
    }

    @Test("fabricated entries fail groundedness even when domain values are valid")
    func rejectsUngroundedEntry() throws {
        let schema = ParsedWeeklyPlanSchema(transcript: "Tuesday lunch tuna salad")
        let payload = try schema.decode(
            #"{"entries":[{"day":"Thursday","slot":"dinner","raw_dish":"tacos","intent":"recipe","evidence":"Thursday dinner tacos"}]}"#
        )

        let errors = schema.validate(payload)
        #expect(errors.contains { $0.contains("entries[0].evidence") })
        #expect(errors.contains { $0.contains("Thursday dinner tacos") })
    }

    @Test("groundedness ignores only case and whitespace differences")
    func conservativeGroundednessNormalization() throws {
        let schema = ParsedWeeklyPlanSchema(transcript: "Tuesday\n lunch   TUNA salad")
        let payload = try schema.decode(
            #"{"entries":[{"day":"Tuesday","slot":"lunch","raw_dish":"tuna salad","intent":"recipe","evidence":"tuesday lunch tuna SALAD"}]}"#
        )

        #expect(schema.validate(payload).isEmpty)
    }

    @Test("empty dishes are allowed only for skip and eatOut")
    func rawDishPolicy() throws {
        let transcript = "Monday dinner skip. Tuesday lunch eat out. Wednesday dinner leftovers."
        let schema = ParsedWeeklyPlanSchema(transcript: transcript)
        let payload = try schema.decode(
            #"{"entries":[{"day":"Monday","slot":"dinner","raw_dish":"","intent":"skip","evidence":"Monday dinner skip"},{"day":"Tuesday","slot":"lunch","raw_dish":"","intent":"eatOut","evidence":"Tuesday lunch eat out"},{"day":"Wednesday","slot":"dinner","raw_dish":"","intent":"leftovers","evidence":"Wednesday dinner leftovers"}]}"#
        )

        let errors = schema.validate(payload)
        #expect(errors.count == 1)
        #expect(errors[0].contains("entries[2].raw_dish"))
    }

    @Test("duplicate day and slot names both entries")
    func duplicateDaySlot() throws {
        let schema = ParsedWeeklyPlanSchema(transcript: "Tuesday lunch tuna, then Tuesday lunch soup")
        let payload = try schema.decode(
            #"{"entries":[{"day":"Tuesday","slot":"lunch","raw_dish":"tuna","intent":"recipe","evidence":"Tuesday lunch tuna"},{"day":"tuesday","slot":"LUNCH","raw_dish":"soup","intent":"recipe","evidence":"Tuesday lunch soup"}]}"#
        )

        let errors = schema.validate(payload)
        #expect(errors.contains { $0.contains("entries[1]") && $0.contains("entries[0]") })
    }

    @Test("empty plan is valid when no meal was stated")
    func emptyPlanIsValid() throws {
        let schema = ParsedWeeklyPlanSchema(transcript: "How does this work?")
        let payload = try schema.decode(#"{"entries":[]}"#)

        #expect(schema.validate(payload).isEmpty)
        #expect(payload.toParsed().entries.isEmpty)
    }

    @Test("repair hint identifies bad values and gives one concrete valid example")
    func repairHint() throws {
        let schema = ParsedWeeklyPlanSchema(transcript: "Tuesday lunch tuna")
        let payload = try schema.decode(
            #"{"entries":[{"day":"Funday","slot":"lunch","raw_dish":"tacos","intent":"recipe","evidence":"made up tacos"}]}"#
        )
        let hint = schema.repairHint(for: schema.validate(payload))

        #expect(hint.contains("Funday"))
        #expect(hint.contains("made up tacos"))
        #expect(hint.contains(#"{"entries":[{"day":"Tuesday""#))
    }
}
