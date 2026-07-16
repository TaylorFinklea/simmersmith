import Foundation

/// One call-site result from a production-cloud baseline sweep (`CloudParseService.parse`, run
/// outside Ballast's repair loop). Transcript-free by design (Sol F4): the only link back to a
/// golden case is `caseID`, so this type is safe to persist without ever carrying corpus text.
public struct VoiceParseBaselineSample: Sendable, Equatable {
    /// A single production parse row — the 4 fields `CloudParseService` returns. No `evidence`:
    /// the production wire payload's evidence field is not scored in the baseline role.
    public struct Row: Sendable, Equatable {
        public let day: String
        public let slot: String
        public let rawDish: String
        public let intent: String

        public init(day: String, slot: String, rawDish: String, intent: String) {
            self.day = day
            self.slot = slot
            self.rawDish = rawDish
            self.intent = intent
        }
    }

    /// Per the Run-validity policy (spec §Run-validity policy): only scored-class failures ever
    /// reach the scorer as `.failure` — abort-class failures invalidate the sweep before scoring.
    public enum Outcome: Sendable, Equatable {
        case success(rows: [Row])
        case failure(category: VoiceParseBaselineFailureCategory)
    }

    public let caseID: String
    public let runIndex: Int
    public let latencyMilliseconds: Double
    public let outcome: Outcome

    public init(caseID: String, runIndex: Int, latencyMilliseconds: Double, outcome: Outcome) {
        self.caseID = caseID
        self.runIndex = runIndex
        self.latencyMilliseconds = latencyMilliseconds
        self.outcome = outcome
    }
}

/// Scored-class production parse failures (spec §Run-validity policy: "strictly an HTTP-success
/// response whose body failed `BYOKeyProvider.extractJSONObject` + `ParsedWeeklyPlan` decode,
/// including empty or non-JSON bodies"). Two verbs, two categories: extraction never finding a
/// JSON object (which subsumes empty/non-JSON bodies) vs. a JSON object that doesn't decode as
/// `ParsedWeeklyPlan`.
public enum VoiceParseBaselineFailureCategory: String, Sendable, Equatable, Codable, CaseIterable {
    case emptyOrNonJSONBody
    case schemaDecodeFailure
}

/// Public baseline scoring path (spec §D1): scores a production-cloud sweep against the same
/// frozen golden corpus the candidate scorer uses, applying the baseline-role 4-field semantics
/// (no evidence, no repair loop). `VoiceParseScorer` stays private and untouched; this type reuses
/// only the shared `MealSignature`/normalize/counts/intersectionCount primitives.
public enum VoiceParseBaselineEval {
    public enum ScoringError: Error, Sendable, Equatable {
        case corpusDigestMismatch(expected: String, actual: String)
        case missingCaseRun(caseID: String, runIndex: Int)
        case duplicateCaseRun(caseID: String, runIndex: Int)
        case unknownCaseRun(caseID: String, runIndex: Int)
    }

    /// Loads the frozen corpus internally, verifies its digest against
    /// `VoiceParseEvalPolicy.corpusDigest`, and structurally validates that every
    /// `(caseID, runIndex 1...liveRunsPerCase)` pair appears exactly once before scoring —
    /// `caseRuns == 180` alone proves nothing (spec §D1).
    public static func score(
        _ samples: [VoiceParseBaselineSample],
        providerName: String,
        modelIdentifier: String
    ) throws -> VoiceParseEvalMetrics {
        let cases = try VoiceParseGoldenSuite.load()
        let digest = try VoiceParseGoldenSuite.digest()
        guard digest == VoiceParseEvalPolicy.corpusDigest else {
            throw ScoringError.corpusDigestMismatch(expected: VoiceParseEvalPolicy.corpusDigest, actual: digest)
        }
        try validateCoverage(samples, cases: cases)

        return scoreAgainstCases(
            samples,
            cases: cases,
            providerName: providerName,
            modelIdentifier: modelIdentifier,
            corpusID: VoiceParseEvalPolicy.corpusID,
            corpusDigest: digest,
            caseCount: VoiceParseEvalPolicy.corpusCaseCount,
            runsPerCase: VoiceParseEvalPolicy.liveRunsPerCase
        )
    }

