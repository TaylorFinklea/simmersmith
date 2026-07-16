import CryptoKit
import Foundation
import Testing
@testable import SimmerSmithBallastAdapter

/// Spec §D4: happy path plus each individual mechanical-check failure, with a distinct error case
/// (and message) per failure.
@Suite("Voice baseline preflight validator")
struct VoiceBaselinePreflightValidatorTests {
    @Test("a matching metrics/sidecar pair validates and returns the sidecar identity")
    func happyPathValidates() throws {
        let metricsData = try encode(makeMetrics())
        let sidecar = makeSidecar(metricsSHA256: hash(of: metricsData))
        let sidecarData = try encode(sidecar)

        let result = try VoiceBaselinePreflightValidator.validate(
            metricsData: metricsData,
            sidecarData: sidecarData
        )

        #expect(result.providerName == sidecar.providerName)
        #expect(result.modelIdentifier == sidecar.modelIdentifier)
        #expect(result.startedAt == sidecar.startedAt)
        #expect(result.endedAt == sidecar.endedAt)
        #expect(result.appVersion == sidecar.appVersion)
        #expect(result.appBuild == sidecar.appBuild)
        #expect(result.repoCommit == sidecar.repoCommit)
        #expect(result.scorerVersion == sidecar.scorerVersion)
        #expect(result.runnerVersion == sidecar.runnerVersion)
    }

