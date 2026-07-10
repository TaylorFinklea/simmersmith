import Foundation
import Testing
@testable import SimmerSmithKit

// bead simmersmith-b9z — pure, dependency-free (no ModelContainer) so these run under
// plain `swift test`, unlike PrivatePlaneStoreTests.swift's entitled-host-only suite.

@Suite("PreferenceSignalScoring")
struct PreferenceSignalScoringTests {

    // MARK: - accumulate

    @Test
    func accumulateAddsSentimentWithinBounds() {
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: 1) == 1)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 1, sentiment: 1) == 2)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: -1) == -1)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 1, sentiment: 0) == 1)
    }

    // FeedbackComposerView's five-way picker (tag(-2)...tag(2), see
    // Features/Shared/FeedbackComposerView.swift:19-23) sends sentiment ∈ {-2,-1,0,1,2} —
    // ±2 are the "Avoid"/"Great" extremes and the only values a single tap on that
    // picker's ends actually produces. The "feedback→signal scoring" ADR
    // (.docs/ai/decisions.md) calls these out by name as the path the first
    // implementation's ±1-only tests missed; assert them directly rather than repeat
    // that gap. Both land exactly on strongLikeThreshold/dislikeThreshold from a single
    // fresh rating (currentScore: 0).
    @Test
    func accumulateHandlesUIExtremeSentimentValues() {
        // One emphatic tap is MEANT to land on a threshold: Great(+2) == strongLikeThreshold,
        // Avoid(-2) == dislikeThreshold. Good/Bad (±1) require repetition.
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: 2) == 2)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: -2) == -2)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: 2) == PreferenceSignalScoring.strongLikeThreshold)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: -2) == PreferenceSignalScoring.dislikeThreshold)
    }

    /// A caller outside `FeedbackComposerView` must not be able to leapfrog the thresholds
    /// by passing a sentiment the picker can never emit.
    @Test
    func accumulateClampsSentimentInputToTheRangeTheUIEmits() {
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: 99) ==
                PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: PreferenceSignalScoring.sentimentMax))
        #expect(PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: -99) ==
                PreferenceSignalScoring.accumulate(currentScore: 0, sentiment: PreferenceSignalScoring.sentimentMin))
        // and the score bound still holds on top of the input bound
        #expect(PreferenceSignalScoring.accumulate(currentScore: 3, sentiment: 99) == PreferenceSignalScoring.scoreMax)
    }

    @Test
    func accumulateClampsAtUpperBound() {
        #expect(PreferenceSignalScoring.accumulate(currentScore: 2, sentiment: 1) == 3)
        #expect(PreferenceSignalScoring.accumulate(currentScore: 3, sentiment: 1) == 3)
    }

    @Test
    func accumulateClampsAtLowerBound() {
        #expect(PreferenceSignalScoring.accumulate(currentScore: -2, sentiment: -1) == -3)
        #expect(PreferenceSignalScoring.accumulate(currentScore: -3, sentiment: -1) == -3)
    }

    // MARK: - derive: recipe strongLikes threshold boundary (1 vs 2)

    @Test
    func recipeScoreBelowStrongLikeThresholdIsExcluded() {
        let signals = [PreferenceSignal(signalType: "recipe", name: "Tacos", normalizedName: "tacos", score: 1, active: true)]
        #expect(PreferenceSignalScoring.derive(signals: signals).strongLikes.isEmpty)
    }

    @Test
    func recipeScoreAtStrongLikeThresholdIsIncluded() {
        let signals = [PreferenceSignal(signalType: "recipe", name: "Tacos", normalizedName: "tacos", score: 2, active: true)]
        #expect(PreferenceSignalScoring.derive(signals: signals).strongLikes == ["Tacos"])
    }

    // MARK: - derive: cuisine likedCuisines threshold boundary (1 vs 2)

    @Test
    func cuisineScoreBelowLikeThresholdIsExcluded() {
        let signals = [PreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 1, active: true)]
        let result = PreferenceSignalScoring.derive(signals: signals)
        #expect(result.likedCuisines.isEmpty)
        #expect(result.dislikedCuisines.isEmpty)
    }

    @Test
    func cuisineScoreAtLikeThresholdIsIncluded() {
        let signals = [PreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 2, active: true)]
        #expect(PreferenceSignalScoring.derive(signals: signals).likedCuisines == ["Thai"])
    }

    // MARK: - derive: cuisine dislikedCuisines threshold boundary (-1 vs -2)

    @Test
    func cuisineScoreAboveDislikeThresholdIsExcluded() {
        let signals = [PreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: -1, active: true)]
        #expect(PreferenceSignalScoring.derive(signals: signals).dislikedCuisines.isEmpty)
    }

    @Test
    func cuisineScoreAtDislikeThresholdIsIncluded() {
        let signals = [PreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: -2, active: true)]
        #expect(PreferenceSignalScoring.derive(signals: signals).dislikedCuisines == ["Thai"])
    }

    // MARK: - derive: inactive signals excluded

    @Test
    func inactiveSignalsAreExcludedFromAllLists() {
        let signals = [
            PreferenceSignal(signalType: "recipe", name: "Tacos", normalizedName: "tacos", score: 3, active: false),
            PreferenceSignal(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: 3, active: false),
        ]
        let result = PreferenceSignalScoring.derive(signals: signals)
        #expect(result.strongLikes.isEmpty)
        #expect(result.likedCuisines.isEmpty)
        #expect(result.dislikedCuisines.isEmpty)
    }
}
