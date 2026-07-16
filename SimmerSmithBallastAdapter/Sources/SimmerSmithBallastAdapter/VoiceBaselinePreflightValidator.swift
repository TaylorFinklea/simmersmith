import CryptoKit
import Foundation

/// Mechanical preflight for a production-cloud baseline artifact pair (spec §D4), run before any
/// `SimmerSmithBallastEval --live --baseline` invocation. Lives in the library target (not the
/// thin `VoiceBaselinePreflight` executable) so it is directly testable. Never trusts the sidecar
/// or metrics file's self-reported claims without re-deriving them: the metrics hash and corpus
/// digest are recomputed here, not merely echoed back.
public enum VoiceBaselinePreflightValidator {
    /// The human-facing identity + code-version summary printed on success, for cross-checking
    /// against the device's current Settings and the repo's current HEAD (spec §D4).
    public struct Result: Sendable, Equatable {
        public let providerName: String
        public let modelIdentifier: String
        public let startedAt: String
        public let endedAt: String
        public let appVersion: String
        public let appBuild: String
        public let repoCommit: String
        public let scorerVersion: String
        public let runnerVersion: String
    }

    /// One case per mechanical check (spec §D4: "each with a distinct failure message").
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case metricsDecodeFailed(String)
        case wrongRole(actual: VoiceParseEvalRole)
        case corpusIDMismatch(expected: String, actual: String)
        case corpusDigestMismatch(expected: String, actual: String)
        case caseCountMismatch(expected: Int, actual: Int)
        case runsPerCaseMismatch(expected: Int, actual: Int)
        case caseRunsMismatch(expected: Int, actual: Int)
        case sidecarDecodeFailed(String)
        case metricsHashMismatch(expected: String, actual: String)
        case sidecarCorpusDigestMismatch(expected: String, actual: String)
        case scorerVersionMismatch(expected: String, actual: String)

        public var description: String {
            switch self {
            case .metricsDecodeFailed(let reason):
                return "metrics file does not decode as VoiceParseEvalMetrics: \(reason)"
            case .wrongRole(let actual):
                return "metrics role is \(actual.rawValue), expected \(VoiceParseEvalRole.productionCloudBaseline.rawValue)"
            case .corpusIDMismatch(let expected, let actual):
                return "metrics corpusID \(actual) does not match VoiceParseEvalPolicy.corpusID \(expected)"
            case .corpusDigestMismatch(let expected, let actual):
                return "metrics corpusDigest \(actual) does not match VoiceParseEvalPolicy.corpusDigest \(expected)"
            case .caseCountMismatch(let expected, let actual):
                return "metrics caseCount \(actual) does not match VoiceParseEvalPolicy.corpusCaseCount \(expected)"
            case .runsPerCaseMismatch(let expected, let actual):
                return "metrics runsPerCase \(actual) does not match VoiceParseEvalPolicy.liveRunsPerCase \(expected)"
            case .caseRunsMismatch(let expected, let actual):
                return "metrics caseRuns \(actual) does not equal caseCount × runsPerCase (\(expected))"
            case .sidecarDecodeFailed(let reason):
                return "sidecar file does not decode as VoiceBaselineProvenance: \(reason)"
            case .metricsHashMismatch(let expected, let actual):
                return "sidecar metricsSHA256 \(expected) does not match the exported metrics file's SHA-256 \(actual)"
            case .sidecarCorpusDigestMismatch(let expected, let actual):
                return "sidecar corpusDigest \(actual) does not match metrics corpusDigest \(expected)"
            case .scorerVersionMismatch(let expected, let actual):
                return "sidecar scorerVersion \(actual) does not match VoiceParseBaselineEval.scoringVersion \(expected)"
            }
        }
    }

    /// Validates the exact bytes of a `voice-baseline-metrics.json` /
    /// `voice-baseline-provenance.json` pair against `VoiceParseEvalPolicy` and
    /// `VoiceParseBaselineEval.scoringVersion`. Throws on the first failed check; callers that
    /// want the human cross-check summary use the returned `Result` on success.
    public static func validate(metricsData: Data, sidecarData: Data) throws -> Result {
        let metrics: VoiceParseEvalMetrics
        do {
            metrics = try JSONDecoder().decode(VoiceParseEvalMetrics.self, from: metricsData)
        } catch {
            throw ValidationError.metricsDecodeFailed(String(describing: error))
        }

        guard metrics.role == .productionCloudBaseline else {
            throw ValidationError.wrongRole(actual: metrics.role)
        }
        guard metrics.corpusID == VoiceParseEvalPolicy.corpusID else {
            throw ValidationError.corpusIDMismatch(expected: VoiceParseEvalPolicy.corpusID, actual: metrics.corpusID)
        }
        guard metrics.corpusDigest == VoiceParseEvalPolicy.corpusDigest else {
            throw ValidationError.corpusDigestMismatch(
                expected: VoiceParseEvalPolicy.corpusDigest,
                actual: metrics.corpusDigest
            )
        }
        guard metrics.caseCount == VoiceParseEvalPolicy.corpusCaseCount else {
            throw ValidationError.caseCountMismatch(
                expected: VoiceParseEvalPolicy.corpusCaseCount,
                actual: metrics.caseCount
            )
        }
        guard metrics.runsPerCase == VoiceParseEvalPolicy.liveRunsPerCase else {
            throw ValidationError.runsPerCaseMismatch(
                expected: VoiceParseEvalPolicy.liveRunsPerCase,
                actual: metrics.runsPerCase
            )
        }
        let expectedCaseRuns = metrics.caseCount * metrics.runsPerCase
        guard metrics.caseRuns == expectedCaseRuns else {
            throw ValidationError.caseRunsMismatch(expected: expectedCaseRuns, actual: metrics.caseRuns)
        }

        let sidecar: VoiceBaselineProvenance
        do {
            sidecar = try JSONDecoder().decode(VoiceBaselineProvenance.self, from: sidecarData)
        } catch {
            throw ValidationError.sidecarDecodeFailed(String(describing: error))
        }

        let actualMetricsHash = SHA256.hash(data: metricsData).map { String(format: "%02x", $0) }.joined()
        guard sidecar.metricsSHA256 == actualMetricsHash else {
            throw ValidationError.metricsHashMismatch(expected: sidecar.metricsSHA256, actual: actualMetricsHash)
        }
        guard sidecar.corpusDigest == metrics.corpusDigest else {
            throw ValidationError.sidecarCorpusDigestMismatch(expected: metrics.corpusDigest, actual: sidecar.corpusDigest)
        }
        guard sidecar.scorerVersion == VoiceParseBaselineEval.scoringVersion else {
            throw ValidationError.scorerVersionMismatch(
                expected: VoiceParseBaselineEval.scoringVersion,
                actual: sidecar.scorerVersion
            )
        }

        return Result(
            providerName: sidecar.providerName,
            modelIdentifier: sidecar.modelIdentifier,
            startedAt: sidecar.startedAt,
            endedAt: sidecar.endedAt,
            appVersion: sidecar.appVersion,
            appBuild: sidecar.appBuild,
            repoCommit: sidecar.repoCommit,
            scorerVersion: sidecar.scorerVersion,
            runnerVersion: sidecar.runnerVersion
        )
    }
}
