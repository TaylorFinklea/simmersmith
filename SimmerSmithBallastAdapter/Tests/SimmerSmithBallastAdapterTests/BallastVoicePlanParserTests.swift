import BallastCore
import BallastMock
import Foundation
import SimmerSmithKit
import Testing
@testable import SimmerSmithBallastAdapter

@Suite("BallastVoicePlanParser")
struct BallastVoicePlanParserTests {
    private let transcript = "Tuesday dinner tacos"
    private let validJSON = #"{"entries":[{"day":"Tuesday","slot":"dinner","raw_dish":"tacos","intent":"recipe","evidence":"Tuesday dinner tacos"}]}"#

    @Test("happy path returns the validated on-device plan without cloud")
    func happyPath() async throws {
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(provider: MockProvider(script: [.text(validJSON)]), cloud: cloud)

        let result = try await parser.parse(transcript: transcript)

        #expect(result.entries[0].rawDish == "tacos")
        #expect(await cloud.calls == 0)
    }

    @Test("semantic failure repairs and then returns the on-device plan")
    func repairThenOK() async throws {
        let invalid = #"{"entries":[{"day":"Funday","slot":"dinner","raw_dish":"tacos","intent":"recipe","evidence":"Tuesday dinner tacos"}]}"#
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(
            provider: MockProvider(script: [.text(invalid), .text(validJSON)]),
            cloud: cloud
        )

        let result = try await parser.parse(transcript: transcript)

        #expect(result.entries[0].day == "Tuesday")
        #expect(await cloud.calls == 0)
    }

    @Test("ungrounded output repairs before returning")
    func ungroundedRepair() async throws {
        let ungrounded = #"{"entries":[{"day":"Thursday","slot":"dinner","raw_dish":"tacos","intent":"recipe","evidence":"Thursday dinner tacos"}]}"#
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(
            provider: MockProvider(script: [.text(ungrounded), .text(validJSON)]),
            cloud: cloud
        )

        let result = try await parser.parse(transcript: transcript)

        #expect(result.entries[0].day == "Tuesday")
        #expect(await cloud.calls == 0)
    }

    @Test("terminal model error degrades to the injected cloud parser")
    func terminalDegrades() async throws {
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(
            provider: MockProvider(script: [.failure(.refusal(explanation: "no"))]),
            cloud: cloud
        )

        let result = try await parser.parse(transcript: transcript)

        #expect(result == cloudPlan)
        #expect(await cloud.calls == 1)
    }

    @Test("budget breach degrades to the injected cloud parser")
    func budgetDegrades() async throws {
        let snapshot = BudgetSnapshot(
            inputTokens: 0,
            outputTokens: 0,
            steps: 4,
            limits: BudgetLimits(maxSteps: 3)
        )
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(
            provider: MockProvider(script: [.failure(.budgetExceeded(snapshot))]),
            cloud: cloud
        )

        let result = try await parser.parse(transcript: transcript)

        #expect(result == cloudPlan)
        #expect(await cloud.calls == 1)
    }

    @Test("cancellation propagates and never calls cloud")
    func cancellationPropagates() async {
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(provider: CancellingProvider(), cloud: cloud)

        do {
            _ = try await parser.parse(transcript: transcript)
            Issue.record("expected cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(await cloud.calls == 0)
    }

    @Test("provider configuration fault propagates and never calls cloud")
    func configurationFaultPropagates() async {
        let identity = ProviderIdentity(name: "misconfigured", privacy: .onDevice, capabilities: [])
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(
            provider: MockProvider(identity: identity, script: [.text(validJSON)]),
            cloud: cloud
        )

        do {
            _ = try await parser.parse(transcript: transcript)
            Issue.record("expected configuration failure")
        } catch BallastVoicePlanParser.ConfigurationError.providerMissingGuidedGeneration(let name) {
            #expect(name == "misconfigured")
        } catch {
            Issue.record("expected configuration error, got \(error)")
        }
        #expect(await cloud.calls == 0)
    }

    @Test("repair request carries the schema hint")
    func repairHintCarried() async throws {
        let prompts = PromptRecorder()
        let invalid = #"{"entries":[{"day":"Funday","slot":"dinner","raw_dish":"tacos","intent":"recipe","evidence":"Tuesday dinner tacos"}]}"#
        let provider = MockProvider { request, index in
            prompts.record(request.prompt)
            return .text(index == 0 ? invalid : validJSON)
        }
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(provider: provider, cloud: cloud)

        _ = try await parser.parse(transcript: transcript)

        #expect(prompts.values.count == 2)
        #expect(prompts.values[1].contains("Funday"))
        #expect(prompts.values[1].contains("One valid example"))
    }

    @Test("unavailable FM sends the original transcript to cloud")
    func cloudReceivesOriginalTranscript() async throws {
        let cloud = CloudRecorder(result: cloudPlan)
        let parser = makeParser(
            provider: MockProvider(script: [.text(validJSON)]),
            available: false,
            cloud: cloud
        )

        _ = try await parser.parse(transcript: transcript)

        #expect(await cloud.transcripts == [transcript])
    }

    private func makeParser(
        provider: any LanguageProvider,
        available: Bool = true,
        cloud: CloudRecorder
    ) -> BallastVoicePlanParser {
        BallastVoicePlanParser(
            fmProvider: provider,
            isFMAvailable: { available },
            cloudParse: { transcript in try await cloud.parse(transcript) }
        )
    }

    private var cloudPlan: ParsedWeeklyPlan {
        ParsedWeeklyPlan(entries: [
            ParsedMealEntry(day: "Friday", slot: "dinner", rawDish: "cloud soup", intent: "recipe")
        ])
    }
}

private struct CancellingProvider: LanguageProvider {
    let identity = ProviderIdentity(
        name: "cancelling",
        privacy: .onDevice,
        capabilities: [.guidedGeneration]
    )

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        throw CancellationError()
    }
}

private actor CloudRecorder {
    private(set) var transcripts: [String] = []
    let result: ParsedWeeklyPlan

    init(result: ParsedWeeklyPlan) {
        self.result = result
    }

    var calls: Int { transcripts.count }

    func parse(_ transcript: String) throws -> ParsedWeeklyPlan {
        transcripts.append(transcript)
        return result
    }
}

private final class PromptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []

    func record(_ prompt: String) {
        lock.lock()
        prompts.append(prompt)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return prompts
    }
}
