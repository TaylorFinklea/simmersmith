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
        let live = arguments.contains("--live")
        let cases = try VoiceParseGoldenSuite.load()
        let provider: any LanguageProvider

        if live {
            #if canImport(FoundationModels)
            provider = GuidedFMParseProvider()
            #else
            throw CommandError.unsupportedMode("--live requires FoundationModels")
            #endif
        } else {
            provider = try mockProvider(for: cases)
        }

        let runsPerCase = live ? VoiceParseEvalPolicy.liveRunsPerCase : 1
        let run = await VoiceParseEvalRunner(runsPerCase: runsPerCase).run(cases, with: provider)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var output = try encoder.encode(run.metrics)
        output.append(0x0A)
        FileHandle.standardOutput.write(output)

        if !live, !run.ballastReport.allPassed {
            throw CommandError.mockRegression(run.ballastReport.passed, run.ballastReport.total)
        }

        if let baselinePath = value(after: "--baseline", in: arguments) {
            let data = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
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

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
