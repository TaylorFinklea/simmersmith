import BallastCore
import BallastMock
import Foundation
import Testing
@testable import SimmerSmithBallastAdapter

/// Coverage validation, baseline-role semantics, and the spec §D1 step 4 differential suite that
/// reuses `VoiceParseScorerFixtures` verbatim to prove the new 4-field baseline path agrees with
/// the current candidate scorer on every shared metric.
@Suite("Voice parse production-cloud baseline scoring")
struct VoiceParseBaselineEvalTests {
    // MARK: - Public entry: structural coverage validation (spec §D1: "caseRuns == 180 alone proves nothing")

    @Test("a valid 180-sample sweep with perfect predictions scores a clean baseline")
    func perfectSweepScoresCleanly() throws {
        let cases = try VoiceParseGoldenSuite.load()
        let metrics = try VoiceParseBaselineEval.score(
            perfectSamples(cases: cases),
            providerName: "production-cloud",
            modelIdentifier: "cloud-model-v1"
        )

        #expect(metrics.role == .productionCloudBaseline)
        #expect(metrics.providerName == "production-cloud")
        #expect(metrics.modelIdentifier == "cloud-model-v1")
        #expect(metrics.corpusID == VoiceParseEvalPolicy.corpusID)
        #expect(metrics.corpusDigest == VoiceParseEvalPolicy.corpusDigest)
        #expect(metrics.caseCount == VoiceParseEvalPolicy.corpusCaseCount)
        #expect(metrics.runsPerCase == VoiceParseEvalPolicy.liveRunsPerCase)
        #expect(metrics.caseRuns == VoiceParseEvalPolicy.corpusCaseCount * VoiceParseEvalPolicy.liveRunsPerCase)
        #expect(metrics.entryPrecision == 1)
        #expect(metrics.entryRecall == 1)
        #expect(metrics.entryF1 == 1)
        #expect(metrics.exactPlanMatchRate == 1)
        #expect(metrics.fieldAccuracy == 1)
        #expect(metrics.unsupportedEntryRate == 0)
        #expect(metrics.safetyUnsupportedEntries == 0)
        #expect(metrics.emptyResultFalseNegativeRate == 0)
        #expect(metrics.repairRate == 0)
        #expect(metrics.fallbackRate == 0)
    }

    @Test("repairRate is always 0 by construction, even with scored failures present")
    func repairRateIsAlwaysZero() throws {
        let cases = try VoiceParseGoldenSuite.load()
        var samples = perfectSamples(cases: cases)
        samples[0] = VoiceParseBaselineSample(
            caseID: samples[0].caseID,
            runIndex: samples[0].runIndex,
            latencyMilliseconds: 100,
            outcome: .failure(category: .schemaDecodeFailure)
        )
        let metrics = try VoiceParseBaselineEval.score(samples, providerName: "x", modelIdentifier: "y")

        #expect(metrics.repairRate == 0)
        #expect(metrics.fallbackRate > 0)
    }

