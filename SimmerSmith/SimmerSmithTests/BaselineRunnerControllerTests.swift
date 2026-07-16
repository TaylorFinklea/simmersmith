import AIProviderKit
import CryptoKit
import Foundation
import SimmerSmithBallastAdapter
import SimmerSmithKit
import Testing

@testable import SimmerSmith

// P8 D3 — the app-owned baseline-runner controller. These tests drive the FULL 60×3=180
// case-major run-minor sweep against the real frozen adapter corpus (`VoiceParseGoldenSuite`) —
// `VoiceParseBaselineEval.score`'s internal coverage validation only accepts real case IDs, so a
// smaller fake corpus can't reach `.completed`. The injected `parseCall` never touches the
// network: every call is answered synchronously/in-memory, so a full 180-iteration sweep still
// runs near-instantly.
@MainActor
struct BaselineRunnerControllerTests {

    // MARK: - Fakes

    /// Fake `BaselineIdentityLeasing` — a distinct reference type per instance, so two fakes with
    /// the SAME `identity` value still have different `ObjectIdentifier`s (needed for the
    /// instance-replacement test, which the lease's own value-equality check can't catch).
    final class FakeIdentityLeasing: BaselineIdentityLeasing {
        var identity: AIServiceIdentity
        var identitySnapshotError: Error?
        private(set) var leaseHeld: AIServiceIdentity?
        private(set) var leaseEndedCount = 0

        init(identity: AIServiceIdentity) { self.identity = identity }

        func identitySnapshot() throws -> AIServiceIdentity {
            if let identitySnapshotError { throw identitySnapshotError }
            return identity
        }
        func beginIdentityLease(_ identity: AIServiceIdentity) throws {
            leaseHeld = identity
        }
        func endIdentityLease() {
            leaseHeld = nil
            leaseEndedCount += 1
        }
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    private static let identity = AIServiceIdentity(providerName: "openai", modelIdentifier: "gpt-4o")

    /// Builds a controller with sensible test defaults; every seam is overridable. Defaults to
    /// the REAL adapter corpus (`loadCorpus`/`corpusDigest` unset) so tests that need `.completed`
    /// don't have to wire it themselves.
    private func makeController(
        resolveService: @escaping BaselineRunnerController.ServiceResolver,
        parseCall: @escaping BaselineRunnerController.ParseCall,
        currentEpoch: @escaping BaselineRunnerController.EpochProvider = { 0 },
        idleTimer: BaselineRunnerController.IdleTimerControl,
        exportSink: @escaping BaselineRunnerController.ExportSink = { _, _ in }
    ) -> BaselineRunnerController {
        BaselineRunnerController(
            resolveService: resolveService,
            parseCall: parseCall,
            currentEpoch: currentEpoch,
            idleTimer: idleTimer,
            exportSink: exportSink
        )
    }

    /// Waits for a started sweep to settle (`.completed` or `.aborted`), cooperatively yielding
    /// so the sweep task actually gets scheduler turns. Never cancels — used by tests that need
    /// the sweep to reach its own natural conclusion.
    private func waitForSettlement(_ controller: BaselineRunnerController) async {
        while true {
            if case .running = controller.state {
                await Task.yield()
            } else {
                break
            }
        }
    }

    // MARK: - No call before consent

    @Test
    func prepareNeverCallsParseBeforeConsent() {
        var callCount = 0
        let service = FakeIdentityLeasing(identity: Self.identity)
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in callCount += 1; return ParsedWeeklyPlan(entries: []) },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        #expect(callCount == 0)
        guard case .awaitingConsent = controller.state else {
            Issue.record("expected .awaitingConsent, got \(controller.state)")
            return
        }
    }

