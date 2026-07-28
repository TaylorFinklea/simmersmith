import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdSync
import Observation
import SimmerSmithKit
import Testing

@testable import SimmerSmith

/// Covers the AppState-side half of the household-zone-recovery apply survival fix:
///
/// 1. Parking for recovery must never let SwiftUI observe `householdLaunchPhase` leave
///    `.ready` (that phase gates `RootView`'s entire `MainTabView` tree, so a transient
///    `.resolving` tears down the very Settings sheet hosting the recovery screen) while
///    still doing every other teardown effect `beginEpochFirstHouseholdTransition` always did.
/// 2. `evaluatePendingReleaseNotes()` must be inert while a recovery boundary is parked, and
///    work again once it unparks.
/// 3. The apply run itself must live on `AppState`, not on any view or view model, so it keeps
///    advancing after whatever started it discards its reference; only an explicit cancel may
///    stop it, and unparking runs exactly once.
/// 4. Starting an apply must be refused without a matching confirmed digest or a currently
///    recognized authority — the "normal launch never has these" gate.
/// 5. The batch loop's result handling must never retry or resume automatically: a resumable
///    stop, a conflict, and a preflight rejection each halt after exactly one
///    `apply(maximumBatchCount: 1)` call, and a capacity-unsatisfiable preparation reports its
///    own named failure and still unparks.
@MainActor
@Suite(.serialized)
struct HouseholdZoneRecoveryAppStateTests {

    // MARK: - Fixtures

