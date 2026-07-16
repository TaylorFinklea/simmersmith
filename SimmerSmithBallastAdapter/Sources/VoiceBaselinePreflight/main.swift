import Darwin
import Foundation
import SimmerSmithBallastAdapter

/// Thin CLI wrapper (spec §D4): parses two file paths and hands their bytes to
/// `VoiceBaselinePreflightValidator`. All validation logic lives in the library target so it's
/// testable; this executable is just argument parsing + printing.
@main
struct VoiceBaselinePreflightCommand {
    enum CommandError: Error, CustomStringConvertible {
        case invalidArguments([String])

        var description: String {
            switch self {
            case .invalidArguments:
                return "usage: VoiceBaselinePreflight <metrics.json> <provenance.json>"
            }
        }
    }

    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else {
                throw CommandError.invalidArguments(arguments)
            }
            let metricsURL = URL(fileURLWithPath: arguments[0])
            let sidecarURL = URL(fileURLWithPath: arguments[1])
            let metricsData = try Data(contentsOf: metricsURL)
            let sidecarData = try Data(contentsOf: sidecarURL)

            let result = try VoiceBaselinePreflightValidator.validate(
                metricsData: metricsData,
                sidecarData: sidecarData
            )

            print("preflight OK — cross-check the following against current Settings and HEAD:")
            print("providerName: \(result.providerName)")
            print("modelIdentifier: \(result.modelIdentifier)")
            print("startedAt: \(result.startedAt)")
            print("endedAt: \(result.endedAt)")
            print("appVersion: \(result.appVersion)")
            print("appBuild: \(result.appBuild)")
            print("repoCommit: \(result.repoCommit)")
            print("scorerVersion: \(result.scorerVersion)")
            print("runnerVersion: \(result.runnerVersion)")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("preflight failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}
