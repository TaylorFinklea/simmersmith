import CloudKit
import Foundation
import HouseholdSync
import Testing

@testable import SimmerSmith

@MainActor
struct HouseholdZoneRecoveryViewModelTests {
    final class RecordingStore: HouseholdZoneRecoveryManifestStoring {
        private(set) var saved: [HouseholdZoneRecoveryStoredArtifact] = []
        private(set) var removeCount = 0
        var storedArtifact: HouseholdZoneRecoveryStoredArtifact?

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
    }

    final class RecordingApplyBoundary: HouseholdZoneRecoveryApplyBoundary {
        let sessionAuthority = HouseholdSessionAuthority(initiallyAuthoritative: true)
        var snapshot: HouseholdZoneRecoveryApplyAuthoritySnapshot
        private(set) var isParked = true
        private(set) var unparkCount = 0

        init(snapshot: HouseholdZoneRecoveryAuthoritySnapshot) {
            self.snapshot = HouseholdZoneRecoveryApplyAuthoritySnapshot(
                accountFingerprint: snapshot.accountFingerprint,
                sourceScope: snapshot.sourceScope,
                targetScope: snapshot.targetScope,
                sessionEpoch: snapshot.sessionEpoch)
        }

        func currentAuthoritySnapshot() async throws -> HouseholdZoneRecoveryApplyAuthoritySnapshot {
            snapshot
        }

        func normalSessionIsParked() async -> Bool {
            isParked
        }

        func unparkNormalSession() async {
            isParked = false
            unparkCount += 1
            sessionAuthority.revoke()
        }
    }

    final class RecordingApplyOperation: HouseholdZoneRecoveryApplying {
        let totalBatchCount: Int
        private(set) var maximumBatchCounts: [Int] = []
        var results: [HouseholdZoneRecoveryApplyResult]

        init(
            totalBatchCount: Int,
            results: [HouseholdZoneRecoveryApplyResult]
        ) {
            self.totalBatchCount = totalBatchCount
            self.results = results
        }

        func apply(maximumBatchCount: Int) async -> HouseholdZoneRecoveryApplyResult {
            maximumBatchCounts.append(maximumBatchCount)
            return results.removeFirst()
        }
    }
    final class SuspendingApplyOperation: HouseholdZoneRecoveryApplying {
        let totalBatchCount = 1
        let started = AsyncStream.makeStream(of: Void.self)
        private let result: HouseholdZoneRecoveryApplyResult

        init(result: HouseholdZoneRecoveryApplyResult) {
            self.result = result
        }

        func apply(maximumBatchCount: Int) async -> HouseholdZoneRecoveryApplyResult {
            started.continuation.yield()
            try? await Task.sleep(for: .seconds(30))
            return result
        }
    }

    final class SnapshotBox {
        var value: HouseholdZoneRecoveryAuthoritySnapshot

        init(_ value: HouseholdZoneRecoveryAuthoritySnapshot) {
            self.value = value
        }
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

    private func receipt(
        completedBatchCount: Int,
        totalBatchCount: Int,
        complete: Bool = false
    ) throws -> HouseholdZoneRecoveryReceipt {
        let batchDigests = (0..<totalBatchCount).map { "batch-\($0)" }
        return try HouseholdZoneRecoveryReceipt(
            manifestDigest: "manifest-digest",
            sourceInputFingerprint: "source-fingerprint",
            initialTargetInputFingerprint: "target-fingerprint",
            targetZoneOwnerName: targetScope.zoneOwnerName,
            targetZoneName: targetScope.zoneName,
            approvedIdentityActions: [],
            batchDigests: batchDigests,
            targetApplicationDigests: (0...totalBatchCount).map { "target-\($0)" },
            targetRecordApplicationDigestProgress: Array(
                repeating: [:],
                count: totalBatchCount + 1),
            completedBatches: batchDigests.prefix(completedBatchCount).enumerated().map {
                HouseholdZoneRecoveryCompletedBatch(index: $0.offset, digest: $0.element)
            },
            status: complete ? .complete : .inProgress,
            completedAt: complete ? Date(timeIntervalSince1970: 1_000) : nil)
    }

