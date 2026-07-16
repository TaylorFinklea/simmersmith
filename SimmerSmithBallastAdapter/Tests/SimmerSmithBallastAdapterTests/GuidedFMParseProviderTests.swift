#if canImport(FoundationModels)
import BallastCore
import FoundationModels
import Testing
@testable import SimmerSmithBallastAdapter

@Suite("GuidedFMParseProvider")
struct GuidedFMParseProviderTests {
    @Test("identity advertises on-device guided generation")
    func identity() {
        let identity = GuidedFMParseProvider().identity

        #expect(identity.privacy == .onDevice)
        #expect(identity.capabilities == [.guidedGeneration])
    }

    @Test("availability reasons mirror Ballast's Foundation Models mapping")
    func availabilityReasons() {
        #expect(GuidedFMParseProvider.mapReason(.deviceNotEligible) == .deviceNotEligible)
        #expect(GuidedFMParseProvider.mapReason(.appleIntelligenceNotEnabled) == .notEnabled)
        #expect(GuidedFMParseProvider.mapReason(.modelNotReady) == .modelNotReady)
    }

    @Test("guided output reserializes to canonical snake_case wire JSON with evidence")
    func canonicalWireJSON() throws {
        let guided = GuidedFMWeeklyPlan(entries: [
            GuidedFMMealEntry(
                day: "Tuesday",
                slot: "lunch",
                rawDish: "tuna salad",
                intent: "recipe",
                evidence: "Tuesday lunch tuna salad"
            )
        ])

        let json = try GuidedFMParseProvider.canonicalJSON(from: guided)
        let payload = try ParsedWeeklyPlanSchema(transcript: "Tuesday lunch tuna salad").decode(json)

        #expect(payload.entries[0].evidence == "Tuesday lunch tuna salad")
        #expect(json.contains(#""raw_dish""#))
        #expect(!json.contains(#""rawDish""#))
    }

    @Test("instructions require extraction and literal evidence, never week completion")
    func instructions() {
        #expect(GuidedFMParseProvider.extractionInstructions.contains("do NOT plan"))
        #expect(GuidedFMParseProvider.extractionInstructions.contains("evidence"))
        #expect(GuidedFMParseProvider.extractionInstructions.contains("empty list"))
    }
}
#endif
