import BallastCore
import BallastMock
import Foundation
import Testing
@testable import SimmerSmithBallastAdapter

/// Pins the *current* private `VoiceParseScorer` behavior (spec §D1 step 1), driven entirely
/// through the existing public surface — `VoiceParseEvalRunner` with a scripted `MockProvider` —
/// exactly as `VoiceParseGoldenEvalTests` does. Runs green against unrefactored code and must stay
/// green after the MealSignature/normalize/counts/intersectionCount extraction (spec §D1 step 2:
/// "no behavior change"). `VoiceParseBaselineEvalTests`' differential suite reuses these same
/// fixtures verbatim (spec §D1 step 4).
@Suite("Voice parse candidate scorer characterization")
struct VoiceParseScorerCharacterizationTests {
    @Test("case/whitespace normalization is transparent; evidence-only span divergence breaks exact match")
    func normalizationAndEvidenceSpanDivergence() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.normalizationAndEvidenceSpan)

        #expect(run.metrics.entryPrecision == 1)
        #expect(run.metrics.entryRecall == 1)
        #expect(run.metrics.entryF1 == 1)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 0.8)
        #expect(run.metrics.unsupportedEntryRate == 0)
        #expect(run.metrics.safetyUnsupportedEntries == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
        #expect(run.metrics.repairRate == 0)
        #expect(run.metrics.fallbackRate == 0)
    }

    @Test("expected [A,A,B] vs predicted [A,B] caps the multiset intersection at what was produced")
    func multisetIntersectionCapping() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.multisetIntersection)

        #expect(run.metrics.entryPrecision == 1)
        #expect(abs(run.metrics.entryRecall - 2.0 / 3.0) < 0.0000001)
        #expect(run.metrics.entryF1 == 0.8)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 0.4)
        #expect(run.metrics.unsupportedEntryRate == 0)
        #expect(run.metrics.safetyUnsupportedEntries == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
    }

    @Test("successful call with an empty result against a nonempty label is a false negative")
    func successfulEmptyAgainstNonempty() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.successfulEmptyAgainstNonempty)

        #expect(run.metrics.entryPrecision == 1)
        #expect(run.metrics.entryRecall == 0)
        #expect(run.metrics.entryF1 == 0)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 0)
        #expect(run.metrics.unsupportedEntryRate == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 1)
        #expect(run.metrics.fallbackRate == 0)
    }

    @Test("a failed call against a nonempty label is never counted as an empty-result false negative")
    func failedAgainstNonempty() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.failedAgainstNonempty)

        #expect(run.metrics.entryPrecision == 1)
        #expect(run.metrics.entryRecall == 0)
        #expect(run.metrics.entryF1 == 0)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
        #expect(run.metrics.repairRate == 0)
        #expect(run.metrics.fallbackRate == 1)
    }

    @Test("a successful empty result against an empty label is a trivial exact match")
    func successfulEmptyAgainstEmpty() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.successfulEmptyAgainstEmpty)

        #expect(run.metrics.entryPrecision == 1)
        #expect(run.metrics.entryRecall == 1)
        #expect(run.metrics.entryF1 == 1)
        #expect(run.metrics.exactPlanMatchRate == 1)
        #expect(run.metrics.fieldAccuracy == 1)
        #expect(run.metrics.unsupportedEntryRate == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
        #expect(run.metrics.fallbackRate == 0)
    }

    @Test("a safety-critical extra entry counts toward safetyUnsupportedEntries")
    func safetyCriticalExtraEntryCounts() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.safetyCriticalExtraEntry)

        #expect(run.metrics.entryPrecision == 0.5)
        #expect(run.metrics.entryRecall == 1)
        #expect(abs(run.metrics.entryF1 - 2.0 / 3.0) < 0.0000001)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 1)
        #expect(run.metrics.unsupportedEntryRate == 0.5)
        #expect(run.metrics.safetyUnsupportedEntries == 1)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
    }

    @Test("a non-safety extra entry is unsupported but never counted toward safetyUnsupportedEntries")
    func nonSafetyExtraEntryDoesNotCount() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.nonSafetyExtraEntry)

        #expect(run.metrics.entryPrecision == 0.5)
        #expect(run.metrics.entryRecall == 1)
        #expect(abs(run.metrics.entryF1 - 2.0 / 3.0) < 0.0000001)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 1)
        #expect(run.metrics.unsupportedEntryRate == 0.5)
        #expect(run.metrics.safetyUnsupportedEntries == 0)
    }

    @Test("crossed partial rows with a full 4-way tie pin the greedy pairing's first-wins order")
    func crossedPartialRowsWithTie() async throws {
        let run = try await runFixture(VoiceParseScorerFixtures.crossedPartialRowsWithTie)

        #expect(run.metrics.entryPrecision == 0)
        #expect(run.metrics.entryRecall == 0)
        #expect(run.metrics.entryF1 == 0)
        #expect(run.metrics.exactPlanMatchRate == 0)
        #expect(run.metrics.fieldAccuracy == 0.6)
        #expect(run.metrics.unsupportedEntryRate == 1)
        #expect(run.metrics.safetyUnsupportedEntries == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
    }

    // MARK: - Support

    private func runFixture(_ fixture: VoiceParseScorerFixtures.Fixture) async throws -> VoiceParseEvalRun {
        await VoiceParseEvalRunner(runsPerCase: 1).run(
            [fixture.goldenCase],
            with: try VoiceParseScorerFixtures.mockProvider(for: fixture)
        )
    }
}
