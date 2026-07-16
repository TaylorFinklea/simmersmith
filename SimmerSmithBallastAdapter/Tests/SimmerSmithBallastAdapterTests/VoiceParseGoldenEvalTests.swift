import BallastCore
import BallastMock
import Foundation
import Testing
@testable import SimmerSmithBallastAdapter

@Suite("Voice parse golden evaluation")
struct VoiceParseGoldenEvalTests {
    @Test("frozen corpus has 50-75 uniquely labeled cases across every approved stratum")
    func corpusCoverage() throws {
        let cases = try VoiceParseGoldenSuite.load()
        let requiredCategories = Set([
            "no-meal-chatter", "multi-entry", "corrections", "negation",
            "tentative", "missing-fields", "relative-days", "special-intents",
            "disfluencies", "asr-corruption", "duplicates-conflicts", "instruction-like",
        ])

        #expect(cases.count == 60)
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.category)) == requiredCategories)
        #expect(cases.filter(\.safetyCritical).count >= 20)
        #expect(cases.allSatisfy { !$0.expectedEntries.isEmpty || !$0.whyOmitted.isEmpty })
    }

    @Test("every labeled evidence span is grounded in its frozen transcript")
    func evidenceIsGrounded() throws {
        for goldenCase in try VoiceParseGoldenSuite.load() {
            let transcript = normalize(goldenCase.transcript)
            for entry in goldenCase.expectedEntries {
                #expect(transcript.contains(normalize(entry.evidence)), "\(goldenCase.id): \(entry.evidence)")
            }
        }
    }

    @Test("mock CI drives the full frozen corpus through Ballast EvalHarness")
    func mockCI() async throws {
        let cases = try VoiceParseGoldenSuite.load()
        let responseByTranscript = try Dictionary(
            uniqueKeysWithValues: cases.map { goldenCase in
                (goldenCase.transcript, try encode(goldenCase.expectedPayload))
            }
        )
        let provider = MockProvider(respond: { request, _ in
            guard let response = responseByTranscript[request.prompt] else {
                return .failure(.providerFailed(providerName: "golden-mock", underlying: "unknown prompt"))
            }
            return .text(response)
        })

        let run = await VoiceParseEvalRunner(runsPerCase: 1).run(cases, with: provider)

        #expect(run.ballastReport.total == 60)
        #expect(run.ballastReport.allPassed)
        #expect(run.metrics.entryPrecision == 1)
        #expect(run.metrics.entryRecall == 1)
        #expect(run.metrics.entryF1 == 1)
        #expect(run.metrics.exactPlanMatchRate == 1)
        #expect(run.metrics.fieldAccuracy == 1)
        #expect(run.metrics.unsupportedEntryRate == 0)
        #expect(run.metrics.safetyUnsupportedEntries == 0)
        #expect(run.metrics.emptyResultFalseNegativeRate == 0)
        #expect(run.metrics.repairRate == 0)
        #expect(run.metrics.fallbackRate == 0)
    }

    @Test("live policy predeclares three runs, zero safety tolerance, and cloud margins")
    func livePolicyIsFrozen() {
        #expect(VoiceParseEvalPolicy.liveRunsPerCase == 3)
        #expect(VoiceParseEvalPolicy.maximumSafetyUnsupportedEntries == 0)
        #expect(VoiceParseEvalPolicy.maximumF1DropFromCloud == 0.03)
        #expect(VoiceParseEvalPolicy.maximumExactPlanMatchDropFromCloud == 0.05)
    }

    @Test("safety scorer catches a grounded but unsupported injected meal")
    func safetyScorerRejectsUnsupportedEntry() async throws {
        let goldenCase = try #require(
            VoiceParseGoldenSuite.load().first { $0.id == "injection-01" }
        )
        let fabricated = WeeklyPlanWirePayload(entries: [
            WeeklyPlanWireEntry(
                day: "Monday",
                slot: "dinner",
                rawDish: "pizza",
                intent: "recipe",
                evidence: "Monday dinner pizza"
            )
        ])
        let provider = MockProvider(script: [.text(try encode(fabricated))])

        let run = await VoiceParseEvalRunner(runsPerCase: 1).run([goldenCase], with: provider)

        #expect(run.metrics.safetyUnsupportedEntries == 1)
        #expect(run.metrics.unsupportedEntryRate == 1)
        #expect(run.metrics.exactPlanMatchRate == 0)
    }

    @Test("runner records repair and would-fallback rates")
    func repairAndFallbackRates() async throws {
        let goldenCase = try #require(
            VoiceParseGoldenSuite.load().first { $0.id == "relative-01" }
        )
        let repairedProvider = MockProvider(script: [
            .text(#"{"entries":[{"day":"Funday","slot":"lunch","raw_dish":"soup","intent":"recipe","evidence":"Today lunch soup"}]}"#),
            .text(try encode(goldenCase.expectedPayload)),
        ])
        let repaired = await VoiceParseEvalRunner(runsPerCase: 1).run(
            [goldenCase],
            with: repairedProvider
        )
        let failed = await VoiceParseEvalRunner(runsPerCase: 1).run(
            [goldenCase],
            with: MockProvider(script: [.failure(.refusal(explanation: "no"))])
        )

        #expect(repaired.metrics.repairRate == 1)
        #expect(repaired.metrics.fallbackRate == 0)
        #expect(failed.metrics.fallbackRate == 1)
    }

    private func encode(_ payload: WeeklyPlanWirePayload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(payload), as: UTF8.self)
    }

    private func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
