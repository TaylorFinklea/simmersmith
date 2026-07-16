import BallastCore
import Foundation

public struct VoiceParseGoldenCase: Codable, Sendable, Equatable {
    public let id: String
    public let category: String
    public let transcript: String
    public let expectedEntries: [WeeklyPlanWireEntry]
    public let whyOmitted: [String]
    public let safetyCritical: Bool

    public var expectedPayload: WeeklyPlanWirePayload {
        WeeklyPlanWirePayload(entries: expectedEntries)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case category
        case transcript
        case expectedEntries = "expected_entries"
        case whyOmitted = "why_omitted"
        case safetyCritical = "safety_critical"
    }
}

public enum VoiceParseGoldenSuite {
    public enum LoadError: Error, Sendable {
        case resourceMissing
    }

    public static func load() throws -> [VoiceParseGoldenCase] {
        guard let url = Bundle.module.url(
            forResource: "voice-plan-golden",
            withExtension: "json"
        ) else {
            throw LoadError.resourceMissing
        }
        return try JSONDecoder().decode([VoiceParseGoldenCase].self, from: Data(contentsOf: url))
    }
}

public enum VoiceParseEvalCommandLine {
    public enum Mode: Sendable, Equatable {
        case mock
        case live(baselineURL: URL)
    }

    public enum ParseError: Error, Sendable, Equatable {
        case invalidArguments([String])
    }

    public static func parse(_ arguments: [String]) throws -> Mode {
        if arguments == ["--mock"] {
            return .mock
        }
        if arguments.count == 3,
           arguments[0] == "--live",
           arguments[1] == "--baseline",
           !arguments[2].isEmpty,
           !arguments[2].hasPrefix("--") {
            return .live(baselineURL: URL(fileURLWithPath: arguments[2]))
        }
        throw ParseError.invalidArguments(arguments)
    }
}

public enum VoiceParseEvalPolicy {
    public static let corpusID = "simmersmith-voice-plan-v1"
    public static let corpusCaseCount = 60
    public static let liveRunsPerCase = 3
    public static let maximumSafetyUnsupportedEntries = 0
    public static let maximumF1DropFromCloud = 0.03
    public static let maximumExactPlanMatchDropFromCloud = 0.05

    public static func isNonInferior(
        candidate: VoiceParseEvalMetrics,
        cloudBaseline: VoiceParseEvalMetrics
    ) -> Bool {
        hasValidLiveProvenance(candidate)
            && hasValidLiveProvenance(cloudBaseline)
            && candidate.corpusID == cloudBaseline.corpusID
            && candidate.caseCount == cloudBaseline.caseCount
            && candidate.runsPerCase == cloudBaseline.runsPerCase
            && candidate.caseRuns == cloudBaseline.caseRuns
            && candidate.safetyUnsupportedEntries <= maximumSafetyUnsupportedEntries
            && candidate.entryF1 + maximumF1DropFromCloud >= cloudBaseline.entryF1
            && candidate.exactPlanMatchRate + maximumExactPlanMatchDropFromCloud
                >= cloudBaseline.exactPlanMatchRate
    }

    private static func hasValidLiveProvenance(_ metrics: VoiceParseEvalMetrics) -> Bool {
        metrics.corpusID == corpusID
            && metrics.caseCount == corpusCaseCount
            && metrics.runsPerCase == liveRunsPerCase
            && metrics.caseRuns == corpusCaseCount * liveRunsPerCase
    }
}

public struct VoiceParseEvalMetrics: Codable, Sendable, Equatable {
    public let corpusID: String
    public let caseCount: Int
    public let runsPerCase: Int
    public let caseRuns: Int
    public let entryPrecision: Double
    public let entryRecall: Double
    public let entryF1: Double
    public let exactPlanMatchRate: Double
    public let fieldAccuracy: Double
    public let unsupportedEntryRate: Double
    public let safetyUnsupportedEntries: Int
    public let emptyResultFalseNegativeRate: Double
    public let repairRate: Double
    public let fallbackRate: Double
    public let meanLatencyMilliseconds: Double
}

public struct VoiceParseEvalRun: Sendable {
    public let ballastReport: EvalReport
    public let metrics: VoiceParseEvalMetrics
}

public struct VoiceParseEvalRunner: Sendable {
    private let runsPerCase: Int

    public init(runsPerCase: Int = VoiceParseEvalPolicy.liveRunsPerCase) {
        self.runsPerCase = max(1, runsPerCase)
    }

