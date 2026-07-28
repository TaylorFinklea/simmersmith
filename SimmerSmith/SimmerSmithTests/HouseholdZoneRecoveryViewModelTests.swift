import CloudKit
import Foundation
import HouseholdSync
import Observation
import Testing

@testable import SimmerSmith

@MainActor
struct HouseholdZoneRecoveryViewModelTests {
    final class RecordingStore: HouseholdZoneRecoveryManifestStoring {
        private(set) var saved: [HouseholdZoneRecoveryStoredArtifact] = []
        private(set) var removeCount = 0
        var storedArtifact: HouseholdZoneRecoveryStoredArtifact?
        private(set) var savedOutcomes: [HouseholdZoneRecoveryApplyOutcome] = []
        var lastApplyOutcome: HouseholdZoneRecoveryApplyOutcome?
        private(set) var removeLastApplyOutcomeCount = 0
        private(set) var saveAttemptCount = 0
        var saveOutcomeError: Error?

        func save(_ manifest: HouseholdZoneRecoveryManifest) throws -> HouseholdZoneRecoveryStoredArtifact {
            let artifact = try HouseholdZoneRecoveryStoredArtifact(
                canonicalManifestBytes: manifest.canonicalJSONBytes(),
                digest: manifest.digest())
            saved.append(artifact)
            storedArtifact = artifact
            return artifact
        }

        func load() throws -> HouseholdZoneRecoveryStoredArtifact? {
            storedArtifact
        }

        func remove() throws {
            removeCount += 1
            storedArtifact = nil
        }

        func saveLastApplyOutcome(_ outcome: HouseholdZoneRecoveryApplyOutcome) throws {
            saveAttemptCount += 1
            if let saveOutcomeError {
                throw saveOutcomeError
            }
            savedOutcomes.append(outcome)
            lastApplyOutcome = outcome
        }

        func loadLastApplyOutcome() throws -> HouseholdZoneRecoveryApplyOutcome? {
            lastApplyOutcome
        }

        func removeLastApplyOutcome() throws {
            removeLastApplyOutcomeCount += 1
            lastApplyOutcome = nil
        }
    }

    /// A fake `AppState`-owned run. Marked `@Observable` (like the production
    /// `HouseholdZoneRecoveryApplyRun`) so the view model's `withObservationTracking`-based
    /// completion watcher can be exercised without any real `AppState`.
    @MainActor
    @Observable
    final class FakeApplyRun: HouseholdZoneRecoveryApplyRunObserving {
        var state: HouseholdZoneRecoveryApplyRunState
        var diagnostic: HouseholdZoneRecoveryApplyDiagnostic?
        var localConflictIdentity: HouseholdZoneRecoveryIdentity?

        init(state: HouseholdZoneRecoveryApplyRunState = .preparing) {
            self.state = state
        }
    }

    /// Stands in for `AppState`'s retained `activeHouseholdZoneRecoveryApplyRun`: whichever
    /// run is currently "owned" survives independently of any view model reading it.
    @MainActor
    final class RunBox {
        var value: (any HouseholdZoneRecoveryApplyRunObserving)?
    }

    enum SensitiveFailure: Error, CustomStringConvertible {
        case failed
        var description: String { "account=SECRET-ACCOUNT record=SECRET-RECIPE meal=SECRET-MEAL" }
    }

    private let sourceScope = MirrorScope(
        accountRecordName: "account-record",
        zoneOwnerName: CKCurrentUserDefaultName,
        zoneName: HouseholdZoneRecoveryManifest.reservedSourceZoneName,
        householdID: "spc-recipe-test",
        role: .owner,
        databaseScope: .private)
    private let targetScope = MirrorScope(
        accountRecordName: "account-record",
        zoneOwnerName: CKCurrentUserDefaultName,
        zoneName: "household-production",
        householdID: "production",
        role: .owner,
        databaseScope: .private)

    private func identity(
        _ recordName: String,
        type: String = "Recipe",
        source: MirrorScope? = nil,
        target: MirrorScope? = nil
    ) -> HouseholdZoneRecoveryIdentity {
        let source = source ?? sourceScope
        let target = target ?? targetScope
        return HouseholdZoneRecoveryIdentity(
            source: MirrorRecordIdentity(
                recordType: type,
                recordName: recordName,
                zoneOwnerName: source.zoneOwnerName,
                zoneName: source.zoneName),
            targetScope: target)
    }

    private func manifest(
        entries: [HouseholdZoneRecoveryEntry] = [],
        exclusions: [HouseholdZoneRecoveryExclusion] = [],
        unresolved: [HouseholdZoneRecoveryUnresolvedEntry] = [],
        blocked: [HouseholdZoneRecoveryBlockedEntry] = []
    ) throws -> HouseholdZoneRecoveryManifest {
        try HouseholdZoneRecoveryManifest(
            accountFingerprint: "account-fingerprint",
            sourceScope: sourceScope,
            targetScope: targetScope,
            sourceInputFingerprint: "source-fingerprint",
            targetInputFingerprint: "target-fingerprint",
            entries: entries,
            exclusions: exclusions,
            unresolvedEntries: unresolved,
            blockedEntries: blocked)
    }

    private func analysis(_ manifest: HouseholdZoneRecoveryManifest) -> HouseholdZoneRecoveryAnalysis {
        let allEntries = manifest.entries + manifest.unresolvedEntries.map(\.entry)
        return HouseholdZoneRecoveryAnalysis(
            manifest: manifest,
            summary: HouseholdZoneRecoveryPreviewSummary(
                candidateCount: allEntries.count + manifest.blockedEntries.count,
                copyCount: allEntries.filter { $0.action == .copy }.count,
                skipIdenticalCount: allEntries.filter { $0.action == .skipIdentical }.count,
                conflictCount: allEntries.filter { $0.action == .conflict }.count,
                excludedCount: manifest.exclusions.reduce(0) { $0 + $1.count },
                unresolvedCount: manifest.unresolvedEntries.filter { $0.decision == nil }.count,
                blockedCount: manifest.blockedEntries.count,
                assetCount: 0))
    }

    private func snapshot(
        source: MirrorScope? = nil,
        target: MirrorScope? = nil,
        epoch: Int = 41
    ) -> HouseholdZoneRecoveryAuthoritySnapshot {
        HouseholdZoneRecoveryAuthoritySnapshot(
            accountFingerprint: "account-fingerprint",
            sourceScope: source ?? sourceScope,
            targetScope: target ?? targetScope,
            sessionEpoch: epoch)
    }

