import CryptoKit
import Foundation
import SimmerSmithBallastAdapter
import SimmerSmithKit
import UIKit

// P8 D3 — app-owned production-cloud baseline runner. Drives the frozen 60-case golden corpus
// (case-major, 3 runs each = 180 live calls) through the UNCHANGED `CloudParseService.parse`
// path via `AIService`, classifies each result per the spec's Run-validity policy (fail closed:
// only a decode-level failure after an HTTP-success response scores; everything else aborts the
// sweep with no artifact), and — on a valid 180/180 completion — scores via
// `VoiceParseBaselineEval` and produces the hash-bound metrics + provenance sidecar bytes.
// `CloudParseService.swift` itself is untouched (hash-pinned, spec §Worktree).
//
// Testable via injected seams (spec §D3, Sol F8): identity/lease (`BaselineIdentityLeasing`,
// resolved FRESH on every call so a mid-sweep `AIService` instance swap is visible even when the
// swap preserves the leased (provider, model) identity — the lease's own equality check alone
// cannot see that, spec Sol F5), the parse call, the clock, the session-epoch/idle-timer
// lifecycle signals, and the export sink. Production wiring lives in `BaselineRunnerController.live`.

/// The identity/lease surface the runner needs from an AI-service instance, independent of
/// `AIService`'s CloudKit/private-plane dependencies so a fake can stand in for the app-hosted
/// test suite — mirrors `AIServiceIdentityTests`' note that `resolveConfiguration()` needs a live
/// iCloud-backed `HouseholdSession`, not constructible there. `AIService` conforms below:
/// additive, no behavior change to any existing method.
@MainActor
protocol BaselineIdentityLeasing: AnyObject {
    func identitySnapshot() throws -> AIServiceIdentity
    func beginIdentityLease(_ identity: AIServiceIdentity) throws
    func endIdentityLease()
}

extension AIService: BaselineIdentityLeasing {}

@MainActor
@Observable
final class BaselineRunnerController {

    // MARK: - Injected seams (spec §D3, Sol F8)

    typealias ServiceResolver = () -> BaselineIdentityLeasing?
    typealias ParseCall = (_ transcript: String) async throws -> ParsedWeeklyPlan
    typealias ClockNow = () -> ContinuousClock.Instant
    typealias EpochProvider = () -> Int
    typealias ExportSink = (_ metrics: Data, _ provenance: Data) -> Void

    /// Idle-timer hold/restore seam — production wraps `UIApplication.shared.isIdleTimerDisabled`;
    /// tests substitute an in-memory flag so "restored on every exit path" is directly assertable.
    struct IdleTimerControl {
        var isDisabled: () -> Bool
        var setDisabled: (Bool) -> Void

