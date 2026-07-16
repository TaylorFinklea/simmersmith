import BallastCore
import BallastMock
import Darwin
import Foundation
import SimmerSmithBallastAdapter

@main
struct SimmerSmithBallastEvalCommand {
    enum CommandError: Error {
        case mockRegression(Int, Int)
        case nonInferiorGateFailed
        case unsupportedMode(String)
    }

    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = try VoiceParseEvalCommandLine.parse(arguments)
        let cases = try VoiceParseGoldenSuite.load()
        let provider: any LanguageProvider
        let runsPerCase: Int
        let baselineURL: URL?
        let role: VoiceParseEvalRole
        let modelIdentifier: String

        switch mode {
        case .mock:
            provider = try mockProvider(for: cases)
            runsPerCase = 1
            baselineURL = nil
            role = .mockWiring
            modelIdentifier = "scripted-golden-responses"
        case .live(let url):
            #if canImport(FoundationModels)
            provider = GuidedFMParseProvider()
            #else
            throw CommandError.unsupportedMode("--live requires FoundationModels")
            #endif
            runsPerCase = VoiceParseEvalPolicy.liveRunsPerCase
            baselineURL = url
            role = .liveFMCandidate
            modelIdentifier = "SystemLanguageModel.default@\(ProcessInfo.processInfo.operatingSystemVersionString)"
        }

        let run = await VoiceParseEvalRunner(
            runsPerCase: runsPerCase,
            role: role,
            modelIdentifier: modelIdentifier,
            corpusDigest: try VoiceParseGoldenSuite.digest()
        ).run(cases, with: provider)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var output = try encoder.encode(run.metrics)
        output.append(0x0A)
        FileHandle.standardOutput.write(output)

        if case .mock = mode, !run.ballastReport.allPassed {
            throw CommandError.mockRegression(run.ballastReport.passed, run.ballastReport.total)
        }

        if let baselineURL {
            let data = try Data(contentsOf: baselineURL)
            let baseline = try JSONDecoder().decode(VoiceParseEvalMetrics.self, from: data)
            guard VoiceParseEvalPolicy.isNonInferior(
                candidate: run.metrics,
                cloudBaseline: baseline
            ) else {
                throw CommandError.nonInferiorGateFailed
            }
        }

        exit(EXIT_SUCCESS)
    }

    private static func mockProvider(
        for cases: [VoiceParseGoldenCase]
    ) throws -> MockProvider {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let responseByTranscript = try Dictionary(
            uniqueKeysWithValues: cases.map { goldenCase in
                let data = try encoder.encode(goldenCase.expectedPayload)
                return (goldenCase.transcript, String(decoding: data, as: UTF8.self))
            }
        )
        return MockProvider(respond: { request, _ in
            guard let response = responseByTranscript[request.prompt] else {
                return .failure(
                    .providerFailed(
                        providerName: "golden-mock",
                        underlying: "unknown synthetic case"
                    )
                )
            }
            return .text(response)
        })
    }
}