    private func makeViewModel(
        available: Bool = true,
        snapshot: HouseholdZoneRecoveryAuthoritySnapshot? = nil,
        authorityIsCurrent: @escaping HouseholdZoneRecoveryViewModel.AuthorityValidator = { _ in true },
        analyze: @escaping HouseholdZoneRecoveryViewModel.AnalysisProvider,
        store: RecordingStore = RecordingStore(),
        startApplyRun: HouseholdZoneRecoveryViewModel.ApplyRunStarter? = nil,
        cancelApplyRun: HouseholdZoneRecoveryViewModel.ApplyRunCanceler? = nil,
        activeApplyRun: HouseholdZoneRecoveryViewModel.ActiveApplyRunProvider? = nil
    ) -> (HouseholdZoneRecoveryViewModel, RecordingStore) {
        let snapshot = snapshot ?? self.snapshot()
        return (
            HouseholdZoneRecoveryViewModel(
                isRecoveryAvailable: { available },
                authoritySnapshot: { snapshot },
                authorityIsCurrent: authorityIsCurrent,
                analyze: analyze,
                manifestStore: store,
                startApplyRun: startApplyRun,
                cancelApplyRun: cancelApplyRun,
                activeApplyRun: activeApplyRun),
            store)
    }

    /// Approves `entries` against `store` and returns the resulting artifact, mirroring what
    /// `analyze()` + decisions would have produced, without running the analysis machinery.
    private func approve(
        _ store: RecordingStore,
        entries: [HouseholdZoneRecoveryEntry]
    ) throws -> HouseholdZoneRecoveryStoredArtifact {
        try store.save(try manifest(entries: entries))
    }

    private func waitUntilSettled(_ viewModel: HouseholdZoneRecoveryViewModel) async {
        while case .analyzing = viewModel.state {
            await Task.yield()
        }
    }

    /// Yields until `condition` holds or a bounded number of scheduler turns elapse. Used to
    /// await the view model's `withObservationTracking`-based completion watcher, which
    /// resumes on the next MainActor turn after a fake run's `state` is mutated — no real
    /// timers are involved, so this settles in a handful of iterations.
    private func waitUntil(
        maxIterations: Int = 500,
        _ condition: () -> Bool
    ) async {
        var iterations = 0
        while !condition(), iterations < maxIterations {
            await Task.yield()
            iterations += 1
        }
    }

    @Test("non-debug/TestFlight builds fail closed before resolving authority")
    func testFlightGateFailsClosed() async {
        var authorityCalls = 0
        var analyzeCalls = 0
        let store = RecordingStore()
        let viewModel = HouseholdZoneRecoveryViewModel(
            isRecoveryAvailable: { false },
            authoritySnapshot: {
                authorityCalls += 1
                return snapshot()
            },
            authorityIsCurrent: { _ in true },
            analyze: { _, _, _ in
                analyzeCalls += 1
                return analysis(try manifest())
            },
            manifestStore: store)

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        #expect(authorityCalls == 0)
        #expect(analyzeCalls == 0)
        #expect(store.saved.isEmpty)
        #expect(viewModel.failureMessage == "Recovery analysis is unavailable in this build.")
    }

    @Test("analyze requires an authoritative owner/private exact target scope")
    func ownerPrivateAuthorityIsRequired() async throws {
        let participantTarget = MirrorScope(
            accountRecordName: targetScope.accountRecordName,
            zoneOwnerName: "shared-owner",
            zoneName: targetScope.zoneName,
            householdID: targetScope.householdID,
            role: .participant,
            databaseScope: .shared)
        var analyzeCalls = 0
        let (viewModel, store) = makeViewModel(snapshot: snapshot(target: participantTarget)) { _, _, _ in
            analyzeCalls += 1
            return analysis(try manifest())
        }

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        #expect(analyzeCalls == 0)
        #expect(store.saved.isEmpty)
        #expect(viewModel.failureMessage == "Recovery analysis could not verify the active owner household.")
    }