    private func lifecycleDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hzr-appstate-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func manifestDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hzr-appstate-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeAppState() throws -> AppState {
        AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false,
            householdLifecycleDirectoryURL: try lifecycleDirectory())
    }

    private func lifecycleExecutor(
        currentAccountRecordName: @escaping @MainActor () async throws -> String?
    ) -> HouseholdLifecycleExecutor {
        HouseholdLifecycleExecutor(
            currentAccountRecordName: currentAccountRecordName,
            requestRootClear: { _ in },
            completeRootClear: { _ in },
            requestScopeClear: { _, _ in },
            completeScopeClear: { _, _ in },
            clearRoleEngineStateFiles: { _ in },
            deleteAllHouseholdZones: { _ in [] })
    }

    /// A parkable owner session: `HouseholdSession`'s throwing initializer installs
    /// `initialMirrorScope` directly into the engine, so `activeMirrorScopeSnapshot` matches
    /// `targetScope` without a real CloudKit bootstrap round trip.
    private func makeOwnerSession(
        householdID: String,
        accountRecordName: String
    ) throws -> HouseholdSession {
        let targetScope = MirrorScope(
            accountRecordName: accountRecordName,
            zoneOwnerName: CKCurrentUserDefaultName,
            zoneName: HouseholdZoneProvisioner.zoneName(householdID: householdID),
            householdID: householdID,
            role: .owner,
            databaseScope: .private)
        return try HouseholdSession(
            householdID: householdID,
            role: .owner,
            initialMirrorScope: targetScope)
    }

    private enum FixtureError: Error {
        case authorityNotPromoted
    }

    /// A fully wired `AppState` with a live, owner, currently-authoritative session whose
    /// `householdZoneRecoveryAuthoritySnapshot()` succeeds, plus a matching stored approval
    /// artifact — everything `startHouseholdZoneRecoveryApply` needs, without touching real
    /// CloudKit.
    private func recoveryApplyFixture() async throws -> (
        state: AppState,
        authority: HouseholdZoneRecoveryAuthoritySnapshot,
        artifact: HouseholdZoneRecoveryStoredArtifact
    ) {
        let state = try makeAppState()
        let householdID = "hzr-apply-\(UUID().uuidString)"
        let accountRecordName = "hzr-apply-account-\(UUID().uuidString)"
        let session = try makeOwnerSession(
            householdID: householdID,
            accountRecordName: accountRecordName)
        guard session.promoteCachedAuthority() else {
            throw FixtureError.authorityNotPromoted
        }
        state.householdSession = session
        state.householdLifecycleExecutor = lifecycleExecutor { accountRecordName }

        let authority = try await state.householdZoneRecoveryAuthoritySnapshot()
        let manifest = try HouseholdZoneRecoveryManifest(
            accountFingerprint: authority.accountFingerprint,
            sourceScope: authority.sourceScope,
            targetScope: authority.targetScope,
            sourceInputFingerprint: "source-fingerprint",
            targetInputFingerprint: "target-fingerprint",
            entries: [],
            exclusions: [])
        let manifestStore = HouseholdZoneRecoveryManifestStore(directory: try manifestDirectory())
        let artifact = try manifestStore.save(manifest)
        return (state, authority, artifact)
    }

    private func receipt(
        authority: HouseholdZoneRecoveryAuthoritySnapshot,
        completedBatchCount: Int,
        totalBatchCount: Int,
        complete: Bool = false
    ) throws -> HouseholdZoneRecoveryReceipt {
        let batchDigests = (0..<totalBatchCount).map { "batch-\($0)" }
        return try HouseholdZoneRecoveryReceipt(
            manifestDigest: "manifest-digest",
            sourceInputFingerprint: "source-fingerprint",
            initialTargetInputFingerprint: "target-fingerprint",
            targetZoneOwnerName: authority.targetScope.zoneOwnerName,
            targetZoneName: authority.targetScope.zoneName,
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

    /// Scripted fake standing in for `HouseholdZoneRecoveryProductionApplyOperation` — hands
    /// back queued results one bounded batch at a time, exactly like the real applier.
    private final class ScriptedApplyOperation: HouseholdZoneRecoveryApplying {
        let totalBatchCount: Int
        private(set) var maximumBatchCounts: [Int] = []
        private var results: [HouseholdZoneRecoveryApplyResult]

        init(totalBatchCount: Int, results: [HouseholdZoneRecoveryApplyResult]) {
            self.totalBatchCount = totalBatchCount
            self.results = results
        }

        func apply(maximumBatchCount: Int) async -> HouseholdZoneRecoveryApplyResult {
            maximumBatchCounts.append(maximumBatchCount)
            return results.removeFirst()
        }
    }

    /// Suspends inside `apply(maximumBatchCount:)` until cancelled, then returns immediately —
    /// `Task.sleep` throws the instant the driving Task is cancelled. Mirrors the same
    /// technique `HouseholdZoneRecoveryViewModelTests` uses for its cancellation coverage.
    private final class SuspendingApplyOperation: HouseholdZoneRecoveryApplying {
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

    private struct WaitTimedOut: Error {}

    /// Polls a MainActor condition until it holds or the timeout elapses. Every assertion below
    /// that depends on the AppState-owned apply `Task` making progress uses this instead of a
    /// fixed delay — the drive loop's exact interleaving with the polling Task is not something
    /// a test should assume.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw WaitTimedOut() }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 1. Parking never publishes `.resolving`

    @Test("beginEpochFirstHouseholdTransition preserves .ready when asked, while still tearing everything else down")
    func preservingLaunchPhaseSkipsTheResolvingPublish() throws {
        let state = try makeAppState()
        let session = try makeOwnerSession(
            householdID: "phase-pin-\(UUID().uuidString)",
            accountRecordName: "phase-pin-account")
        state.householdSession = session
        state.recipeRepository = RecipeRepository(session: session)
        state.householdLaunchPhase = .ready
        let epochBefore = state.sessionBootEpoch

        let parked = state.beginEpochFirstHouseholdTransition(
            clearPersonalData: false,
            preservingLaunchPhase: true)

        #expect(parked)
        #expect(state.householdLaunchPhase == .ready)
        #expect(state.sessionBootEpoch == epochBefore + 1)
        #expect(state.householdSession == nil)
        #expect(state.recipeRepository == nil)
    }

    @Test("beginEpochFirstHouseholdTransition still publishes .resolving for every other caller")
    func defaultCallersStillPublishResolving() throws {
        let state = try makeAppState()
        state.householdLaunchPhase = .ready

        state.beginEpochFirstHouseholdTransition(clearPersonalData: false)

        #expect(state.householdLaunchPhase == .resolving)
    }

    @Test("parkNormalSessionForHouseholdZoneRecovery keeps householdLaunchPhase at .ready and detaches the normal session")
    func parkingKeepsLaunchPhaseReady() async throws {
        let (state, authority, _) = try await recoveryApplyFixture()
        state.householdLaunchPhase = .ready
        let sessionBefore = state.householdSession
        let epochBefore = state.sessionBootEpoch

        let boundary = try await state.parkNormalSessionForHouseholdZoneRecovery(authority)

        #expect(state.householdLaunchPhase == .ready)
        #expect(state.householdSession == nil)
        #expect(sessionBefore != nil)
        #expect(state.sessionBootEpoch == epochBefore + 1)
        #expect(state.activeHouseholdZoneRecoveryBoundary != nil)
        #expect(await boundary.normalSessionIsParked())
    }

    // MARK: - 2. Release notes suppressed while a recovery boundary is active

    @Test("evaluatePendingReleaseNotes is inert while a recovery boundary is parked, and writes work again after unpark")
    func releaseNotesSuppressedDuringRecoveryBoundary() throws {
        let state = try makeAppState()
        let boundary = HouseholdZoneRecoveryAppSessionBoundary(
            appState: state,
            snapshot: HouseholdZoneRecoveryAuthoritySnapshot(
                accountFingerprint: "fingerprint",
                sourceScope: MirrorScope(
                    accountRecordName: "account",
                    zoneOwnerName: CKCurrentUserDefaultName,
                    zoneName: HouseholdZoneRecoveryManifest.reservedSourceZoneName,
                    householdID: "spc-recipe-test",
                    role: .owner,
                    databaseScope: .private),
                targetScope: MirrorScope(
                    accountRecordName: "account",
                    zoneOwnerName: CKCurrentUserDefaultName,
                    zoneName: "household-release-notes-test",
                    householdID: "release-notes-test",
                    role: .owner,
                    databaseScope: .private),
                sessionEpoch: 0))
        state.activeHouseholdZoneRecoveryBoundary = boundary

        // A direct write is refused outright while the boundary is active — deterministic
        // regardless of what real ReleaseNotesStore/catalog data this test host happens to have.
        state.pendingReleaseNotes = ReleaseNotesPresentation(notes: [], previousNotes: [])
        #expect(state.pendingReleaseNotes == nil)

        // Whatever evaluatePendingReleaseNotes() would have decided from real device state, the
        // guarded setter means it can never publish while the boundary is active.
        state.evaluatePendingReleaseNotes()
        #expect(state.pendingReleaseNotes == nil)

        state.activeHouseholdZoneRecoveryBoundary = nil
        state.pendingReleaseNotes = ReleaseNotesPresentation(notes: [], previousNotes: [])
        #expect(state.pendingReleaseNotes != nil)
    }

    // MARK: - 3. The apply run lives on AppState, not on any view

    @Test("an apply run keeps advancing after every local reference to it is discarded, and reaches verified completion unparked")
    func applyRunSurvivesSimulatedViewTeardown() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        let operation = ScriptedApplyOperation(
            totalBatchCount: 2,
            results: [
                .progress(try receipt(authority: authority, completedBatchCount: 1, totalBatchCount: 2)),
                .verifiedCompletion(try receipt(
                    authority: authority,
                    completedBatchCount: 2,
                    totalBatchCount: 2,
                    complete: true)),
            ])
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in operation }

        // Start the run the way a view would, then behave exactly like a torn-down view: never
        // touch the returned handle again. Only AppState's own published state is read below —
        // proving the driving Task belongs to AppState, not to this (now-discarded) caller.
        do {
            let started = state.startHouseholdZoneRecoveryApply(
                artifact: artifact,
                confirmedDigest: artifact.digest,
                authority: authority)
            #expect(started != nil)
        }

        try await waitUntil {
            state.activeHouseholdZoneRecoveryApplyRun?.state == .verifiedCompletion(
                completedBatchCount: 2,
                totalBatchCount: 2)
        }
        #expect(operation.maximumBatchCounts == [1, 1])

        // Unparking follows once the run finishes, with nobody having called cancel.
        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    @Test("only an explicit cancel stops a running apply, and it stops resumably with the boundary unparked")
    func explicitCancelStopsApplyResumably() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        // A stagnant .progress receipt (0 completed, matching the starting count) so the result
        // itself — not a race against the loop's own cancellation check — is what settles
        // .resumableStop once Task.sleep is interrupted by cancel().
        let operation = SuspendingApplyOperation(
            result: .progress(try receipt(authority: authority, completedBatchCount: 0, totalBatchCount: 1)))
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in operation }

        let run = state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority)
        #expect(run != nil)

        for await _ in operation.started.stream.prefix(1) { break }
        state.cancelHouseholdZoneRecoveryApply()

        try await waitUntil {
            state.activeHouseholdZoneRecoveryApplyRun?.state == .resumableStop(
                completedBatchCount: 0,
                totalBatchCount: 1)
        }
        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    // MARK: - 4. Apply cannot start without a live authority or a matching confirmed digest

    @Test("startHouseholdZoneRecoveryApply refuses to start on a normal launch with no recognized authority")
    func cannotStartWithoutARecognizedAuthority() throws {
        let state = try makeAppState()
        // No householdSession at all — exactly a normal launch that never reached a parked,
        // approved recovery state.
        let bogusAuthority = HouseholdZoneRecoveryAuthoritySnapshot(
            accountFingerprint: "fingerprint",
            sourceScope: MirrorScope(
                accountRecordName: "account",
                zoneOwnerName: CKCurrentUserDefaultName,
                zoneName: HouseholdZoneRecoveryManifest.reservedSourceZoneName,
                householdID: "spc-recipe-test",
                role: .owner,
                databaseScope: .private),
            targetScope: MirrorScope(
                accountRecordName: "account",
                zoneOwnerName: CKCurrentUserDefaultName,
                zoneName: "household-normal-launch-test",
                householdID: "normal-launch-test",
                role: .owner,
                databaseScope: .private),
            sessionEpoch: 0)
        let manifest = try HouseholdZoneRecoveryManifest(
            accountFingerprint: bogusAuthority.accountFingerprint,
            sourceScope: bogusAuthority.sourceScope,
            targetScope: bogusAuthority.targetScope,
            sourceInputFingerprint: "source-fingerprint",
            targetInputFingerprint: "target-fingerprint",
            entries: [],
            exclusions: [])
        let artifact = try HouseholdZoneRecoveryStoredArtifact(
            canonicalManifestBytes: manifest.canonicalJSONBytes(),
            digest: manifest.digest())

        let run = state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: bogusAuthority)

        #expect(run == nil)
        #expect(state.activeHouseholdZoneRecoveryApplyRun == nil)
        #expect(state.activeHouseholdZoneRecoveryBoundary == nil)
    }

    @Test("startHouseholdZoneRecoveryApply refuses to start without the exact confirmed digest")
    func cannotStartWithAMismatchedDigest() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()

        let run = state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: "not-\(artifact.digest)",
            authority: authority)

        #expect(run == nil)
        #expect(state.activeHouseholdZoneRecoveryApplyRun == nil)
        #expect(state.householdSession != nil, "a rejected start must not touch the live session")
    }

    @Test("startHouseholdZoneRecoveryApply refuses to start once the authority is stale")
    func cannotStartWithAStaleAuthority() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        // Simulate the session having moved on since the caller captured `authority` (e.g. a
        // sign-out/sign-in race) — the epoch AppState tracks no longer matches.
        state.sessionBootEpoch += 1

        let run = state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority)

        #expect(run == nil)
        #expect(state.activeHouseholdZoneRecoveryApplyRun == nil)
    }

    // MARK: - 5. Batch loop result handling: no automatic retry, no automatic resume

    @Test("a resumable stop halts the loop after exactly one batch, publishes the receipt's counts, and unparks")
    func resumableStopHaltsAfterOneCallAndUnparks() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        let diagnostic = HouseholdZoneRecoveryApplyDiagnostic(
            category: .networkUnavailable, batchIndex: 1, batchRecordCount: 9)
        let operation = ScriptedApplyOperation(
            totalBatchCount: 3,
            results: [
                .resumableStop(
                    try receipt(authority: authority, completedBatchCount: 1, totalBatchCount: 3),
                    .transientTransport,
                    diagnostic),
            ])
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in operation }

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        try await waitUntil {
            run.state == .resumableStop(completedBatchCount: 1, totalBatchCount: 3)
        }
        // Only one queued result: a second `apply(maximumBatchCount:)` call would crash on
        // `results.removeFirst()` of an empty array, so reaching here at all already proves no
        // automatic retry happened. Assert the call count explicitly too.
        #expect(operation.maximumBatchCounts == [1])

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    @Test("a conflict halts the loop after exactly one batch, publishes the conflict identity, and unparks")
    func conflictHaltsAfterOneCallAndPublishesIdentity() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        let conflictIdentity = HouseholdZoneRecoveryIdentity(
            source: MirrorRecordIdentity(
                recordType: "Recipe",
                recordName: "conflict-record",
                zoneOwnerName: authority.sourceScope.zoneOwnerName,
                zoneName: authority.sourceScope.zoneName),
            targetScope: authority.targetScope)
        let diagnostic = HouseholdZoneRecoveryApplyDiagnostic(
            category: .serverRecordChanged, batchIndex: 0, batchRecordCount: 4)
        let operation = ScriptedApplyOperation(
            totalBatchCount: 2,
            results: [
                .conflict(
                    try receipt(authority: authority, completedBatchCount: 0, totalBatchCount: 2),
                    conflictIdentity,
                    diagnostic),
            ])
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in operation }

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        try await waitUntil {
            run.state == .conflict(completedBatchCount: 0, totalBatchCount: 2)
        }
        #expect(operation.maximumBatchCounts == [1])
        #expect(run.localConflictIdentity == conflictIdentity)

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    @Test("a preflight rejection halts the loop after one batch and publishes a failure whose message and counts show how far the run got")
    func preflightRejectedHaltsWithDiagnosticClauseAndCounts() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        let diagnostic = HouseholdZoneRecoveryApplyDiagnostic(
            category: .limitExceeded, batchIndex: 2, batchRecordCount: 17)
        let operation = ScriptedApplyOperation(
            totalBatchCount: 3,
            results: [
                .preflightRejected(.invalidReceipt, diagnostic),
            ])
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in operation }

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        try await waitUntil {
            if case .failed = run.state { return true }
            return false
        }
        #expect(operation.maximumBatchCounts == [1])

        guard case .failed(let message, let completedBatchCount, let totalBatchCount) = run.state else {
            Issue.record("expected .failed, got \(run.state)")
            return
        }
        #expect(message.contains("limitExceeded"))
        #expect(message.contains("batch 2"))
        #expect(message.contains("17 records"))
        // No batch ever completed before the preflight rejection; total reflects what the
        // preparation reported.
        #expect(completedBatchCount == 0)
        #expect(totalBatchCount == 3)

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    @Test("a preparation that reports batchCapacityUnsatisfiable publishes its own named failure and always unparks")
    func batchCapacityUnsatisfiablePreparationNamesFailureAndUnparks() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in
            throw HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable
        }

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        try await waitUntil {
            if case .failed = run.state { return true }
            return false
        }
        guard case .failed(let message, let completedBatchCount, let totalBatchCount) = run.state else {
            Issue.record("expected .failed, got \(run.state)")
            return
        }
        #expect(message.contains("batchCapacityUnsatisfiable"))
        #expect(completedBatchCount == 0)
        #expect(totalBatchCount == 0)
        #expect(run.diagnostic?.category == .limitExceeded)

        // The app must never be left permanently parked, even on this early-failing path.
        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    // MARK: - 6. Preparation-phase failures publish a diagnostic before their terminal state
    // (Finding 1). Every preparation-phase catch must classify its failure into the same
    // privacy-safe diagnostic-category vocabulary the batch loop already uses, and must do so
    // strictly *before* publishing the terminal `.failed` state — a tracking observer that
    // wakes on the state change must never see a `nil`/stale diagnostic for what turns out to
    // be a real, distinguishable failure.

    @Test("invalidAuthority publishes the authorityChanged diagnostic before failing and unparks")
    func invalidAuthorityPublishesAuthorityChangedDiagnosticAndUnparks() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()

        // Starts against the fixture's genuinely-current authority (passes
        // `startHouseholdZoneRecoveryApply`'s own recheck), then swaps the live session for a
        // different household before the driving Task gets a chance to run (MainActor is
        // serial, and nothing here awaits yet) — so the *internal* recheck inside
        // `driveHouseholdZoneRecoveryApply` observes a live authority that no longer matches
        // the captured snapshot, distinct from the earlier "stale epoch" refusal at start time.
        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        let otherSession = try makeOwnerSession(
            householdID: "hzr-apply-other-\(UUID().uuidString)",
            accountRecordName: "hzr-apply-other-account-\(UUID().uuidString)")
        guard otherSession.promoteCachedAuthority() else {
            throw FixtureError.authorityNotPromoted
        }
        state.householdSession = otherSession

        try await waitUntil {
            if case .failed = run.state { return true }
            return false
        }
        #expect(run.diagnostic?.category == .authorityChanged)

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    @Test("invalidStoredArtifact publishes a distinct diagnostic before failing and unparks")
    func invalidStoredArtifactPublishesDiagnosticAndUnparks() async throws {
        let (state, authority, _) = try await recoveryApplyFixture()
        // A self-consistent artifact — its digest matches its own bytes, so it clears the
        // digest recheck — whose decoded manifest nonetheless carries an account fingerprint
        // the live authority never had. Exercises the manifest/authority-scope mismatch branch
        // of `invalidStoredArtifact`, distinct from a mismatched `confirmedDigest`.
        let staleManifest = try HouseholdZoneRecoveryManifest(
            accountFingerprint: "stale-account-fingerprint",
            sourceScope: authority.sourceScope,
            targetScope: authority.targetScope,
            sourceInputFingerprint: "source-fingerprint",
            targetInputFingerprint: "target-fingerprint",
            entries: [],
            exclusions: [])
        let manifestStore = HouseholdZoneRecoveryManifestStore(directory: try manifestDirectory())
        let staleArtifact = try manifestStore.save(staleManifest)

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: staleArtifact,
            confirmedDigest: staleArtifact.digest,
            authority: authority))

        try await waitUntil {
            if case .failed = run.state { return true }
            return false
        }
        #expect(run.diagnostic?.category == .manifestRejected)

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    @Test(
        "the bare catch classifies real CloudKit errors through the existing signal chain, publishing a distinct diagnostic category per CKError family, and unparks",
        arguments: [
            (CKError.Code.zoneNotFound, HouseholdZoneRecoveryApplyDiagnosticCategory.zoneNotFound),
            (CKError.Code.quotaExceeded, HouseholdZoneRecoveryApplyDiagnosticCategory.quotaExceeded),
            (CKError.Code.networkUnavailable, HouseholdZoneRecoveryApplyDiagnosticCategory.networkUnavailable),
        ])
    func bareCatchClassifiesCloudKitErrorFamilies(
        code: CKError.Code,
        expectedCategory: HouseholdZoneRecoveryApplyDiagnosticCategory
    ) async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in
            throw CKError(code)
        }

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        try await waitUntil {
            if case .failed = run.state { return true }
            return false
        }
        #expect(run.diagnostic?.category == expectedCategory)

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }

    /// Two-state capture (rather than a bare `Category??`) so the assertion below reads as an
    /// explicit "was this ever observed, and with what" rather than a nested-optional literal.
    private enum TerminalDiagnosticObservation: Equatable {
        case notYetObserved
        case observed(HouseholdZoneRecoveryApplyDiagnosticCategory?)
    }

    /// Captures `run.diagnostic` synchronously *inside* the `withObservationTracking`
    /// `onChange` callback registered against `run.state` — i.e. at the moment the state
    /// mutation the callback reports is under way, not after this test's own polling notices
    /// it settled. `state` and `diagnostic` are both `@MainActor`-isolated; `onChange`'s type
    /// is `@Sendable () -> Void`, but the mutation that ever triggers it can only happen on
    /// the actor that owns `run`, so `MainActor.assumeIsolated` states a fact here, not an
    /// assumption.
    private final class TerminalStateDiagnosticCapture: @unchecked Sendable {
        private(set) var observation: TerminalDiagnosticObservation = .notYetObserved

        @MainActor
        func observe(_ run: HouseholdZoneRecoveryApplyRun) {
            withObservationTracking {
                _ = run.state
            } onChange: {
                MainActor.assumeIsolated {
                    self.observation = .observed(run.diagnostic?.category)
                }
            }
        }
    }

    @Test("the diagnostic category is already set at the moment the terminal state change is observed, not only afterward")
    func diagnosticPrecedesTerminalStatePublish() async throws {
        let (state, authority, artifact) = try await recoveryApplyFixture()
        state.householdZoneRecoveryApplyPreparation = { _, _, _ in
            throw CKError(.zoneNotFound)
        }

        let run = try #require(state.startHouseholdZoneRecoveryApply(
            artifact: artifact,
            confirmedDigest: artifact.digest,
            authority: authority))

        // Registered before the driving Task's first await, so this starts watching
        // `run.state` from its initial `.preparing` value — for a preparation-phase failure,
        // the first (and only) change it will ever see is the terminal `.failed` publish.
        let capture = TerminalStateDiagnosticCapture()
        capture.observe(run)

        try await waitUntil {
            if case .failed = run.state { return true }
            return false
        }

        #expect(
            capture.observation == .observed(.zoneNotFound),
            "the diagnostic must already carry its category in the very observation that reveals the terminal state — not only once polling notices it settled afterward")

        try await waitUntil {
            state.activeHouseholdZoneRecoveryBoundary == nil
        }
    }
}