    @Test
    func prepareDegradesGracefullyWithNoService() {
        var callCount = 0
        let controller = makeController(
            resolveService: { nil },
            parseCall: { _ in callCount += 1; return ParsedWeeklyPlan(entries: []) },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        #expect(callCount == 0)
        guard case .consentUnavailable = controller.state else {
            Issue.record("expected .consentUnavailable, got \(controller.state)")
            return
        }
    }

    // MARK: - Exact case-major run-minor 60×3 accounting

    @Test
    func caseMajorRunMinorAccountingIsExact() async throws {
        let service = FakeIdentityLeasing(identity: Self.identity)
        var recorded: [String] = []
        let controller = makeController(
            resolveService: { service },
            parseCall: { transcript in
                recorded.append(transcript)
                return ParsedWeeklyPlan(entries: [])
            },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        let cases = try VoiceParseGoldenSuite.load()
        #expect(cases.count == VoiceParseEvalPolicy.corpusCaseCount)
        let expected = cases.flatMap { c in Array(repeating: c.transcript, count: VoiceParseEvalPolicy.liveRunsPerCase) }
        #expect(recorded == expected)
        #expect(recorded.count == VoiceParseEvalPolicy.corpusCaseCount * VoiceParseEvalPolicy.liveRunsPerCase)

        guard case .completed(let run) = controller.state else {
            Issue.record("expected .completed, got \(controller.state)")
            return
        }
        #expect(run.metrics.caseRuns == 180)
    }

    // MARK: - Classification: DecodingError → scored, sweep still completes with an artifact

    @Test
    func dataCorruptedDecodeErrorClassifiesAsEmptyOrNonJSONBody() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        let decodeError = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "not valid JSON")
        )
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in throw decodeError },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        guard case .completed(let run) = controller.state else {
            Issue.record("expected .completed (scored failures still complete the sweep), got \(controller.state)")
            return
        }
        #expect(run.metrics.fallbackRate == 1.0)
        #expect(run.provenance.scoredFailureCounts["emptyOrNonJSONBody"] == 180)
        #expect(run.provenance.scoredFailureCounts["schemaDecodeFailure"] == 0)
    }

    @Test
    func keyNotFoundDecodeErrorClassifiesAsSchemaDecodeFailure() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        struct DummyKey: CodingKey { var stringValue: String; init?(stringValue: String) { self.stringValue = stringValue }; var intValue: Int?; init?(intValue: Int) { return nil } }
        let decodeError = DecodingError.keyNotFound(
            DummyKey(stringValue: "entries")!,
            DecodingError.Context(codingPath: [], debugDescription: "missing entries")
        )
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in throw decodeError },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        guard case .completed(let run) = controller.state else {
            Issue.record("expected .completed, got \(controller.state)")
            return
        }
        #expect(run.provenance.scoredFailureCounts["schemaDecodeFailure"] == 180)
        #expect(run.provenance.scoredFailureCounts["emptyOrNonJSONBody"] == 0)
    }

    // MARK: - Abort class: terminal 400, identity-lease violation, unknown errors → no artifact

    @Test
    func terminalHTTP400AbortsWithNoArtifact() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        var callCount = 0
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in
                callCount += 1
                throw AIError.httpError(provider: "openai", statusCode: 400, body: "")
            },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        #expect(callCount == 1)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    @Test
    func identityLeaseViolationAbortsWithNoArtifact() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        let other = AIServiceIdentity(providerName: "anthropic", modelIdentifier: "claude-opus-4-5")
        var callCount = 0
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in
                callCount += 1
                throw AIServiceError.identityLeaseViolation(expected: Self.identity, resolved: other)
            },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        #expect(callCount == 1)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    // MARK: - aiService instance replacement mid-sweep (same identity, new object) → abort

    @Test
    func aiServiceInstanceReplacementMidSweepAborts() async {
        let serviceA = FakeIdentityLeasing(identity: Self.identity)
        let serviceB = FakeIdentityLeasing(identity: Self.identity) // same identity VALUE, different object
        let box = Box<BaselineIdentityLeasing>(serviceA)
        var callCount = 0
        let controller = makeController(
            resolveService: { box.value },
            parseCall: { _ in
                callCount += 1
                if callCount == 2 { box.value = serviceB }
                return ParsedWeeklyPlan(entries: [])
            },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        #expect(callCount == 2)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    // MARK: - Session-epoch change mid-sweep → abort, no artifact

    @Test
    func sessionEpochChangeMidSweepAborts() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        let epochBox = Box<Int>(0)
        var callCount = 0
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in
                callCount += 1
                if callCount == 2 { epochBox.value = 1 }
                return ParsedWeeklyPlan(entries: [])
            },
            currentEpoch: { epochBox.value },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        #expect(callCount == 2)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    // MARK: - Cancellation → no artifact

    @Test
    func cancelBeforeAnyCallAbortsWithZeroCalls() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        var callCount = 0
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in callCount += 1; return ParsedWeeklyPlan(entries: []) },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await controller.cancel()

        #expect(callCount == 0)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    @Test
    func cancelMidSweepDiscardsPartialProgressWithNoArtifact() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        var callCount = 0
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in
                callCount += 1
                await Task.yield() // give the concurrently-spawned cancel task a scheduling turn
                return ParsedWeeklyPlan(entries: [])
            },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()

        let canceller = Task {
            for _ in 0..<3 { await Task.yield() }
            await controller.cancel()
        }
        await canceller.value

        #expect(callCount > 0)
        #expect(callCount < VoiceParseEvalPolicy.corpusCaseCount * VoiceParseEvalPolicy.liveRunsPerCase)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    // MARK: - Idle-timer restored on every exit path

    @Test
    func idleTimerIsRestoredToItsPriorValueAfterCompletion() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        let idleBox = Box<Bool>(false)
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in ParsedWeeklyPlan(entries: []) },
            idleTimer: BaselineRunnerController.IdleTimerControl(
                isDisabled: { idleBox.value }, setDisabled: { idleBox.value = $0 }
            )
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        #expect(idleBox.value == false)
        guard case .completed = controller.state else {
            Issue.record("expected .completed, got \(controller.state)")
            return
        }
    }

    @Test
    func idleTimerIsRestoredToPriorTrueValueAfterAbort() async {
        let service = FakeIdentityLeasing(identity: Self.identity)
        let idleBox = Box<Bool>(true) // some OTHER feature already holds the idle timer disabled
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in throw AIError.httpError(provider: "openai", statusCode: 500, body: "") },
            idleTimer: BaselineRunnerController.IdleTimerControl(
                isDisabled: { idleBox.value }, setDisabled: { idleBox.value = $0 }
            )
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        #expect(idleBox.value == true)
        guard case .aborted = controller.state else {
            Issue.record("expected .aborted, got \(controller.state)")
            return
        }
    }

    // MARK: - Exported metrics decode + sidecar hash binds the exported bytes

    @Test
    func exportedMetricsDecodeAndSidecarHashBindsTheBytes() async throws {
        let service = FakeIdentityLeasing(identity: Self.identity)
        let controller = makeController(
            resolveService: { service },
            parseCall: { _ in ParsedWeeklyPlan(entries: []) },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in })
        )
        controller.prepare()
        controller.startSweep()
        await waitForSettlement(controller)

        guard case .completed(let run) = controller.state else {
            Issue.record("expected .completed, got \(controller.state)")
            return
        }

        let decoded = try JSONDecoder().decode(VoiceParseEvalMetrics.self, from: run.metricsData)
        #expect(decoded == run.metrics)

        let expectedHash = SHA256.hash(data: run.metricsData).map { String(format: "%02x", $0) }.joined()
        #expect(run.provenance.metricsSHA256 == expectedHash)

        var sinkMetrics: Data?
        var sinkProvenance: Data?
        let exportingController = makeController(
            resolveService: { service },
            parseCall: { _ in ParsedWeeklyPlan(entries: []) },
            idleTimer: BaselineRunnerController.IdleTimerControl(isDisabled: { false }, setDisabled: { _ in }),
            exportSink: { metrics, provenance in sinkMetrics = metrics; sinkProvenance = provenance }
        )
        exportingController.prepare()
        exportingController.startSweep()
        await waitForSettlement(exportingController)
        exportingController.exportNow()

        #expect(sinkMetrics != nil)
        #expect(sinkProvenance != nil)
        if let sinkMetrics {
            let sinkHash = SHA256.hash(data: sinkMetrics).map { String(format: "%02x", $0) }.joined()
            let sinkProvenanceDecoded = try? JSONDecoder().decode(VoiceBaselineProvenance.self, from: sinkProvenance!)
            #expect(sinkProvenanceDecoded?.metricsSHA256 == sinkHash)
        }
    }
}