    @Test("analyzer receives the reserved source and exact active target IDs")
    func exactSourceAndTargetAreForwarded() async throws {
        var receivedSource: MirrorScope?
        var receivedTarget: MirrorScope?
        let expectedManifest = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("recipe-2026-07-25"), action: .copy),
        ])
        let (viewModel, _) = makeViewModel { authority, _, _ in
            receivedSource = authority.sourceScope
            receivedTarget = authority.targetScope
            return analysis(expectedManifest)
        }

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        #expect(receivedSource == sourceScope)
        #expect(receivedTarget == targetScope)
        #expect(viewModel.manifestDigest == (try expectedManifest.digest()))
        #expect(viewModel.reviewItems.first?.recordLabel.contains("recipe-2026-07-25") == true)
        #expect(viewModel.reviewItems.first?.dateLabel != nil)
    }

    @Test("captured epoch and authority are revalidated before preview publication")
    func staleEpochFailsClosed() async throws {
        let expectedManifest = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("recipe-secret"), action: .copy),
        ])
        var validatedEpochs: [Int] = []
        let (viewModel, store) = makeViewModel(
            snapshot: snapshot(epoch: 73),
            authorityIsCurrent: {
                validatedEpochs.append($0.sessionEpoch)
                return false
            },
            analyze: { _, _, _ in analysis(expectedManifest) })

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        #expect(validatedEpochs == [73])
        #expect(store.saved.isEmpty)
        #expect(viewModel.failureMessage == "The household session changed during recovery analysis.")
    }

    @Test("cancelling analysis returns to idle and never persists a partial artifact")
    func cancellationFailsClosed() async {
        let store = RecordingStore()
        let started = AsyncStream.makeStream(of: Void.self)
        let (viewModel, _) = makeViewModel(analyze: { _, _, _ in
            started.continuation.yield()
            try await Task.sleep(for: .seconds(30))
            return self.analysis(try self.manifest())
        }, store: store)

        viewModel.analyze()
        for await _ in started.stream.prefix(1) { break }
        viewModel.cancelAnalysis()
        await Task.yield()

        #expect(viewModel.state == .idle)
        #expect(store.saved.isEmpty)
    }

    @Test("cancelling analysis never touches the AppState-owned apply run")
    func cancelAnalysisNeverCancelsApply() async {
        var cancelCalls = 0
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            cancelApplyRun: { cancelCalls += 1 })

        viewModel.cancelAnalysis()

        #expect(cancelCalls == 0)
    }

    @Test("undecided provenance has no approval artifact and diagnostics redact identities")
    func undecidedProvenanceBlocksApproval() async throws {
        let unresolved = HouseholdZoneRecoveryUnresolvedEntry(
            entry: HouseholdZoneRecoveryEntry(
                identity: identity("SECRET-RECIPE-NAME"),
                action: .copy))
        let expectedAnalysis = analysis(try manifest(unresolved: [unresolved]))
        let (viewModel, store) = makeViewModel { _, _, _ in expectedAnalysis }

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        #expect(viewModel.approvalAvailable == false)
        #expect(store.saved.isEmpty)
        #expect(!viewModel.diagnosticDescription.contains("SECRET-RECIPE-NAME"))
        #expect(!viewModel.diagnosticDescription.contains("account-record"))
        #expect(!viewModel.diagnosticDescription.contains(targetScope.zoneName))
    }

    @Test("blocked entries never produce an approval artifact")
    func blockedEntriesBlockApproval() async throws {
        let blockedIdentity = identity("blocked-secret")
        let expectedAnalysis = analysis(try manifest(blocked: [
            HouseholdZoneRecoveryBlockedEntry(
                identity: blockedIdentity,
                reason: HouseholdZoneRecoveryBlockedEntry.missingDependencyReason,
                missingDependencies: [identity("missing-secret")]),
        ]))
        let (viewModel, store) = makeViewModel { _, _, _ in expectedAnalysis }

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        #expect(viewModel.approvalAvailable == false)
        #expect(store.saved.isEmpty)
        #expect(viewModel.blockedItems.count == 1)
    }

    @Test("explicit conflict and provenance decisions recanonicalize and persist a new digest")
    func decisionsRebuildCanonicalManifest() async throws {
        let candidate = identity("recipe-2026-07-25")
        let unresolvedConflict = HouseholdZoneRecoveryUnresolvedEntry(
            entry: HouseholdZoneRecoveryEntry(identity: candidate, action: .conflict),
            decision: nil)
        let initial = analysis(try manifest(unresolved: [unresolvedConflict]))
        let (viewModel, store) = makeViewModel { _, _, _ in initial }

        viewModel.analyze()
        await waitUntilSettled(viewModel)
        let initialDigest = try #require(viewModel.manifestDigest)
        #expect(viewModel.approvalAvailable == false)

        viewModel.decideConflict(candidate, decision: .source)
        let conflictDigest = try #require(viewModel.manifestDigest)
        #expect(conflictDigest != initialDigest)
        #expect(viewModel.approvalAvailable == false)

        viewModel.decideProvenance(candidate, decision: .include)
        let approvedDigest = try #require(viewModel.manifestDigest)
        #expect(approvedDigest != conflictDigest)
        #expect(viewModel.approvalAvailable)
        #expect(store.saved.map(\.digest) == [approvedDigest])
        #expect(store.saved.first?.canonicalManifestBytes == viewModel.canonicalManifestBytes)
        #expect(viewModel.storedApprovalDigest == approvedDigest)
        viewModel.typedDigestConfirmation = approvedDigest
        #expect(viewModel.canRequestApplyConfirmation)
    }

    @Test("include all decides only undecided provenance and persists one canonical artifact")
    func includeAllProvenanceRebuildsOnce() async throws {
        let first = identity("first-undecided")
        let second = identity("second-undecided")
        let previouslyExcluded = identity("already-excluded")
        let exclusions = [HouseholdZoneRecoveryExclusion(reason: "developer-fixture", count: 5)]
        let initialManifest = try manifest(
            exclusions: exclusions,
            unresolved: [
                HouseholdZoneRecoveryUnresolvedEntry(
                    entry: HouseholdZoneRecoveryEntry(identity: first, action: .copy)),
                HouseholdZoneRecoveryUnresolvedEntry(
                    entry: HouseholdZoneRecoveryEntry(identity: second, action: .copy)),
                HouseholdZoneRecoveryUnresolvedEntry(
                    entry: HouseholdZoneRecoveryEntry(identity: previouslyExcluded, action: .copy),
                    decision: .exclude),
            ])
        let initial = analysis(initialManifest)
        let (viewModel, store) = makeViewModel { _, _, _ in initial }

        viewModel.analyze()
        await waitUntilSettled(viewModel)
        let initialDigest = try #require(viewModel.manifestDigest)
        #expect(viewModel.undecidedProvenanceCount == 2)

        viewModel.decideAllProvenance(.include)

        let rebuilt = try #require(viewModel.preview?.manifest)
        let rebuiltDigest = try #require(viewModel.manifestDigest)
        let decisions = Dictionary(
            uniqueKeysWithValues: rebuilt.unresolvedEntries.map { ($0.identity, $0.decision) })
        #expect(rebuiltDigest != initialDigest)
        #expect(decisions[first] == .include)
        #expect(decisions[second] == .include)
        #expect(decisions[previouslyExcluded] == .exclude)
        #expect(rebuilt.exclusions == exclusions)
        #expect(viewModel.undecidedProvenanceCount == 0)
        #expect(rebuilt.unresolvedEntries.allSatisfy { $0.decision != nil })
        #expect(viewModel.approvalAvailable)
        #expect(store.saved.map(\.digest) == [rebuiltDigest])
    }

    @Test("include all fails closed when captured authority is stale")
    func includeAllWithStaleAuthorityNeverPersists() async throws {
        let unresolved = HouseholdZoneRecoveryUnresolvedEntry(
            entry: HouseholdZoneRecoveryEntry(
                identity: identity("stale-bulk-record"),
                action: .copy))
        let initial = analysis(try manifest(unresolved: [unresolved]))
        var authorityIsCurrent = true
        let (viewModel, store) = makeViewModel(
            authorityIsCurrent: { _ in authorityIsCurrent },
            analyze: { _, _, _ in initial })

        viewModel.analyze()
        await waitUntilSettled(viewModel)
        authorityIsCurrent = false

        viewModel.decideAllProvenance(.include)

        #expect(viewModel.failureMessage == "The household session changed during recovery review.")
        #expect(store.saved.isEmpty)
        #expect(store.removeCount >= 2)
    }

    @Test("authority changes before a decision clear the preview and never persist approval")
    func authorityChangeBeforeDecisionFailsClosed() async throws {
        let candidate = identity("authority-sensitive-record")
        let unresolved = HouseholdZoneRecoveryUnresolvedEntry(
            entry: HouseholdZoneRecoveryEntry(identity: candidate, action: .copy))
        let initial = analysis(try manifest(unresolved: [unresolved]))
        var authorityIsCurrent = true
        let (viewModel, store) = makeViewModel(
            authorityIsCurrent: { _ in authorityIsCurrent },
            analyze: { _, _, _ in initial })

        viewModel.analyze()
        await waitUntilSettled(viewModel)
        #expect(viewModel.manifestDigest != nil)

        authorityIsCurrent = false
        viewModel.decideProvenance(candidate, decision: .include)

        #expect(viewModel.failureMessage == "The household session changed during recovery review.")
        #expect(store.saved.isEmpty)
        #expect(store.removeCount >= 2)
    }

    @Test("failures expose only fixed privacy-safe text")
    func failureStringsArePrivacySafe() async {
        let (viewModel, store) = makeViewModel { _, _, _ in throw SensitiveFailure.failed }

        viewModel.analyze()
        await waitUntilSettled(viewModel)

        let message = viewModel.failureMessage ?? ""
        #expect(message == "Recovery analysis failed without changing household data.")
        #expect(!message.contains("SECRET"))
        #expect(store.saved.isEmpty)
    }

    @Test("apply is unavailable outside debug or TestFlight and never asks AppState to start")
    func applyGateFailsClosed() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var startCalls = 0
        let (viewModel, _) = makeViewModel(
            available: false,
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                startCalls += 1
                return FakeApplyRun()
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        #expect(viewModel.storedApprovalDigest == nil)
        #expect(viewModel.canRequestApplyConfirmation == false)
        #expect(startCalls == 0)
        #expect(viewModel.applyFailureMessage == "Recovery apply is unavailable in this build.")
    }

    @Test("exact stored digest and destructive second confirmation are both required before AppState starts a run")
    func exactDigestAndSecondConfirmationGateApply() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var startCalls: [(HouseholdZoneRecoveryStoredArtifact, String, HouseholdZoneRecoveryAuthoritySnapshot)] = []
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { passedArtifact, confirmedDigest, authority in
                startCalls.append((passedArtifact, confirmedDigest, authority))
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = "wrong-digest"
        viewModel.requestApplyConfirmation()
        #expect(viewModel.canRequestApplyConfirmation == false)
        #expect(startCalls.isEmpty)

        viewModel.typedDigestConfirmation = artifact.digest
        #expect(viewModel.canRequestApplyConfirmation)
        viewModel.requestApplyConfirmation()
        #expect(viewModel.applyState == .awaitingDestructiveConfirmation)
        #expect(startCalls.isEmpty)
        #expect(viewModel.destructiveConfirmationMessage.contains("source"))
        #expect(viewModel.destructiveConfirmationMessage.contains("preserved"))

        viewModel.confirmApply()

        #expect(startCalls.count == 1)
        #expect(startCalls.first?.0 == artifact)
        #expect(startCalls.first?.1 == artifact.digest)
        #expect(viewModel.applyState == .preparing)

        fakeRun.state = .verifiedCompletion(completedBatchCount: 2, totalBatchCount: 2)
        await waitUntil { viewModel.applyState == .verifiedCompletion(completedBatchCount: 2, totalBatchCount: 2) }

        #expect(viewModel.applyState == .verifiedCompletion(completedBatchCount: 2, totalBatchCount: 2))
        #expect(startCalls.count == 1, "a stopped/completed run is never retried automatically")
    }

    @Test("authority or epoch change after confirmation stops before AppState is asked to start")
    func authorityChangeAfterConfirmationStopsApply() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var currentEpoch = 41
        var startCalls = 0
        let (viewModel, _) = makeViewModel(
            authorityIsCurrent: { $0.sessionEpoch == currentEpoch },
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                startCalls += 1
                return FakeApplyRun()
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        currentEpoch = 42
        viewModel.confirmApply()

        #expect(startCalls == 0)
        #expect(viewModel.applyFailureMessage == "The household session changed before recovery apply.")
    }

    @Test("a changed stored manifest is not retried under the confirmed digest")
    func changedStoredManifestInvalidatesConfirmation() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var startCalls = 0
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                startCalls += 1
                return FakeApplyRun()
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        _ = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("different-record"), action: .copy),
        ])
        viewModel.confirmApply()

        #expect(startCalls == 0)
        #expect(viewModel.applyFailureMessage == "The approved recovery manifest changed. Review it again.")
    }

    @Test("AppState refusing to start a run surfaces a privacy-safe failure")
    func appStateRefusingToStartSurfacesFailure() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in nil })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        #expect(viewModel.applyFailureMessage == "Recovery apply could not start. Review it again.")
    }

    @Test("analysis and review decisions cannot mutate approval while an AppState run is in flight")
    func applyLocksAnalysisAndReviewControls() async throws {
        let conflictIdentity = identity("approved-conflict")
        let provenanceIdentity = identity("approved-provenance")
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(
                identity: conflictIdentity,
                action: .conflict,
                decision: .source),
        ])
        let fakeRun = FakeApplyRun(state: .applying(completedBatchCount: 0, totalBatchCount: 1))
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest(unresolved: [
                HouseholdZoneRecoveryUnresolvedEntry(
                    entry: HouseholdZoneRecoveryEntry(identity: provenanceIdentity, action: .copy),
                    decision: .include),
            ])) },
            store: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        let applyingState = viewModel.applyState
        #expect(applyingState == .applying(completedBatchCount: 0, totalBatchCount: 1))
        viewModel.decideConflict(conflictIdentity, decision: .target)
        viewModel.decideProvenance(provenanceIdentity, decision: .exclude)
        viewModel.decideAllProvenance(.exclude)
        viewModel.analyze()

        #expect(viewModel.applyState == applyingState)
        #expect(viewModel.state != .analyzing)

        fakeRun.state = .resumableStop(completedBatchCount: 0, totalBatchCount: 1)
        await waitUntil { viewModel.applyState == .resumableStop(completedBatchCount: 0, totalBatchCount: 1) }
        #expect(viewModel.applyState == .resumableStop(completedBatchCount: 0, totalBatchCount: 1))
    }

    @Test("the Stop safely action delegates to AppState.cancelHouseholdZoneRecoveryApply and never builds its own task")
    func cancelApplyDelegatesToAppState() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var cancelCalls = 0
        let fakeRun = FakeApplyRun(state: .applying(completedBatchCount: 0, totalBatchCount: 1))
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            cancelApplyRun: { cancelCalls += 1 },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        #expect(viewModel.applyIsRunning)

        viewModel.cancelApply()

        #expect(cancelCalls == 1)
        // The view model only asked AppState to cancel; AppState (not this test) is
        // responsible for actually transitioning the run, so simulate that here.
        fakeRun.state = .resumableStop(completedBatchCount: 0, totalBatchCount: 1)
        await waitUntil { viewModel.applyState == .resumableStop(completedBatchCount: 0, totalBatchCount: 1) }
        #expect(viewModel.applyState == .resumableStop(completedBatchCount: 0, totalBatchCount: 1))
    }

    @Test("conflict identity remains local and stops without retry")
    func conflictStopsWithLocalIdentity() async throws {
        let approvedIdentity = identity("local-conflict-record")
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: approvedIdentity, action: .copy),
        ])
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        fakeRun.localConflictIdentity = approvedIdentity
        fakeRun.state = .conflict(completedBatchCount: 0, totalBatchCount: 1)
        await waitUntil { viewModel.applyState == .conflict(completedBatchCount: 0, totalBatchCount: 1) }

        #expect(viewModel.localConflictIdentity == approvedIdentity)
        #expect(viewModel.applyStatusMessage == "Recovery stopped because target data changed.")
        #expect(!viewModel.applyStatusMessage.contains("local-conflict-record"))
    }

    @Test("a live stopped apply renders the diagnostic clause and never the completion sentence; a live verified completion renders no diagnostic clause")
    func liveApplyRendersDiagnosticNeverCompletion() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let diagnostic = HouseholdZoneRecoveryApplyDiagnostic(
            category: .limitExceeded,
            batchIndex: 0,
            batchRecordCount: 142)
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        fakeRun.diagnostic = diagnostic
        fakeRun.state = .resumableStop(completedBatchCount: 0, totalBatchCount: 3)
        await waitUntil { viewModel.applyState == .resumableStop(completedBatchCount: 0, totalBatchCount: 3) }

        #expect(viewModel.applyStatusMessage == "Recovery stopped safely after 0 of 3 batches "
            + "(limitExceeded, batch 0, 142 records). Resume manually with the same digest.")
        #expect(!viewModel.applyStatusMessage.contains("Verified recovery completion"))

        let completedRun = FakeApplyRun()
        runBox.value = completedRun
        completedRun.state = .verifiedCompletion(completedBatchCount: 3, totalBatchCount: 3)

        #expect(viewModel.applyStatusMessage == "Verified recovery completion: 3 of 3 batches.")
        #expect(!viewModel.applyStatusMessage.contains("("))
    }

    @Test("a stopped-with-diagnostic run persists its outcome, and a freshly constructed view model restores and renders it without re-running anything")
    func freshViewModelRestoresPersistedDiagnosticOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdZoneRecoveryManifestStore(directory: directory)
        let approvedManifest = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let artifact = try store.save(approvedManifest)
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let firstSnapshot = snapshot()
        let firstViewModel = HouseholdZoneRecoveryViewModel(
            isRecoveryAvailable: { true },
            authoritySnapshot: { firstSnapshot },
            authorityIsCurrent: { _ in true },
            analyze: { _, _, _ in self.analysis(approvedManifest) },
            manifestStore: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await firstViewModel.loadStoredApproval()
        firstViewModel.typedDigestConfirmation = artifact.digest
        firstViewModel.requestApplyConfirmation()
        firstViewModel.confirmApply()

        fakeRun.diagnostic = HouseholdZoneRecoveryApplyDiagnostic(
            category: .limitExceeded, batchIndex: 1, batchRecordCount: 40)
        fakeRun.state = .resumableStop(completedBatchCount: 1, totalBatchCount: 3)
        await waitUntil { (try? store.loadLastApplyOutcome()) != nil }

        let persisted = try #require(try store.loadLastApplyOutcome())
        #expect(persisted.kind == .resumableStop)
        #expect(persisted.completedBatchCount == 1)
        #expect(persisted.totalBatchCount == 3)
        #expect(persisted.diagnosticCategory == .limitExceeded)
        #expect(persisted.diagnosticBatchIndex == 1)
        #expect(persisted.diagnosticBatchRecordCount == 40)

        var freshStartCalls = 0
        let secondSnapshot = snapshot()
        let secondViewModel = HouseholdZoneRecoveryViewModel(
            isRecoveryAvailable: { true },
            authoritySnapshot: { secondSnapshot },
            authorityIsCurrent: { _ in true },
            analyze: { _, _, _ in self.analysis(approvedManifest) },
            manifestStore: store,
            startApplyRun: { _, _, _ in
                freshStartCalls += 1
                return FakeApplyRun()
            },
            activeApplyRun: { nil })

        await secondViewModel.loadStoredApproval()

        #expect(freshStartCalls == 0, "restoring must never re-run the apply")
        #expect(secondViewModel.applyState == .resumableStop(completedBatchCount: 1, totalBatchCount: 3))
        let message = secondViewModel.applyStatusMessage
        #expect(message.contains("limitExceeded"))
        #expect(message.contains("batch 1"))
        #expect(message.contains("40 records"))
        #expect(message.contains("Previous attempt"), "a restored outcome must read as the previous run's result")
    }

    @Test("a restored stop never renders the verified-completion sentence; a restored verified completion renders no diagnostic clause")
    func restoredOutcomesRenderDistinctly() async throws {
        let stoppedStore = RecordingStore()
        stoppedStore.lastApplyOutcome = HouseholdZoneRecoveryApplyOutcome(
            kind: .resumableStop,
            completedBatchCount: 0,
            totalBatchCount: 3,
            diagnosticCategory: .limitExceeded,
            diagnosticBatchIndex: 0,
            diagnosticBatchRecordCount: 142)
        let stoppedArtifact = try approve(stoppedStore, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let (stoppedViewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: stoppedStore,
            activeApplyRun: { nil })
        _ = stoppedArtifact

        await stoppedViewModel.loadStoredApproval()

        #expect(stoppedViewModel.applyState == .resumableStop(completedBatchCount: 0, totalBatchCount: 3))
        #expect(!stoppedViewModel.applyStatusMessage.contains("Verified recovery completion"))
        #expect(stoppedViewModel.applyStatusMessage.contains("limitExceeded"))

        let completedStore = RecordingStore()
        completedStore.lastApplyOutcome = HouseholdZoneRecoveryApplyOutcome(
            kind: .verifiedCompletion,
            completedBatchCount: 3,
            totalBatchCount: 3,
            diagnosticCategory: nil,
            diagnosticBatchIndex: nil,
            diagnosticBatchRecordCount: nil)
        let completedArtifact = try approve(completedStore, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let (completedViewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: completedStore,
            activeApplyRun: { nil })
        _ = completedArtifact

        await completedViewModel.loadStoredApproval()

        #expect(completedViewModel.applyState == .verifiedCompletion(completedBatchCount: 3, totalBatchCount: 3))
        #expect(completedViewModel.applyStatusMessage.contains("Verified recovery completion: 3 of 3 batches."))
        #expect(!completedViewModel.applyStatusMessage.contains("("), "a restored verified completion renders no diagnostic clause")
        #expect(completedViewModel.applyStatusMessage.contains("Previous attempt"))
    }

    @Test("a live run's state always wins over a stale restored outcome, and reflects true completion without the restored framing")
    func liveRunTakesPrecedenceOverRestoredOutcome() async throws {
        let store = RecordingStore()
        store.lastApplyOutcome = HouseholdZoneRecoveryApplyOutcome(
            kind: .resumableStop,
            completedBatchCount: 0,
            totalBatchCount: 3,
            diagnosticCategory: .limitExceeded,
            diagnosticBatchIndex: 0,
            diagnosticBatchRecordCount: 5)
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let liveRun = FakeApplyRun(state: .verifiedCompletion(completedBatchCount: 3, totalBatchCount: 3))
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            activeApplyRun: { liveRun })
        _ = artifact

        await viewModel.loadStoredApproval()

        #expect(viewModel.applyState == .verifiedCompletion(completedBatchCount: 3, totalBatchCount: 3))
        #expect(viewModel.applyStatusMessage == "Verified recovery completion: 3 of 3 batches.")
        #expect(!viewModel.applyStatusMessage.contains("Previous attempt"))
    }

    @Test("discarding the view model while a run is in flight does not cancel it, and a reattached view model picks up the live state")
    func discardingViewModelDoesNotCancelInFlightRun() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var cancelCalls = 0
        let runBox = RunBox()
        var viewModel: HouseholdZoneRecoveryViewModel? = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                let run = FakeApplyRun(state: .applying(completedBatchCount: 1, totalBatchCount: 4))
                runBox.value = run
                return run
            },
            cancelApplyRun: { cancelCalls += 1 },
            activeApplyRun: { runBox.value }).0

        await viewModel?.loadStoredApproval()
        viewModel?.typedDigestConfirmation = artifact.digest
        viewModel?.requestApplyConfirmation()
        viewModel?.confirmApply()
        #expect(viewModel?.applyState == .applying(completedBatchCount: 1, totalBatchCount: 4))

        // Simulate the SwiftUI view (and its `@State`-held reference) being torn down. Nothing
        // in the view model wires deinit/scope-exit to cancellation.
        viewModel = nil

        #expect(cancelCalls == 0)

        let (reattached, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            activeApplyRun: { runBox.value })

        #expect(reattached.applyState == .applying(completedBatchCount: 1, totalBatchCount: 4))
        #expect(reattached.applyIsRunning)
    }

    @Test("the persisted outcome file contains only enum/count fields, never record names, digests, or other household content")
    func persistedOutcomeContainsNoPrivateContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdZoneRecoveryManifestStore(directory: directory)
        let secretIdentity = identity("SECRET-RECORD-NAME-9F3B")
        let approvedManifest = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: secretIdentity, action: .copy),
        ])
        let artifact = try store.save(approvedManifest)
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let outcomeSnapshot = snapshot()
        let viewModel = HouseholdZoneRecoveryViewModel(
            isRecoveryAvailable: { true },
            authoritySnapshot: { outcomeSnapshot },
            authorityIsCurrent: { _ in true },
            analyze: { _, _, _ in self.analysis(approvedManifest) },
            manifestStore: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        fakeRun.localConflictIdentity = secretIdentity
        fakeRun.diagnostic = HouseholdZoneRecoveryApplyDiagnostic(
            category: .serverRecordChanged, batchIndex: 2, batchRecordCount: 9)
        fakeRun.state = .conflict(completedBatchCount: 1, totalBatchCount: 5)
        await waitUntil { (try? store.loadLastApplyOutcome()) != nil }

        let outcomeFileURL = directory.appendingPathComponent("last-apply-outcome.json")
        let rawBytes = try Data(contentsOf: outcomeFileURL)
        let rawText = String(decoding: rawBytes, as: UTF8.self)

        #expect(!rawText.contains("SECRET-RECORD-NAME"))
        #expect(!rawText.contains("approved-record"))
        #expect(!rawText.contains(artifact.digest))
        #expect(!rawText.contains(sourceScope.zoneName))
        #expect(!rawText.contains(targetScope.zoneName))
        #expect(!rawText.contains("account-fingerprint"))
        #expect(!rawText.contains("account-record"))

        let json = try #require(
            try JSONSerialization.jsonObject(with: rawBytes) as? [String: Any])
        let allowedKeys: Set<String> = [
            "kind",
            "completedBatchCount",
            "totalBatchCount",
            "diagnosticCategory",
            "diagnosticBatchIndex",
            "diagnosticBatchRecordCount",
        ]
        #expect(Set(json.keys).isSubset(of: allowedKeys))
        #expect(json["kind"] as? String == "conflict")
        #expect(json["completedBatchCount"] as? Int == 1)
        #expect(json["totalBatchCount"] as? Int == 5)
        #expect(json["diagnosticCategory"] as? String == "serverRecordChanged")
        #expect(json["diagnosticBatchIndex"] as? Int == 2)
        #expect(json["diagnosticBatchRecordCount"] as? Int == 9)
    }

    @Test("approving a new digest clears any outcome recorded against a prior manifest")
    func newApprovalClearsStaleOutcome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdZoneRecoveryManifestStore(directory: directory)
        _ = try store.save(try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("first-approved"), action: .copy),
        ]))
        try store.saveLastApplyOutcome(HouseholdZoneRecoveryApplyOutcome(
            kind: .verifiedCompletion,
            completedBatchCount: 1,
            totalBatchCount: 1,
            diagnosticCategory: nil,
            diagnosticBatchIndex: nil,
            diagnosticBatchRecordCount: nil))
        #expect(try store.loadLastApplyOutcome() != nil)

        _ = try store.save(try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("second-approved"), action: .copy),
        ]))

        #expect(try store.loadLastApplyOutcome() == nil)
    }

    @Test("removing the approved manifest also clears any recorded outcome")
    func removingApprovalClearsStaleOutcome() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdZoneRecoveryManifestStore(directory: directory)
        _ = try store.save(try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("first-approved"), action: .copy),
        ]))
        try store.saveLastApplyOutcome(HouseholdZoneRecoveryApplyOutcome(
            kind: .failed,
            completedBatchCount: 0,
            totalBatchCount: 0,
            diagnosticCategory: nil,
            diagnosticBatchIndex: nil,
            diagnosticBatchRecordCount: nil))

        try store.remove()

        #expect(try store.loadLastApplyOutcome() == nil)
    }

    @Test("application-support store round-trips canonical bytes and verifies the digest")
    func manifestStoreRoundTripsCanonicalArtifact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdZoneRecoveryManifestStore(directory: directory)
        let expectedManifest = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("recipe-2026-07-25"), action: .copy),
        ])

        let saved = try store.save(expectedManifest)
        let loaded = try #require(try store.load())

        #expect(loaded == saved)
        #expect(loaded.canonicalManifestBytes == (try expectedManifest.canonicalJSONBytes()))
        #expect(loaded.digest == (try expectedManifest.digest()))
    }

    @Test("application-support store round-trips the last apply outcome")
    func outcomeStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HouseholdZoneRecoveryManifestStore(directory: directory)
        let outcome = HouseholdZoneRecoveryApplyOutcome(
            kind: .resumableStop,
            completedBatchCount: 2,
            totalBatchCount: 5,
            diagnosticCategory: .quotaExceeded,
            diagnosticBatchIndex: 2,
            diagnosticBatchRecordCount: 30)

        try store.saveLastApplyOutcome(outcome)

        #expect(try store.loadLastApplyOutcome() == outcome)
        #expect(try store.load() == nil, "the outcome round trip must not touch the approved-manifest file")
    }

    // MARK: - Resume after a terminal run (finding 1)

    /// Drives one apply run to `terminalState`, then verifies re-typing the digest and
    /// requesting confirmation reaches `.awaitingDestructiveConfirmation` and `confirmApply()`
    /// actually starts a fresh run — the core of "a finished run must never brick resume".
    private func assertResumeAfterTerminalRun(
        terminalState: HouseholdZoneRecoveryApplyRunState,
        diagnostic: HouseholdZoneRecoveryApplyDiagnostic? = nil,
        localConflictIdentity: HouseholdZoneRecoveryIdentity? = nil
    ) async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var startCalls = 0
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                startCalls += 1
                let run = FakeApplyRun()
                runBox.value = run
                return run
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        #expect(startCalls == 1)

        let firstRun = try #require(runBox.value as? FakeApplyRun)
        firstRun.diagnostic = diagnostic
        firstRun.localConflictIdentity = localConflictIdentity
        firstRun.state = terminalState
        await waitUntil { !viewModel.applyIsRunning }
        await waitUntil { store.savedOutcomes.count == 1 }

        viewModel.typedDigestConfirmation = artifact.digest
        #expect(
            viewModel.canRequestApplyConfirmation,
            "a terminal run must never block re-confirmation")
        viewModel.requestApplyConfirmation()
        #expect(
            viewModel.applyState == .awaitingDestructiveConfirmation,
            "the confirmation dialog must actually present after a terminal run")

        viewModel.confirmApply()
        #expect(startCalls == 2, "confirmApply() must actually start a new run, not silently no-op")
        #expect(viewModel.applyState == .preparing)
        #expect(
            viewModel.localConflictIdentity == nil,
            "a stale conflict identity from the finished run must never sit beside a new attempt")
    }

    @Test("resuming after a resumableStop run reaches confirmation and starts a fresh run")
    func resumeAfterResumableStop() async throws {
        try await assertResumeAfterTerminalRun(
            terminalState: .resumableStop(completedBatchCount: 1, totalBatchCount: 3))
    }

    @Test("resuming after a conflict run reaches confirmation, starts a fresh run, and clears the stale conflict identity")
    func resumeAfterConflict() async throws {
        try await assertResumeAfterTerminalRun(
            terminalState: .conflict(completedBatchCount: 1, totalBatchCount: 3),
            diagnostic: HouseholdZoneRecoveryApplyDiagnostic(
                category: .serverRecordChanged, batchIndex: 1, batchRecordCount: 4),
            localConflictIdentity: identity("conflicting-record"))
    }

    @Test("resuming after a failed run reaches confirmation and starts a fresh run")
    func resumeAfterFailed() async throws {
        try await assertResumeAfterTerminalRun(
            terminalState: .failed(
                "Recovery apply stopped before the next write because its safety checks changed"
                    + " (limitExceeded, batch 2, 10 records).",
                completedBatchCount: 1,
                totalBatchCount: 3),
            diagnostic: HouseholdZoneRecoveryApplyDiagnostic(
                category: .limitExceeded, batchIndex: 2, batchRecordCount: 10))
    }

    @Test("re-approving after a verifiedCompletion run reaches confirmation and starts a fresh run")
    func resumeAfterVerifiedCompletion() async throws {
        try await assertResumeAfterTerminalRun(
            terminalState: .verifiedCompletion(completedBatchCount: 3, totalBatchCount: 3))
    }

    @Test("a live non-terminal run still suppresses a fresh local state and still cannot be started twice")
    func liveRunStillSuppressesLocalStateAndBlocksSecondStart() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        var startCalls = 0
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                startCalls += 1
                let run = FakeApplyRun(state: .applying(completedBatchCount: 1, totalBatchCount: 4))
                runBox.value = run
                return run
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        #expect(startCalls == 1)
        #expect(viewModel.applyState == .applying(completedBatchCount: 1, totalBatchCount: 4))

        viewModel.typedDigestConfirmation = artifact.digest
        #expect(
            viewModel.canRequestApplyConfirmation == false,
            "a live run must block a fresh confirmation request")
        viewModel.requestApplyConfirmation()
        #expect(
            viewModel.applyState == .applying(completedBatchCount: 1, totalBatchCount: 4),
            "a live run must keep owning the screen; the local state must never leak through")

        viewModel.confirmApply()
        #expect(startCalls == 1, "two concurrent runs must remain impossible")
    }

    // MARK: - A fresh instance never infers "no attempt" from `.idle` (finding 2)

    @Test("a view model mounted while another instance's run is in flight renders that run's live progress, then its terminal state when it finishes, instead of collapsing to idle")
    func freshInstanceRendersInFlightRunsTerminalStateInsteadOfIdle() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        // No outcome file on disk and a run already owned by `AppState` before this instance
        // exists: mirrors a fresh view model mounted (e.g. after Back-then-re-entry during the
        // pre-park window) while a prior instance's confirmed apply is still running. This
        // instance never called `requestApplyConfirmation()`/`confirmApply()` itself.
        let fakeRun = FakeApplyRun(state: .applying(completedBatchCount: 0, totalBatchCount: 4))
        let runBox = RunBox()
        runBox.value = fakeRun
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            activeApplyRun: { runBox.value })
        _ = artifact

        await viewModel.loadStoredApproval()
        #expect(
            viewModel.applyState == .applying(completedBatchCount: 0, totalBatchCount: 4),
            "a fresh instance must still render live progress of a run it never started")

        // The run fails before `AppState` ever parks (the finding-1 preparation-phase path):
        // no teardown occurs, so nothing else nudges this instance's local state.
        fakeRun.state = .failed(
            "Recovery apply stopped before completion after 0 of 0 batches.",
            completedBatchCount: 0,
            totalBatchCount: 0)

        #expect(
            viewModel.applyState == .failed(
                "Recovery apply stopped before completion after 0 of 0 batches."),
            "a fresh instance must render the run's terminal outcome, not collapse to idle")
    }

    @Test("after a fresh instance's operator requests a new confirmation, a terminal run it never started stops dictating the screen")
    func freshInstanceFreshConfirmationSupersedesUnstartedTerminalRun() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let fakeRun = FakeApplyRun(
            state: .failed("boom", completedBatchCount: 0, totalBatchCount: 0))
        let runBox = RunBox()
        runBox.value = fakeRun
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        #expect(viewModel.applyState == .failed("boom"))

        viewModel.typedDigestConfirmation = artifact.digest
        #expect(viewModel.canRequestApplyConfirmation)
        viewModel.requestApplyConfirmation()

        #expect(
            viewModel.applyState == .awaitingDestructiveConfirmation,
            "requesting a fresh confirmation must supersede a terminal run this instance never started")
    }

    @Test("a fresh instance cannot start a second run while another instance's run is still in flight")
    func freshInstanceCannotStartConcurrentRun() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let fakeRun = FakeApplyRun(state: .applying(completedBatchCount: 1, totalBatchCount: 4))
        let runBox = RunBox()
        runBox.value = fakeRun
        var startCalls = 0
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                startCalls += 1
                return FakeApplyRun()
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest

        #expect(
            viewModel.canRequestApplyConfirmation == false,
            "a live run owned by another instance must block a fresh confirmation request")
        viewModel.requestApplyConfirmation()
        #expect(viewModel.applyState == .applying(completedBatchCount: 1, totalBatchCount: 4))

        viewModel.confirmApply()
        #expect(startCalls == 0, "two concurrent runs must remain impossible even from a fresh instance")
    }

    // MARK: - Restored `.failed` renders its reason (finding 2)

    @Test("a restored failed outcome renders its category, batch index, record count, and the counts it reached")
    func restoredFailedRendersDiagnosticAndCounts() async throws {
        let store = RecordingStore()
        store.lastApplyOutcome = HouseholdZoneRecoveryApplyOutcome(
            kind: .failed,
            completedBatchCount: 7,
            totalBatchCount: 12,
            diagnosticCategory: .limitExceeded,
            diagnosticBatchIndex: 7,
            diagnosticBatchRecordCount: 142)
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            activeApplyRun: { nil })
        _ = artifact

        await viewModel.loadStoredApproval()

        let message = try #require(viewModel.applyFailureMessage)
        #expect(message.contains("limitExceeded"))
        #expect(message.contains("batch 7"))
        #expect(message.contains("142 records"))
        #expect(message.contains("7 of 12 batches"), "the counts the run reached must survive restore")
        #expect(viewModel.applyStatusMessage.contains("Previous attempt"))
    }

    @Test("a live failed run renders its own diagnostic clause exactly once, never doubled")
    func liveFailedRendersClauseExactlyOnce() async throws {
        let store = RecordingStore()
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        let liveMessage = "Recovery apply stopped before the next write because its safety checks"
            + " changed (limitExceeded, batch 7, 142 records)."
        fakeRun.state = .failed(liveMessage, completedBatchCount: 7, totalBatchCount: 12)
        await waitUntil { !viewModel.applyIsRunning }

        #expect(viewModel.applyFailureMessage == liveMessage)
        let status = viewModel.applyStatusMessage
        #expect(status == liveMessage, "a live failure's status message must be exactly the run's own message")
        let clauseOccurrences = status.components(
            separatedBy: "(limitExceeded, batch 7, 142 records)").count - 1
        #expect(clauseOccurrences == 1, "a live failure's diagnostic clause must never be doubled")
    }

    // MARK: - Starting a run invalidates the stale outcome (finding 4)

    @Test("starting a new run clears the prior persisted outcome so an interrupted run leaves no stale outcome")
    func startingRunClearsStaleOutcome() async throws {
        let store = RecordingStore()
        store.lastApplyOutcome = HouseholdZoneRecoveryApplyOutcome(
            kind: .resumableStop,
            completedBatchCount: 3,
            totalBatchCount: 10,
            diagnosticCategory: .limitExceeded,
            diagnosticBatchIndex: 3,
            diagnosticBatchRecordCount: 50)
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                let run = FakeApplyRun(state: .applying(completedBatchCount: 0, totalBatchCount: 10))
                runBox.value = run
                return run
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        #expect(viewModel.applyState == .resumableStop(completedBatchCount: 3, totalBatchCount: 10))
        #expect(store.lastApplyOutcome != nil)

        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        #expect(
            store.lastApplyOutcome == nil,
            "starting a new run must invalidate the prior outcome immediately, not at termination")
        #expect(store.removeLastApplyOutcomeCount == 1)

        // A process kill mid-flight never reaches a terminal state, so nothing re-persists.
        // A freshly attached view model against the same store must never resurrect the
        // previous run's outcome and must not understate what actually happened.
        let (relaunched, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            activeApplyRun: { nil })
        await relaunched.loadStoredApproval()
        #expect(
            relaunched.applyState == .idle,
            "a run interrupted before terminating must never surface the stale predecessor's outcome")
    }

    // MARK: - A failed durable write never claims persistence (finding 5)

    @Test("a failing outcome write does not claim persistence, though the live render still reflects the true outcome")
    func failingOutcomeWriteDoesNotClaimPersistence() async throws {
        let store = RecordingStore()
        store.saveOutcomeError = SensitiveFailure.failed
        let artifact = try approve(store, entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let fakeRun = FakeApplyRun()
        let runBox = RunBox()
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(try self.manifest()) },
            store: store,
            startApplyRun: { _, _, _ in
                runBox.value = fakeRun
                return fakeRun
            },
            activeApplyRun: { runBox.value })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()

        fakeRun.state = .resumableStop(completedBatchCount: 2, totalBatchCount: 5)
        await waitUntil { store.saveAttemptCount == 1 }

        #expect(store.savedOutcomes.isEmpty, "a failed write must never be recorded as saved")
        #expect(store.lastApplyOutcome == nil, "a failed write must not claim persistence")
        #expect(
            viewModel.applyState == .resumableStop(completedBatchCount: 2, totalBatchCount: 5),
            "the live render must still reflect the true outcome even when the durable write fails")
    }
}