    private func makeViewModel(
        available: Bool = true,
        snapshot: HouseholdZoneRecoveryAuthoritySnapshot? = nil,
        authorityIsCurrent: @escaping HouseholdZoneRecoveryViewModel.AuthorityValidator = { _ in true },
        analyze: @escaping HouseholdZoneRecoveryViewModel.AnalysisProvider,
        store: RecordingStore = RecordingStore(),
        parkNormalSession: HouseholdZoneRecoveryViewModel.ParkNormalSession? = nil,
        prepareApply: HouseholdZoneRecoveryViewModel.ApplyPreparationProvider? = nil
    ) -> (HouseholdZoneRecoveryViewModel, RecordingStore) {
        let snapshot = snapshot ?? self.snapshot()
        return (
            HouseholdZoneRecoveryViewModel(
                isRecoveryAvailable: { available },
                authoritySnapshot: { snapshot },
                authorityIsCurrent: authorityIsCurrent,
                analyze: analyze,
                manifestStore: store,
                parkNormalSession: parkNormalSession,
                prepareApply: prepareApply),
            store)
    }


    private func waitUntilSettled(_ viewModel: HouseholdZoneRecoveryViewModel) async {
        while case .analyzing = viewModel.state {
            await Task.yield()
        }
    }
    private func waitUntilApplySettled(_ viewModel: HouseholdZoneRecoveryViewModel) async {
        while viewModel.applyIsRunning {
            await Task.yield()
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

    @Test("apply is unavailable outside debug or TestFlight and never parks normal sync")
    func applyGateFailsClosed() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        var parkCalls = 0
        let (viewModel, _) = makeViewModel(
            available: false,
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in
                parkCalls += 1
                return RecordingApplyBoundary(snapshot: self.snapshot())
            },
            prepareApply: { _, _, _ in
                Issue.record("Apply preparation must not run outside debug/TestFlight")
                return RecordingApplyOperation(totalBatchCount: 0, results: [])
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)

        #expect(viewModel.storedApprovalDigest == nil)
        #expect(viewModel.canRequestApplyConfirmation == false)
        #expect(parkCalls == 0)
        #expect(viewModel.applyFailureMessage == "Recovery apply is unavailable in this build.")
    }

    @Test("exact stored digest and destructive second confirmation are both required")
    func exactDigestAndSecondConfirmationGateApply() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        let boundary = RecordingApplyBoundary(snapshot: snapshot())
        let operation = RecordingApplyOperation(
            totalBatchCount: 0,
            results: [.verifiedCompletion(try receipt(
                completedBatchCount: 0,
                totalBatchCount: 0,
                complete: true))])
        var parkCalls = 0
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in
                parkCalls += 1
                return boundary
            },
            prepareApply: { stored, _, _ in
                #expect(stored == artifact)
                return operation
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = "wrong-digest"
        viewModel.requestApplyConfirmation()
        #expect(viewModel.canRequestApplyConfirmation == false)
        #expect(parkCalls == 0)

        viewModel.typedDigestConfirmation = artifact.digest
        #expect(viewModel.canRequestApplyConfirmation)
        viewModel.requestApplyConfirmation()
        #expect(viewModel.applyState == .awaitingDestructiveConfirmation)
        #expect(parkCalls == 0)
        #expect(viewModel.destructiveConfirmationMessage.contains("source"))
        #expect(viewModel.destructiveConfirmationMessage.contains("preserved"))

        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)