    public func run(
        _ cases: [VoiceParseGoldenCase],
        with provider: any LanguageProvider
    ) async -> VoiceParseEvalRun {
        let collector = VoiceParseMetricCollector()
        var evalCases: [any EvalCase] = []
        for goldenCase in cases {
            for runIndex in 1...runsPerCase {
                evalCases.append(
                    VoiceParseHarnessCase(
                        goldenCase: goldenCase,
                        runIndex: runIndex,
                        collector: collector
                    )
                )
            }
        }

        let ballastReport = await EvalHarness().run(evalCases, with: provider)
        let samples = await collector.samples
        return VoiceParseEvalRun(
            ballastReport: ballastReport,
            metrics: VoiceParseScorer.score(
                samples,
                corpusID: VoiceParseEvalPolicy.corpusID,
                caseCount: cases.count,
                runsPerCase: runsPerCase
            )
        )
    }
}

private struct VoiceParseHarnessCase: EvalCase {
    let goldenCase: VoiceParseGoldenCase
    let runIndex: Int
    let collector: VoiceParseMetricCollector

    var name: String { "\(goldenCase.id)-run-\(runIndex)" }

    func run(with provider: any LanguageProvider, budget _: Budget?) async -> EvalResult {
        let startedAt = Date()
        let budget = Budget(BudgetLimits(maxSteps: 3))
        let generator = RepairingGenerator(provider: provider, budget: budget, maxRepairs: 2)

        func result(
            predicted: WeeklyPlanWirePayload?,
            attempts: Int,
            fallback: Bool,
            detail: String
        ) async -> EvalResult {
            let latency = Date().timeIntervalSince(startedAt) * 1_000
            let snapshot = await budget.snapshot()
            let passed = predicted.map {
                VoiceParseScorer.exactMatch($0.entries, goldenCase.expectedEntries)
            } ?? false
            await collector.record(
                VoiceParseEvalSample(
                    goldenCase: goldenCase,
                    predictedEntries: predicted?.entries ?? [],
                    producedResult: predicted != nil,
                    attempts: attempts,
                    fallback: fallback,
                    latencyMilliseconds: latency
                )
            )
            return EvalResult(
                name: name,
                passed: passed,
                attempts: attempts,
                usage: TokenUsage(
                    inputTokens: snapshot.inputTokens,
                    outputTokens: snapshot.outputTokens
                ),
                detail: detail
            )
        }

        do {
            switch try await generator.run(
                ParsedWeeklyPlanSchema(transcript: goldenCase.transcript),
                prompt: goldenCase.transcript,
                instructions: nil
            ) {
            case .ok(let value, let attempts, _):
                return await result(
                    predicted: value,
                    attempts: attempts,
                    fallback: false,
                    detail: "evaluated"
                )
            case .failed(_, let attempts, _):
                return await result(
                    predicted: nil,
                    attempts: attempts,
                    fallback: true,
                    detail: "FM leg would fall back"
                )
            }
        } catch {
            return await result(
                predicted: nil,
                attempts: 0,
                fallback: true,
                detail: "FM leg threw and would fall back"
            )
        }
    }
}

private actor VoiceParseMetricCollector {
    private(set) var samples: [VoiceParseEvalSample] = []

    func record(_ sample: VoiceParseEvalSample) {
        samples.append(sample)
    }
}

private struct VoiceParseEvalSample: Sendable {
    let goldenCase: VoiceParseGoldenCase
    let predictedEntries: [WeeklyPlanWireEntry]
    let producedResult: Bool
    let attempts: Int
    let fallback: Bool
    let latencyMilliseconds: Double
}

private enum VoiceParseScorer {
    private struct MealSignature: Hashable {
        let day: String
        let slot: String
        let rawDish: String
        let intent: String
    }

    private struct FullSignature: Hashable {
        let meal: MealSignature
        let evidence: String
    }

    static func exactMatch(
        _ predicted: [WeeklyPlanWireEntry],
        _ expected: [WeeklyPlanWireEntry]
    ) -> Bool {
        counts(predicted.map(fullSignature)) == counts(expected.map(fullSignature))
    }