    @Test("a malformed metrics file fails with metricsDecodeFailed")
    func malformedMetricsFails() throws {
        let metricsData = Data("not json".utf8)
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected metricsDecodeFailed")
        } catch VoiceBaselinePreflightValidator.ValidationError.metricsDecodeFailed {
        } catch {
            Issue.record("expected metricsDecodeFailed, got \(error)")
        }
    }

    @Test("a metrics role other than productionCloudBaseline fails with wrongRole")
    func wrongRoleFails() throws {
        let metricsData = try encode(makeMetrics(role: .mockWiring))
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected wrongRole")
        } catch VoiceBaselinePreflightValidator.ValidationError.wrongRole(let actual) {
            #expect(actual == .mockWiring)
        } catch {
            Issue.record("expected wrongRole, got \(error)")
        }
    }

    @Test("a corpusID that doesn't match VoiceParseEvalPolicy fails with corpusIDMismatch")
    func corpusIDMismatchFails() throws {
        let metricsData = try encode(makeMetrics(corpusID: "some-other-corpus"))
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected corpusIDMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.corpusIDMismatch {
        } catch {
            Issue.record("expected corpusIDMismatch, got \(error)")
        }
    }

    @Test("a corpusDigest that doesn't match VoiceParseEvalPolicy fails with corpusDigestMismatch")
    func corpusDigestMismatchFails() throws {
        let metricsData = try encode(makeMetrics(corpusDigest: "deadbeef"))
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected corpusDigestMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.corpusDigestMismatch {
        } catch {
            Issue.record("expected corpusDigestMismatch, got \(error)")
        }
    }

    @Test("a caseCount that doesn't match VoiceParseEvalPolicy fails with caseCountMismatch")
    func caseCountMismatchFails() throws {
        let metricsData = try encode(makeMetrics(caseCount: 59, caseRuns: 59 * VoiceParseEvalPolicy.liveRunsPerCase))
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected caseCountMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.caseCountMismatch {
        } catch {
            Issue.record("expected caseCountMismatch, got \(error)")
        }
    }

    @Test("a runsPerCase that doesn't match VoiceParseEvalPolicy fails with runsPerCaseMismatch")
    func runsPerCaseMismatchFails() throws {
        let metricsData = try encode(makeMetrics(runsPerCase: 2, caseRuns: VoiceParseEvalPolicy.corpusCaseCount * 2))
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected runsPerCaseMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.runsPerCaseMismatch {
        } catch {
            Issue.record("expected runsPerCaseMismatch, got \(error)")
        }
    }

    @Test("caseRuns not equal to caseCount times runsPerCase fails with caseRunsMismatch")
    func caseRunsMismatchFails() throws {
        let metricsData = try encode(makeMetrics(caseRuns: VoiceParseEvalPolicy.corpusCaseCount * VoiceParseEvalPolicy.liveRunsPerCase - 1))
        let sidecarData = try encode(makeSidecar(metricsSHA256: hash(of: metricsData)))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected caseRunsMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.caseRunsMismatch {
        } catch {
            Issue.record("expected caseRunsMismatch, got \(error)")
        }
    }

    @Test("a malformed sidecar file fails with sidecarDecodeFailed")
    func malformedSidecarFails() throws {
        let metricsData = try encode(makeMetrics())
        let sidecarData = Data("not json".utf8)

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected sidecarDecodeFailed")
        } catch VoiceBaselinePreflightValidator.ValidationError.sidecarDecodeFailed {
        } catch {
            Issue.record("expected sidecarDecodeFailed, got \(error)")
        }
    }

    @Test("a sidecar missing a required field fails with sidecarDecodeFailed")
    func sidecarMissingFieldFails() throws {
        let metricsData = try encode(makeMetrics())
        var sidecarObject = try #require(
            try JSONSerialization.jsonObject(
                with: encode(makeSidecar(metricsSHA256: hash(of: metricsData)))
            ) as? [String: Any]
        )
        sidecarObject.removeValue(forKey: "runID")
        let sidecarData = try JSONSerialization.data(withJSONObject: sidecarObject)

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected sidecarDecodeFailed")
        } catch VoiceBaselinePreflightValidator.ValidationError.sidecarDecodeFailed {
        } catch {
            Issue.record("expected sidecarDecodeFailed, got \(error)")
        }
    }

    @Test("a sidecar metricsSHA256 that doesn't match the exact metrics bytes fails with metricsHashMismatch")
    func metricsHashMismatchFails() throws {
        let metricsData = try encode(makeMetrics())
        let sidecarData = try encode(makeSidecar(metricsSHA256: "0000000000000000000000000000000000000000000000000000000000000000"))

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected metricsHashMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.metricsHashMismatch {
        } catch {
            Issue.record("expected metricsHashMismatch, got \(error)")
        }
    }

    @Test("a sidecar corpusDigest that diverges from the metrics corpusDigest fails with sidecarCorpusDigestMismatch")
    func sidecarCorpusDigestMismatchFails() throws {
        let metricsData = try encode(makeMetrics())
        let sidecarData = try encode(
            makeSidecar(metricsSHA256: hash(of: metricsData), corpusDigest: "some-other-digest")
        )

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected sidecarCorpusDigestMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.sidecarCorpusDigestMismatch {
        } catch {
            Issue.record("expected sidecarCorpusDigestMismatch, got \(error)")
        }
    }

    @Test("a sidecar scorerVersion that doesn't match VoiceParseBaselineEval.scoringVersion fails with scorerVersionMismatch")
    func scorerVersionMismatchFails() throws {
        let metricsData = try encode(makeMetrics())
        let sidecarData = try encode(
            makeSidecar(metricsSHA256: hash(of: metricsData), scorerVersion: "some-old-version")
        )

        do {
            _ = try VoiceBaselinePreflightValidator.validate(metricsData: metricsData, sidecarData: sidecarData)
            Issue.record("expected scorerVersionMismatch")
        } catch VoiceBaselinePreflightValidator.ValidationError.scorerVersionMismatch {
        } catch {
            Issue.record("expected scorerVersionMismatch, got \(error)")
        }
    }

    // MARK: - Support

    private func makeMetrics(
        role: VoiceParseEvalRole = .productionCloudBaseline,
        corpusID: String = VoiceParseEvalPolicy.corpusID,
        corpusDigest: String = VoiceParseEvalPolicy.corpusDigest,
        caseCount: Int = VoiceParseEvalPolicy.corpusCaseCount,
        runsPerCase: Int = VoiceParseEvalPolicy.liveRunsPerCase,
        caseRuns: Int? = nil
    ) -> VoiceParseEvalMetrics {
        VoiceParseEvalMetrics(
            role: role,
            providerName: "production-cloud",
            modelIdentifier: "cloud-model-v1",
            corpusID: corpusID,
            corpusDigest: corpusDigest,
            caseCount: caseCount,
            runsPerCase: runsPerCase,
            caseRuns: caseRuns ?? caseCount * runsPerCase,
            entryPrecision: 0.9,
            entryRecall: 0.9,
            entryF1: 0.9,
            exactPlanMatchRate: 0.8,
            fieldAccuracy: 0.9,
            unsupportedEntryRate: 0.1,
            safetyUnsupportedEntries: 0,
            emptyResultFalseNegativeRate: 0.0,
            repairRate: 0.0,
            fallbackRate: 0.0,
            meanLatencyMilliseconds: 500
        )
    }

    private func makeSidecar(
        metricsSHA256: String,
        corpusDigest: String = VoiceParseEvalPolicy.corpusDigest,
        scorerVersion: String = VoiceParseBaselineEval.scoringVersion
    ) -> VoiceBaselineProvenance {
        VoiceBaselineProvenance(
            runID: "run-1",
            metricsSHA256: metricsSHA256,
            corpusDigest: corpusDigest,
            startedAt: "2026-07-16T00:00:00Z",
            endedAt: "2026-07-16T00:10:00Z",
            appVersion: "1.0",
            appBuild: "100",
            repoCommit: "abc123def456",
            scorerVersion: scorerVersion,
            runnerVersion: "p8-runner-1",
            deviceModel: "iPhone17,1",
            osVersion: "iOS 26.0",
            providerName: "production-cloud",
            modelIdentifier: "cloud-model-v1",
            scoredFailureCounts: [:]
        )
    }

    private func encode(_ value: some Encodable) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
