import Foundation

/// Provenance sidecar for a production-cloud baseline sweep (spec §D3 step 4). Lives in the
/// adapter so the app-side runner (writer) and the preflight validator (reader) share one
/// schema. `VoiceParseEvalMetrics` itself is deliberately unchanged — this file is the home for
/// everything the gate artifact cannot carry (Sol F7). Timestamps are pre-rendered ISO8601
/// strings so encoding never depends on a date strategy. Never carries keys, key presence,
/// transcripts, or response bodies.
public struct VoiceBaselineProvenance: Codable, Sendable, Equatable {
    public let runID: String
    /// SHA-256 (lowercase hex) of the exact exported metrics-file bytes — binds this sidecar to
    /// one specific `voice-baseline-metrics.json`.
    public let metricsSHA256: String
    public let corpusDigest: String
    public let startedAt: String
    public let endedAt: String
    public let appVersion: String
    public let appBuild: String
    public let repoCommit: String
    /// `VoiceParseBaselineEval.scoringVersion` at run time.
    public let scorerVersion: String
    /// App-side runner code version constant.
    public let runnerVersion: String
    public let deviceModel: String
    public let osVersion: String
    public let providerName: String
    public let modelIdentifier: String
    /// Scored-class failure counts keyed by `VoiceParseBaselineFailureCategory` raw value.
    /// Abort-class failures never appear here — aborted sweeps emit no artifact at all.
    public let scoredFailureCounts: [String: Int]

    public init(
        runID: String,
        metricsSHA256: String,
        corpusDigest: String,
        startedAt: String,
        endedAt: String,
        appVersion: String,
        appBuild: String,
        repoCommit: String,
        scorerVersion: String,
        runnerVersion: String,
        deviceModel: String,
        osVersion: String,
        providerName: String,
        modelIdentifier: String,
        scoredFailureCounts: [String: Int]
    ) {
        self.runID = runID
        self.metricsSHA256 = metricsSHA256
        self.corpusDigest = corpusDigest
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.repoCommit = repoCommit
        self.scorerVersion = scorerVersion
        self.runnerVersion = runnerVersion
        self.deviceModel = deviceModel
        self.osVersion = osVersion
        self.providerName = providerName
        self.modelIdentifier = modelIdentifier
        self.scoredFailureCounts = scoredFailureCounts
    }
}