        #expect(parkCalls == 1)
        #expect(operation.maximumBatchCounts == [1])
        #expect(boundary.unparkCount == 1)
        #expect(viewModel.applyState == .verifiedCompletion(
            completedBatchCount: 0,
            totalBatchCount: 0))
    }

    @Test("authority or epoch change after confirmation stops before parking")
    func authorityChangeAfterConfirmationStopsApply() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        let currentSnapshot = SnapshotBox(snapshot(epoch: 41))
        var parkCalls = 0
        let viewModel = HouseholdZoneRecoveryViewModel(
            isRecoveryAvailable: { true },
            authoritySnapshot: { currentSnapshot.value },
            authorityIsCurrent: { $0.sessionEpoch == currentSnapshot.value.sessionEpoch },
            analyze: { _, _, _ in self.analysis(approved) },
            manifestStore: store,
            parkNormalSession: { _ in
                parkCalls += 1
                return RecordingApplyBoundary(snapshot: currentSnapshot.value)
            },
            prepareApply: { _, _, _ in
                Issue.record("Apply must not prepare after an epoch change")
                return RecordingApplyOperation(totalBatchCount: 0, results: [])
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        currentSnapshot.value = snapshot(epoch: 42)
        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)

        #expect(parkCalls == 0)
        #expect(viewModel.applyFailureMessage == "The household session changed before recovery apply.")
    }

    @Test("analysis and review decisions cannot mutate approval while apply is running")
    func applyLocksAnalysisAndReviewControls() async throws {
        let conflictIdentity = identity("approved-conflict")
        let provenanceIdentity = identity("approved-provenance")
        let approved = try manifest(
            entries: [
                HouseholdZoneRecoveryEntry(
                    identity: conflictIdentity,
                    action: .conflict,
                    decision: .source),
            ],
            unresolved: [
                HouseholdZoneRecoveryUnresolvedEntry(
                    entry: HouseholdZoneRecoveryEntry(
                        identity: provenanceIdentity,
                        action: .copy),
                    decision: .include),
            ])
        let store = RecordingStore()
        let boundary = RecordingApplyBoundary(snapshot: snapshot())
        let operation = SuspendingApplyOperation(result: .progress(try receipt(
            completedBatchCount: 0,
            totalBatchCount: 1)))
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in boundary },
            prepareApply: { _, _, _ in operation })

        viewModel.analyze()
        await waitUntilSettled(viewModel)
        let digest = try #require(viewModel.storedApprovalDigest)
        viewModel.typedDigestConfirmation = digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        for await _ in operation.started.stream.prefix(1) { break }

        let applyingState = viewModel.applyState
        let storedArtifact = store.storedArtifact
        let approvalAuthority = viewModel.storedApprovalAuthority
        viewModel.decideConflict(conflictIdentity, decision: .target)
        viewModel.decideProvenance(provenanceIdentity, decision: .exclude)
        viewModel.decideAllProvenance(.exclude)
        viewModel.analyze()

        #expect(viewModel.applyState == applyingState)
        #expect(viewModel.storedApprovalDigest == digest)
        #expect(store.storedArtifact == storedArtifact)
        #expect(viewModel.storedApprovalAuthority == approvalAuthority)
        #expect(viewModel.preview?.authority == approvalAuthority)

        viewModel.cancelApply()
        await waitUntilApplySettled(viewModel)

        #expect(viewModel.applyState == .resumableStop(
            completedBatchCount: 0,
            totalBatchCount: 1))
        #expect(store.storedArtifact == storedArtifact)
        #expect(boundary.unparkCount == 1)
    }

    @Test("cancelling apply stops resumably and unparks normal sync")
    func applyCancellationIsResumable() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        let boundary = RecordingApplyBoundary(snapshot: snapshot())
        let operation = SuspendingApplyOperation(result: .progress(try receipt(
            completedBatchCount: 0,
            totalBatchCount: 1)))
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in boundary },
            prepareApply: { _, _, _ in operation })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        for await _ in operation.started.stream.prefix(1) { break }
        viewModel.cancelApply()
        await waitUntilApplySettled(viewModel)

        #expect(viewModel.applyState == .resumableStop(
            completedBatchCount: 0,
            totalBatchCount: 1))
        #expect(boundary.unparkCount == 1)
    }

    @Test("apply advances one bounded batch at a time and reports verified completion")
    func boundedProgressAndSuccess() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        let boundary = RecordingApplyBoundary(snapshot: snapshot())
        let operation = RecordingApplyOperation(
            totalBatchCount: 2,
            results: [
                .progress(try receipt(completedBatchCount: 1, totalBatchCount: 2)),
                .verifiedCompletion(try receipt(
                    completedBatchCount: 2,
                    totalBatchCount: 2,
                    complete: true)),
            ])
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in boundary },
            prepareApply: { _, _, _ in operation })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)

        #expect(operation.maximumBatchCounts == [1, 1])
        #expect(viewModel.applyState == .verifiedCompletion(
            completedBatchCount: 2,
            totalBatchCount: 2))
        #expect(boundary.unparkCount == 1)
    }

    @Test("transient stop stays resumable and is never retried automatically")
    func transientStopDoesNotRetry() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        let boundary = RecordingApplyBoundary(snapshot: snapshot())
        let operation = RecordingApplyOperation(
            totalBatchCount: 2,
            results: [.resumableStop(
                try receipt(completedBatchCount: 1, totalBatchCount: 2),
                .transientTransport)])
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in boundary },
            prepareApply: { _, _, _ in operation })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)
        await Task.yield()

        #expect(operation.maximumBatchCounts == [1])
        #expect(viewModel.applyState == .resumableStop(
            completedBatchCount: 1,
            totalBatchCount: 2))
    }

    @Test("conflict identity remains local and stops without retry")
    func conflictStopsWithLocalIdentity() async throws {
        let approvedIdentity = identity("local-conflict-record")
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: approvedIdentity, action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        let boundary = RecordingApplyBoundary(snapshot: snapshot())
        let operation = RecordingApplyOperation(
            totalBatchCount: 1,
            results: [.conflict(nil, approvedIdentity)])
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in boundary },
            prepareApply: { _, _, _ in operation })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)

        #expect(operation.maximumBatchCounts == [1])
        #expect(viewModel.applyState == .conflict(
            completedBatchCount: 0,
            totalBatchCount: 1))
        #expect(viewModel.localConflictIdentity == approvedIdentity)
        #expect(viewModel.applyStatusMessage == "Recovery stopped because target data changed.")
        #expect(!viewModel.applyStatusMessage.contains("local-conflict-record"))
    }

    @Test("a changed stored manifest is not retried under the confirmed digest")
    func changedStoredManifestInvalidatesConfirmation() async throws {
        let approved = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("approved-record"), action: .copy),
        ])
        let changed = try manifest(entries: [
            HouseholdZoneRecoveryEntry(identity: identity("different-record"), action: .copy),
        ])
        let store = RecordingStore()
        let artifact = try store.save(approved)
        var parkCalls = 0
        let (viewModel, _) = makeViewModel(
            analyze: { _, _, _ in self.analysis(approved) },
            store: store,
            parkNormalSession: { _ in
                parkCalls += 1
                return RecordingApplyBoundary(snapshot: self.snapshot())
            },
            prepareApply: { _, _, _ in
                Issue.record("Changed manifest must not prepare")
                return RecordingApplyOperation(totalBatchCount: 0, results: [])
            })

        await viewModel.loadStoredApproval()
        viewModel.typedDigestConfirmation = artifact.digest
        viewModel.requestApplyConfirmation()
        _ = try store.save(changed)
        viewModel.confirmApply()
        await waitUntilApplySettled(viewModel)

        #expect(parkCalls == 0)
        #expect(viewModel.applyFailureMessage == "The approved recovery manifest changed. Review it again.")
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
}