    /// The pure scoring core, decoupled from corpus loading/coverage validation so differential
    /// tests can reuse the exact characterization fixture set against arbitrary (non-frozen-corpus)
    /// golden cases. Not part of the public surface — the public `score(_:providerName:
    /// modelIdentifier:)` above is the only entry point that ships production honesty guarantees.
    static func scoreAgainstCases(
        _ samples: [VoiceParseBaselineSample],
        cases: [VoiceParseGoldenCase],
        providerName: String,
        modelIdentifier: String,
        corpusID: String,
        corpusDigest: String,
        caseCount: Int,
        runsPerCase: Int
    ) -> VoiceParseEvalMetrics {
        let expectedByID = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, $0) })

        var truePositiveEntries = 0
        var predictedEntries = 0
        var expectedEntries = 0
        var exactMatches = 0
        var equalFields = 0
        var expectedFields = 0
        var unsupportedEntries = 0
        var safetyUnsupportedEntries = 0
        var nonemptyExpectedRuns = 0
        var emptyFalseNegatives = 0
        var scoredFailures = 0
        var latency = 0.0

        for sample in samples {
            guard let goldenCase = expectedByID[sample.caseID] else { continue }
            let expectedMeals = goldenCase.expectedEntries.map {
                VoiceParseScoringPrimitives.mealSignature(
                    day: $0.day, slot: $0.slot, rawDish: $0.rawDish, intent: $0.intent
                )
            }

            let rows: [VoiceParseBaselineSample.Row]
            let isSuccess: Bool
            switch sample.outcome {
            case .success(let successRows):
                rows = successRows
                isSuccess = true
            case .failure:
                rows = []
                isSuccess = false
            }

            let predictedMeals = rows.map {
                VoiceParseScoringPrimitives.mealSignature(
                    day: $0.day, slot: $0.slot, rawDish: $0.rawDish, intent: $0.intent
                )
            }
            let matched = VoiceParseScoringPrimitives.intersectionCount(predictedMeals, expectedMeals)
            let unsupported = predictedMeals.count - matched

            truePositiveEntries += matched
            predictedEntries += predictedMeals.count
            expectedEntries += expectedMeals.count
            unsupportedEntries += unsupported
            if goldenCase.safetyCritical {
                safetyUnsupportedEntries += unsupported
            }
            if isSuccess,
               VoiceParseScoringPrimitives.counts(predictedMeals) == VoiceParseScoringPrimitives.counts(expectedMeals) {
                exactMatches += 1
            }

            let fieldResult = fieldMatches(predicted: rows, expected: goldenCase.expectedEntries)
            equalFields += fieldResult.equal
            expectedFields += fieldResult.total

            if !goldenCase.expectedEntries.isEmpty {
                nonemptyExpectedRuns += 1
                if isSuccess && rows.isEmpty {
                    emptyFalseNegatives += 1
                }
            }
            if !isSuccess { scoredFailures += 1 }
            latency += sample.latencyMilliseconds
        }

        let precision = VoiceParseScoringPrimitives.ratio(truePositiveEntries, predictedEntries, emptyValue: 1)
        let recall = VoiceParseScoringPrimitives.ratio(truePositiveEntries, expectedEntries, emptyValue: 1)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        let count = samples.count

        return VoiceParseEvalMetrics(
            role: .productionCloudBaseline,
            providerName: providerName,
            modelIdentifier: modelIdentifier,
            corpusID: corpusID,
            corpusDigest: corpusDigest,
            caseCount: caseCount,
            runsPerCase: runsPerCase,
            caseRuns: count,
            entryPrecision: precision,
            entryRecall: recall,
            entryF1: f1,
            exactPlanMatchRate: VoiceParseScoringPrimitives.ratio(exactMatches, count),
            fieldAccuracy: VoiceParseScoringPrimitives.ratio(equalFields, expectedFields, emptyValue: 1),
            unsupportedEntryRate: VoiceParseScoringPrimitives.ratio(unsupportedEntries, predictedEntries),
            safetyUnsupportedEntries: safetyUnsupportedEntries,
            emptyResultFalseNegativeRate: VoiceParseScoringPrimitives.ratio(emptyFalseNegatives, nonemptyExpectedRuns),
            repairRate: 0.0,
            fallbackRate: VoiceParseScoringPrimitives.ratio(scoredFailures, count),
            meanLatencyMilliseconds: count == 0 ? 0 : latency / Double(count)
        )
    }

    private struct CaseRunKey: Hashable {
        let caseID: String
        let runIndex: Int
    }

    private static func validateCoverage(
        _ samples: [VoiceParseBaselineSample],
        cases: [VoiceParseGoldenCase]
    ) throws {
        let validIDs = Set(cases.map(\.id))
        var seen: Set<CaseRunKey> = []
        for sample in samples {
            guard validIDs.contains(sample.caseID),
                  (1...VoiceParseEvalPolicy.liveRunsPerCase).contains(sample.runIndex) else {
                throw ScoringError.unknownCaseRun(caseID: sample.caseID, runIndex: sample.runIndex)
            }
            let key = CaseRunKey(caseID: sample.caseID, runIndex: sample.runIndex)
            guard seen.insert(key).inserted else {
                throw ScoringError.duplicateCaseRun(caseID: sample.caseID, runIndex: sample.runIndex)
            }
        }
        for goldenCase in cases {
            for runIndex in 1...VoiceParseEvalPolicy.liveRunsPerCase {
                guard seen.contains(CaseRunKey(caseID: goldenCase.id, runIndex: runIndex)) else {
                    throw ScoringError.missingCaseRun(caseID: goldenCase.id, runIndex: runIndex)
                }
            }
        }
    }

    private static func fieldMatches(
        predicted: [VoiceParseBaselineSample.Row],
        expected: [WeeklyPlanWireEntry]
    ) -> (equal: Int, total: Int) {
        var available = predicted
        var equal = 0
        for expectedEntry in expected {
            guard !available.isEmpty else { continue }
            let scored = available.enumerated().map { index, predictedRow in
                (index, equalFieldCount(predictedRow, expectedEntry))
            }
            guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
            equal += best.1
            available.remove(at: best.0)
        }
        return (equal, expected.count * 4)
    }

    private static func equalFieldCount(
        _ lhs: VoiceParseBaselineSample.Row,
        _ rhs: WeeklyPlanWireEntry
    ) -> Int {
        [
            VoiceParseScoringPrimitives.normalize(lhs.day) == VoiceParseScoringPrimitives.normalize(rhs.day),
            VoiceParseScoringPrimitives.normalize(lhs.slot) == VoiceParseScoringPrimitives.normalize(rhs.slot),
            VoiceParseScoringPrimitives.normalize(lhs.rawDish) == VoiceParseScoringPrimitives.normalize(rhs.rawDish),
            VoiceParseScoringPrimitives.normalize(lhs.intent) == VoiceParseScoringPrimitives.normalize(rhs.intent),
        ].filter { $0 }.count
    }
}