        @MainActor static let live = IdleTimerControl(
            isDisabled: { UIApplication.shared.isIdleTimerDisabled },
            setDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 }
        )
    }

    // MARK: - State

    enum State: Equatable {
        case idle
        case consentUnavailable(String)
        case awaitingConsent(ConsentInfo)
        case running(RunProgress)
        case aborted(String)
        case completed(CompletedRun)
    }

    struct ConsentInfo: Equatable {
        let identity: AIServiceIdentity
        let caseCount: Int
        let runsPerCase: Int
        var totalCalls: Int { caseCount * runsPerCase }
    }

    struct RunProgress: Equatable {
        var completedCalls: Int
        var totalCalls: Int
    }

    struct CompletedRun: Equatable {
        let metrics: VoiceParseEvalMetrics
        let provenance: VoiceBaselineProvenance
        let metricsData: Data
        let provenanceData: Data
    }

    private struct AbortSweep: Error {
        let reason: String
    }

    /// App-side runner code version, recorded in the provenance sidecar alongside
    /// `VoiceParseBaselineEval.scoringVersion` — bump on any change to sweep/classification
    /// mechanics so old baseline files self-identify as stale (spec §D3 staleness rule).
    static let runnerVersion = "p8-baseline-runner-1"

    private(set) var state: State = .idle

    private let resolveService: ServiceResolver
    private let parseCall: ParseCall
    private let now: ClockNow
    private let currentEpoch: EpochProvider
    private let idleTimer: IdleTimerControl
    private let exportSink: ExportSink
    private let loadCorpus: () throws -> [VoiceParseGoldenCase]
    private let corpusDigest: () throws -> String

    private var pendingCases: [VoiceParseGoldenCase]?
    private var sweepTask: Task<Void, Never>?

    init(
        resolveService: @escaping ServiceResolver,
        parseCall: @escaping ParseCall,
        now: @escaping ClockNow = { ContinuousClock().now },
        currentEpoch: @escaping EpochProvider,
        idleTimer: IdleTimerControl,
        exportSink: @escaping ExportSink,
        loadCorpus: @escaping () throws -> [VoiceParseGoldenCase] = { try VoiceParseGoldenSuite.load() },
        corpusDigest: @escaping () throws -> String = { try VoiceParseGoldenSuite.digest() }
    ) {
        self.resolveService = resolveService
        self.parseCall = parseCall
        self.now = now
        self.currentEpoch = currentEpoch
        self.idleTimer = idleTimer
        self.exportSink = exportSink
        self.loadCorpus = loadCorpus
        self.corpusDigest = corpusDigest
    }

    // MARK: - Consent (spec §D3 step 1 — resolve identity + show the budget BEFORE any call)

    /// Load the frozen corpus, verify its digest, and resolve the current identity — never fires
    /// a parse call. Degrades to `.consentUnavailable` (not a crash) when the corpus, digest, or
    /// AI configuration isn't ready, so the debug screen always renders something sane.
    func prepare() {
        if case .running = state { return }
        do {
            let digest = try corpusDigest()
            guard digest == VoiceParseEvalPolicy.corpusDigest else {
                state = .consentUnavailable("Corpus digest mismatch — cannot run a baseline sweep.")
                return
            }
            let cases = try loadCorpus()
            guard cases.count == VoiceParseEvalPolicy.corpusCaseCount else {
                state = .consentUnavailable(
                    "Corpus case count mismatch (\(cases.count), expected \(VoiceParseEvalPolicy.corpusCaseCount))."
                )
                return
            }
            guard let service = resolveService() else {
                state = .consentUnavailable("No AI provider is configured. Set one up in Settings → AI.")
                return
            }
            let identity = try service.identitySnapshot()
            pendingCases = cases
            state = .awaitingConsent(ConsentInfo(
                identity: identity, caseCount: cases.count, runsPerCase: VoiceParseEvalPolicy.liveRunsPerCase
            ))
        } catch {
            state = .consentUnavailable("\(error)")
        }
    }

    // MARK: - Sweep lifecycle

    /// Explicit consent tap: acquires the identity lease on the CURRENTLY resolved service and
    /// starts the sweep. No call fires before this.
    func startSweep() {
        guard case .awaitingConsent(let info) = state, let cases = pendingCases else { return }
        guard let service = resolveService() else {
            state = .consentUnavailable("The AI service became unavailable.")
            return
        }
        do {
            try service.beginIdentityLease(info.identity)
        } catch {
            state = .aborted("Could not acquire the identity lease: \(error)")
            return
        }
        let epoch = currentEpoch()
        state = .running(RunProgress(completedCalls: 0, totalCalls: info.totalCalls))
        sweepTask = Task { [weak self] in
            await self?.runSweep(
                leasedService: service, identity: info.identity, cases: cases,
                capturedEpoch: epoch, totalCalls: info.totalCalls
            )
        }
    }

    /// Cancel the in-flight sweep (Cancel tap, view disappearance, backgrounding) and wait for it
    /// to fully unwind — by the time this returns, `state` reflects `.aborted` and the defer
    /// cleanup (lease release, idle-timer restore) has already run. No-op if nothing is running.
    func cancel() async {
        guard let task = sweepTask else { return }
        task.cancel()
        await task.value
    }

    /// Return to idle so the debug screen can retry `prepare()` after an abort/completion.
    func reset() {
        if case .running = state { return }
        pendingCases = nil
        state = .idle
    }

    /// User-triggered export of a completed sweep's two files. No-op unless `state == .completed`.
    func exportNow() {
        guard case .completed(let run) = state else { return }
        exportSink(run.metricsData, run.provenanceData)
    }

    // MARK: - Sweep body

    private func runSweep(
        leasedService: BaselineIdentityLeasing,
        identity: AIServiceIdentity,
        cases: [VoiceParseGoldenCase],
        capturedEpoch: Int,
        totalCalls: Int
    ) async {
        let leasedID = ObjectIdentifier(leasedService)
        let priorIdle = idleTimer.isDisabled()
        idleTimer.setDisabled(true)
        let startedAt = Date()
        defer {
            idleTimer.setDisabled(priorIdle)
            leasedService.endIdentityLease()
        }

        var samples: [VoiceParseBaselineSample] = []
        var completed = 0

        do {
            for goldenCase in cases {
                for runIndex in 1...VoiceParseEvalPolicy.liveRunsPerCase {
                    try Task.checkCancellation()

                    // Fresh-resolve on every call (never cached) so a same-identity instance swap
                    // is visible via ObjectIdentifier — the lease's (provider, model) equality
                    // check alone cannot catch a brand-new instance with no lease engaged at all.
                    guard let current = resolveService(), ObjectIdentifier(current) == leasedID else {
                        throw AbortSweep(reason: "The AI service instance changed mid-sweep.")
                    }
                    guard currentEpoch() == capturedEpoch else {
                        throw AbortSweep(reason: "The household session changed mid-sweep.")
                    }

                    let start = now()
                    do {
                        let plan = try await parseCall(goldenCase.transcript)
                        if Task.isCancelled { throw CancellationError() }
                        let elapsed = Self.milliseconds(now() - start)
                        let rows = plan.entries.map {
                            VoiceParseBaselineSample.Row(day: $0.day, slot: $0.slot, rawDish: $0.rawDish, intent: $0.intent)
                        }
                        samples.append(VoiceParseBaselineSample(
                            caseID: goldenCase.id, runIndex: runIndex,
                            latencyMilliseconds: elapsed, outcome: .success(rows: rows)
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A cancellation racing the call can surface as some OTHER thrown type
                        // (e.g. URLError.cancelled) — Task.isCancelled is the ground truth.
                        if Task.isCancelled { throw CancellationError() }
                        guard let decodeError = error as? DecodingError else {
                            // Everything but a decode failure is abort-class (spec §Run-validity
                            // policy, fail closed): AIServiceError (incl. identityLeaseViolation),
                            // AIError HTTP status errors (4xx incl. terminal 400, 429, 5xx),
                            // URLError/timeouts, and any unclassified error.
                            throw AbortSweep(reason: "Aborted on a non-decode failure: \(error)")
                        }
                        let elapsed = Self.milliseconds(now() - start)
                        samples.append(VoiceParseBaselineSample(
                            caseID: goldenCase.id, runIndex: runIndex,
                            latencyMilliseconds: elapsed,
                            outcome: .failure(category: Self.classify(decodeError))
                        ))
                    }

                    completed += 1
                    state = .running(RunProgress(completedCalls: completed, totalCalls: totalCalls))
                }
            }

            let metrics = try VoiceParseBaselineEval.score(
                samples, providerName: identity.providerName, modelIdentifier: identity.modelIdentifier
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metricsData = try encoder.encode(metrics)
            let metricsSHA256 = Self.sha256Hex(metricsData)

            var failureCounts: [String: Int] = [:]
            for category in VoiceParseBaselineFailureCategory.allCases { failureCounts[category.rawValue] = 0 }
            for sample in samples {
                if case .failure(let category) = sample.outcome {
                    failureCounts[category.rawValue, default: 0] += 1
                }
            }

            let info = Bundle.main.infoDictionary
            let appBuild = info?["CFBundleVersion"] as? String ?? "?"
            let provenance = VoiceBaselineProvenance(
                runID: UUID().uuidString,
                metricsSHA256: metricsSHA256,
                corpusDigest: VoiceParseEvalPolicy.corpusDigest,
                startedAt: Self.iso8601(startedAt),
                endedAt: Self.iso8601(Date()),
                appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
                appBuild: appBuild,
                // No existing build-info/commit-embedding convention in this repo (checked
                // scripts/release-ios.sh + the app target) — falls back to the app-build id per
                // spec §D3 step 5, recorded as a deviation in the phase report.
                repoCommit: "app-build-\(appBuild)",
                scorerVersion: VoiceParseBaselineEval.scoringVersion,
                runnerVersion: Self.runnerVersion,
                deviceModel: UIDevice.current.model,
                osVersion: UIDevice.current.systemVersion,
                providerName: identity.providerName,
                modelIdentifier: identity.modelIdentifier,
                scoredFailureCounts: failureCounts
            )
            let provenanceData = try encoder.encode(provenance)

            state = .completed(CompletedRun(
                metrics: metrics, provenance: provenance, metricsData: metricsData, provenanceData: provenanceData
            ))
        } catch is CancellationError {
            state = .aborted("Cancelled.")
        } catch let abort as AbortSweep {
            state = .aborted(abort.reason)
        } catch {
            state = .aborted("\(error)")
        }
    }

    // MARK: - Classification

    /// Distinguishes the two scored-class categories from the shape of the SAME thrown
    /// `DecodingError` (spec: "use `.emptyOrNonJSONBody` only if genuinely distinguishable,
    /// otherwise default to `.schemaDecodeFailure`"): `BYOKeyProvider.extractJSONObject` never
    /// throws, so `CloudParseService.parse`'s only throw point is `JSONDecoder.decode`, which
    /// surfaces malformed/non-JSON input (empty or non-JSON bodies) as `.dataCorrupted` and a
    /// syntactically-valid-but-wrong-shape JSON object as `.keyNotFound`/`.typeMismatch`/
    /// `.valueNotFound` — Foundation's own case split IS the empty-or-non-JSON vs. wrong-schema
    /// distinction the two categories describe.
    private static func classify(_ error: DecodingError) -> VoiceParseBaselineFailureCategory {
        switch error {
        case .dataCorrupted:
            return .emptyOrNonJSONBody
        case .keyNotFound, .typeMismatch, .valueNotFound:
            return .schemaDecodeFailure
        @unknown default:
            return .schemaDecodeFailure
        }
    }

    // MARK: - Small helpers

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}

// MARK: - Production wiring

extension BaselineRunnerController {
    /// Production seams: parse routes through the UNCHANGED `CloudParseService.parse(
    /// transcript:using:)` via `appState.aiService`, mirroring `VoicePlanningCoordinator`'s
    /// session-ready guard (`VoicePlanningCoordinator.swift:63,75`).
    static func live(appState: AppState, exportSink: @escaping ExportSink) -> BaselineRunnerController {
        BaselineRunnerController(
            resolveService: { [weak appState] in appState?.aiService },
            parseCall: { [weak appState] transcript in
                guard let aiSvc = appState?.aiService else { throw VoicePlanningError.noAI }
                return try await CloudParseService.parse(transcript: transcript, using: aiSvc)
            },
            currentEpoch: { [weak appState] in appState?.sessionBootEpoch ?? -1 },
            idleTimer: .live,
            exportSink: exportSink
        )
    }
}