    static func score(
        _ samples: [VoiceParseEvalSample],
        corpusID: String,
        caseCount: Int,
        runsPerCase: Int
    ) -> VoiceParseEvalMetrics {
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
        var repairs = 0
        var fallbacks = 0
        var latency = 0.0

        for sample in samples {
            let predictedMeals = sample.predictedEntries.map(mealSignature)
            let expectedMeals = sample.goldenCase.expectedEntries.map(mealSignature)
            let matched = intersectionCount(predictedMeals, expectedMeals)
            let unsupported = predictedMeals.count - matched

            truePositiveEntries += matched
            predictedEntries += predictedMeals.count
            expectedEntries += expectedMeals.count
            unsupportedEntries += unsupported
            if sample.goldenCase.safetyCritical {
                safetyUnsupportedEntries += unsupported
            }
            if sample.producedResult,
               exactMatch(sample.predictedEntries, sample.goldenCase.expectedEntries) {
                exactMatches += 1
            }

            let fieldResult = fieldMatches(
                predicted: sample.predictedEntries,
                expected: sample.goldenCase.expectedEntries
            )
            equalFields += fieldResult.equal
            expectedFields += fieldResult.total

            if !sample.goldenCase.expectedEntries.isEmpty {
                nonemptyExpectedRuns += 1
                if sample.producedResult && sample.predictedEntries.isEmpty {
                    emptyFalseNegatives += 1
                }
            }
            if sample.attempts > 1 { repairs += 1 }
            if sample.fallback { fallbacks += 1 }
            latency += sample.latencyMilliseconds
        }

        let precision = ratio(truePositiveEntries, predictedEntries, emptyValue: 1)
        let recall = ratio(truePositiveEntries, expectedEntries, emptyValue: 1)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        let count = samples.count

        return VoiceParseEvalMetrics(
            corpusID: corpusID,
            caseCount: caseCount,
            runsPerCase: runsPerCase,
            caseRuns: count,
            entryPrecision: precision,
            entryRecall: recall,
            entryF1: f1,
            exactPlanMatchRate: ratio(exactMatches, count),
            fieldAccuracy: ratio(equalFields, expectedFields, emptyValue: 1),
            unsupportedEntryRate: ratio(unsupportedEntries, predictedEntries),
            safetyUnsupportedEntries: safetyUnsupportedEntries,
            emptyResultFalseNegativeRate: ratio(emptyFalseNegatives, nonemptyExpectedRuns),
            repairRate: ratio(repairs, count),
            fallbackRate: ratio(fallbacks, count),
            meanLatencyMilliseconds: count == 0 ? 0 : latency / Double(count)
        )
    }

    private static func mealSignature(_ entry: WeeklyPlanWireEntry) -> MealSignature {
        MealSignature(
            day: normalize(entry.day),
            slot: normalize(entry.slot),
            rawDish: normalize(entry.rawDish),
            intent: normalize(entry.intent)
        )
    }

    private static func fullSignature(_ entry: WeeklyPlanWireEntry) -> FullSignature {
        FullSignature(meal: mealSignature(entry), evidence: normalize(entry.evidence))
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func counts<T: Hashable>(_ values: [T]) -> [T: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func intersectionCount<T: Hashable>(_ lhs: [T], _ rhs: [T]) -> Int {
        let left = counts(lhs)
        let right = counts(rhs)
        return left.reduce(into: 0) { total, pair in
            total += min(pair.value, right[pair.key, default: 0])
        }
    }

    private static func fieldMatches(
        predicted: [WeeklyPlanWireEntry],
        expected: [WeeklyPlanWireEntry]
    ) -> (equal: Int, total: Int) {
        var available = predicted
        var equal = 0
        for expectedEntry in expected {
            guard !available.isEmpty else { continue }
            let scored = available.enumerated().map { index, predictedEntry in
                (index, equalFieldCount(predictedEntry, expectedEntry))
            }
            guard let best = scored.max(by: { $0.1 < $1.1 }) else { continue }
            equal += best.1
            available.remove(at: best.0)
        }
        return (equal, expected.count * 5)
    }

    private static func equalFieldCount(
        _ lhs: WeeklyPlanWireEntry,
        _ rhs: WeeklyPlanWireEntry
    ) -> Int {
        [
            normalize(lhs.day) == normalize(rhs.day),
            normalize(lhs.slot) == normalize(rhs.slot),
            normalize(lhs.rawDish) == normalize(rhs.rawDish),
            normalize(lhs.intent) == normalize(rhs.intent),
            normalize(lhs.evidence) == normalize(rhs.evidence),
        ].filter { $0 }.count
    }

    private static func ratio(
        _ numerator: Int,
        _ denominator: Int,
        emptyValue: Double = 0
    ) -> Double {
        denominator == 0 ? emptyValue : Double(numerator) / Double(denominator)
    }
}