    @Test("a sweep missing a case-run throws")
    func missingCaseRunThrows() throws {
        let cases = try VoiceParseGoldenSuite.load()
        var samples = perfectSamples(cases: cases)
        samples.removeLast()

        #expect(throws: VoiceParseBaselineEval.ScoringError.self) {
            try VoiceParseBaselineEval.score(samples, providerName: "x", modelIdentifier: "y")
        }
    }

    @Test("a sweep with a duplicate case-run throws")
    func duplicateCaseRunThrows() throws {
        let cases = try VoiceParseGoldenSuite.load()
        var samples = perfectSamples(cases: cases)
        samples.append(samples[0])

        #expect(throws: VoiceParseBaselineEval.ScoringError.self) {
            try VoiceParseBaselineEval.score(samples, providerName: "x", modelIdentifier: "y")
        }
    }

    @Test("a sweep containing an unknown case ID throws")
    func unknownCaseRunThrows() throws {
        let cases = try VoiceParseGoldenSuite.load()
        var samples = perfectSamples(cases: cases)
        samples[0] = VoiceParseBaselineSample(
            caseID: "not-a-real-case",
            runIndex: 1,
            latencyMilliseconds: 100,
            outcome: .success(rows: [])
        )

        #expect(throws: VoiceParseBaselineEval.ScoringError.self) {
            try VoiceParseBaselineEval.score(samples, providerName: "x", modelIdentifier: "y")
        }
    }

    @Test("a sweep with an out-of-range run index throws")
    func outOfRangeRunIndexThrows() throws {
        let cases = try VoiceParseGoldenSuite.load()
        var samples = perfectSamples(cases: cases)
        samples[0] = VoiceParseBaselineSample(
            caseID: samples[0].caseID,
            runIndex: 4,
            latencyMilliseconds: 100,
            outcome: .success(rows: [])
        )

        #expect(throws: VoiceParseBaselineEval.ScoringError.self) {
            try VoiceParseBaselineEval.score(samples, providerName: "x", modelIdentifier: "y")
        }
    }

    // MARK: - Differential suite (spec §D1 step 4): reuse the characterization fixtures verbatim

    @Test("evidence-only span divergence: shared metrics match; exact/field differ as declared")
    func normalizationAndEvidenceSpanDivergence() async throws {
        let fixture = VoiceParseScorerFixtures.normalizationAndEvidenceSpan
        try await assertSharedMetricsMatch(fixture)

        let candidate = try await candidateMetrics(for: fixture)
        let baseline = baselineMetrics(for: fixture)

        #expect(candidate.exactPlanMatchRate == 0)
        #expect(baseline.exactPlanMatchRate == 1)
        #expect(candidate.fieldAccuracy == 0.8)
        #expect(baseline.fieldAccuracy == 1)
    }

    @Test("multiset intersection capping matches between candidate and baseline")
    func multisetIntersectionCapping() async throws {
        let fixture = VoiceParseScorerFixtures.multisetIntersection
        try await assertSharedMetricsMatch(fixture)

        let candidate = try await candidateMetrics(for: fixture)
        let baseline = baselineMetrics(for: fixture)

        #expect(candidate.exactPlanMatchRate == 0)
        #expect(baseline.exactPlanMatchRate == 0)
        #expect(candidate.fieldAccuracy == 0.4)
        #expect(abs(baseline.fieldAccuracy - 5.0 / 12.0) < 0.0000001)
    }

    @Test("a successful empty result against a nonempty label scores identically")
    func successfulEmptyAgainstNonempty() async throws {
        try await assertSharedMetricsMatch(VoiceParseScorerFixtures.successfulEmptyAgainstNonempty)
    }

    @Test("a failed call against a nonempty label scores identically")
    func failedAgainstNonempty() async throws {
        try await assertSharedMetricsMatch(VoiceParseScorerFixtures.failedAgainstNonempty)
    }

    @Test("a successful empty result against an empty label scores identically")
    func successfulEmptyAgainstEmpty() async throws {
        try await assertSharedMetricsMatch(VoiceParseScorerFixtures.successfulEmptyAgainstEmpty)
    }

    @Test("a safety-critical extra entry scores identically, including safetyUnsupportedEntries")
    func safetyCriticalExtraEntry() async throws {
        try await assertSharedMetricsMatch(VoiceParseScorerFixtures.safetyCriticalExtraEntry)
    }

    @Test("a non-safety extra entry scores identically")
    func nonSafetyExtraEntry() async throws {
        try await assertSharedMetricsMatch(VoiceParseScorerFixtures.nonSafetyExtraEntry)
    }

    @Test("crossed partial rows with a tie: shared metrics match; field accuracy differs by denominator")
    func crossedPartialRowsWithTie() async throws {
        let fixture = VoiceParseScorerFixtures.crossedPartialRowsWithTie
        try await assertSharedMetricsMatch(fixture)

        let candidate = try await candidateMetrics(for: fixture)
        let baseline = baselineMetrics(for: fixture)

        #expect(candidate.exactPlanMatchRate == 0)
        #expect(baseline.exactPlanMatchRate == 0)
        #expect(candidate.fieldAccuracy == 0.6)
        #expect(baseline.fieldAccuracy == 0.75)
    }

    // MARK: - Support

    private func perfectSamples(cases: [VoiceParseGoldenCase]) -> [VoiceParseBaselineSample] {
        cases.flatMap { goldenCase in
            (1...VoiceParseEvalPolicy.liveRunsPerCase).map { runIndex in
                VoiceParseBaselineSample(
                    caseID: goldenCase.id,
                    runIndex: runIndex,
                    latencyMilliseconds: 120,
                    outcome: .success(rows: goldenCase.expectedEntries.map {
                        VoiceParseBaselineSample.Row(
                            day: $0.day, slot: $0.slot, rawDish: $0.rawDish, intent: $0.intent
                        )
                    })
                )
            }
        }
    }

    private func candidateMetrics(for fixture: VoiceParseScorerFixtures.Fixture) async throws -> VoiceParseEvalMetrics {
        let run = await VoiceParseEvalRunner(runsPerCase: 1).run(
            [fixture.goldenCase],
            with: try VoiceParseScorerFixtures.mockProvider(for: fixture)
        )
        return run.metrics
    }

    private func baselineMetrics(for fixture: VoiceParseScorerFixtures.Fixture) -> VoiceParseEvalMetrics {
        VoiceParseBaselineEval.scoreAgainstCases(
            [VoiceParseScorerFixtures.baselineSample(for: fixture)],
            cases: [fixture.goldenCase],
            providerName: "production-cloud",
            modelIdentifier: "cloud-model",
            corpusID: VoiceParseEvalPolicy.corpusID,
            corpusDigest: VoiceParseEvalPolicy.corpusDigest,
            caseCount: 1,
            runsPerCase: 1
        )
    }

    /// The metrics spec §D1's baseline-role table declares identical after 4-field projection —
    /// everything except `exactPlanMatchRate` and `fieldAccuracy`, which the table explicitly
    /// allows to diverge (evidence is absent from the 4-field baseline math).
    private func assertSharedMetricsMatch(_ fixture: VoiceParseScorerFixtures.Fixture) async throws {
        let candidate = try await candidateMetrics(for: fixture)
        let baseline = baselineMetrics(for: fixture)

        #expect(closeEnough(candidate.entryPrecision, baseline.entryPrecision))
        #expect(closeEnough(candidate.entryRecall, baseline.entryRecall))
        #expect(closeEnough(candidate.entryF1, baseline.entryF1))
        #expect(closeEnough(candidate.unsupportedEntryRate, baseline.unsupportedEntryRate))
        #expect(candidate.safetyUnsupportedEntries == baseline.safetyUnsupportedEntries)
        #expect(closeEnough(candidate.emptyResultFalseNegativeRate, baseline.emptyResultFalseNegativeRate))
    }

    private func closeEnough(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) < 0.0000001
    }
}
