import Foundation
import Testing
import SimmerSmithKit
import AIProviderKit
@testable import SimmerSmith

// bead simmersmith-b9z acceptance criterion (b): "WeekGenContextGatherer.build returns
// non-empty likes/cuisines when signals exist (host test — it is a pure gather over
// injected data, so this is unit-testable today, no z69.3 needed)". `build(...)` is a
// pure transform over already-gathered domain values (see WeekGenContextGatherer.swift's
// doc comment), so this exercises the exact PreferenceSignalScoring.derive wiring
// AppState.gatherWeekGenContext feeds from `preferenceRepository.signals`, without
// needing a ModelContainer or CloudKit entitlement.

@Suite("WeekGenContextGatherer")
struct WeekGenContextGathererTests {
    @Test
    func buildDerivesStrongLikesAndCuisinesFromPreferenceSignals() {
        let signals = [
            PreferenceSignal(signalType: "recipe", name: "Tacos", normalizedName: "tacos", score: 2, active: true),
            PreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 2, active: true),
            PreferenceSignal(signalType: "cuisine", name: "French", normalizedName: "french", score: -2, active: true),
        ]

        let context = WeekGenContextGatherer.build(
            pantryStaples: [],
            dietaryGoal: nil,
            ingredientPreferences: [],
            preferenceSignals: signals,
            recentWeeks: [],
            termAliases: [:]
        )

        #expect(context.strongLikes == ["Tacos"])
        #expect(context.likedCuisines == ["Thai"])
        #expect(context.dislikedCuisines == ["French"])
    }

    @Test
    func buildStaysEmptyWithNoSignals() {
        let context = WeekGenContextGatherer.build(
            pantryStaples: [],
            dietaryGoal: nil,
            ingredientPreferences: [],
            preferenceSignals: [],
            recentWeeks: [],
            termAliases: [:]
        )

        #expect(context.strongLikes.isEmpty)
        #expect(context.likedCuisines.isEmpty)
        #expect(context.dislikedCuisines.isEmpty)
    }
}
