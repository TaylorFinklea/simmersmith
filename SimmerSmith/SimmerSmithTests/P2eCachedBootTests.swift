import Foundation
import Testing
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import HouseholdSync
#endif
import HouseholdRecords
@testable import SimmerSmith

@MainActor
struct P2eLaunchPolicyTests {
    @Test("developer CloudKit checks visibility is DEBUG or sandbox TestFlight only")
    func cloudKitChecksVisibilityIsReceiptGated() {
        let cases: [(isDebug: Bool, receiptFilename: String?, expected: Bool)] = [
            (true, nil, true),
            (true, "receipt", true),
            (false, "sandboxReceipt", true),
            (false, "receipt", false),
            (false, nil, false),
            (false, "unexpected", false),
        ]

        for testCase in cases {
            #expect(
                DebugGate.resolveShowsCloudKitChecks(
                    isDebug: testCase.isDebug,
                    receiptFilename: testCase.receiptFilename
                ) == testCase.expected
            )
        }
    }

    @Test("shipping default stays off and App Store ignores both local overrides")
    func productionPolicyFailsClosed() {
        #expect(CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: true,
            receipt: .appStore,
            isDebug: false
        ).enabled == false)
        #expect(CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: false,
            receipt: .appStore,
            isDebug: false
        ).enabled == false)
        #expect(CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: true,
            receipt: .unknown,
            isDebug: false
        ).enabled == false)
    }

    @Test("gate-off injection preserves the P1 control decision")
    func gateOffIsInjectableAtAppBoundary() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false)
        #expect(state.cacheFirstLaunchEnabled == false)

        let session = HouseholdSession(householdID: "gate-off-control")
        defer { session.detach() }
        #expect(!session.isCachedBootstrap)
        #expect(!session.isRecoveryOnly)
        #expect(session.store.count() == 0)
        #expect(session.engine.bootstrapGateOutcome == nil)
    }

    @Test("debug and sandbox TestFlight may honor the local override")
    func internalPolicyCanOptIn() {
        #expect(CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: true,
            receipt: .sandbox,
            isDebug: false
        ).enabled)
        #expect(CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: true,
            receipt: .unknown,
            isDebug: true
        ).enabled)
    }
}

struct P2eInterventionCountTests {
    @Test("a rejected cached candidate cannot leak stale intervention state into P1 fallback")
    func rejectedCandidateCountIsDiscarded() {
        #expect(HouseholdSessionInterventionCountPolicy.resolve(
            cachedBootstrapActivated: false,
            cachedCandidateCount: 3,
            recoveryCandidateCount: nil) == 0)
        #expect(HouseholdSessionInterventionCountPolicy.resolve(
            cachedBootstrapActivated: true,
            cachedCandidateCount: 3,
            recoveryCandidateCount: nil) == 3)
        #expect(HouseholdSessionInterventionCountPolicy.resolve(
            cachedBootstrapActivated: false,
            cachedCandidateCount: nil,
            recoveryCandidateCount: 2) == 2)
    }
}

struct P2eForegroundRetryTests {
    @Test("foreground retries only an existing cached session with offline or degraded authority")
    func cachedForegroundRetryDecision() {
        #expect(CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: true,
            authority: .offlineCached(cachedAt: .now)))
        #expect(CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: true,
            authority: .degraded(message: "offline")))
        #expect(!CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: true,
            authority: .reconciling(cachedAt: .now)))
        #expect(!CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: false,
            authority: .offlineCached(cachedAt: .now)))
    }
}

struct P2eSystemOperationPolicyTests {
    @Test("cached sessions deny every P2e absence-derived create-delete system seam")
    func cachedSystemInventoryIsFailClosed() {
        for operation in CachedHouseholdSystemOperation.allCases {
            #expect(!CachedHouseholdSystemOperationPolicy.allows(
                operation, isCachedBootstrap: true))
            #expect(CachedHouseholdSystemOperationPolicy.allows(
                operation, isCachedBootstrap: false))
        }
    }

    @Test("system inventory follows current session authority")
    func systemInventoryRequiresCurrentAuthority() {
        for operation in CachedHouseholdSystemOperation.allCases {
            #expect(CachedHouseholdSystemOperationPolicy.result(
                operation, isAuthoritative: false) == .retryableNotAuthoritative)
            #expect(CachedHouseholdSystemOperationPolicy.result(
                operation, isAuthoritative: true) == .allowed)
            #expect(!CachedHouseholdSystemOperationPolicy.allows(
                operation, isAuthoritative: false))
            #expect(CachedHouseholdSystemOperationPolicy.allows(
                operation, isAuthoritative: true))
        }
    }

    @Test("leftover cleanup revalidates the exact authoritative owner at its destructive seam")
    func cleanupContinuationIsFailClosed() {
        #expect(LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: true,
            isOwner: true,
            hasCurrentAuthority: true))
        #expect(!LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: false,
            isOwner: true,
            hasCurrentAuthority: true))
        #expect(!LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: true,
            isOwner: false,
            hasCurrentAuthority: true))
        #expect(!LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: true,
            isOwner: true,
            hasCurrentAuthority: false))
    }
}

struct P2fDeferredSystemWorkTests {
    @Test("deferred stages run in order and duplicate success skips completed stages")
    func stagesRunOnceInOrder() {
        var plan = DeferredCachedSystemWorkPlan()
        var observed: [DeferredCachedSystemWorkStage] = []

        while let stage = plan.claimNext(isAuthoritative: true) {
            observed.append(stage)
            plan.complete(stage)
        }

        #expect(observed == DeferredCachedSystemWorkStage.allCases)
        #expect(plan.claimNext(isAuthoritative: true) == nil)
    }

    @Test("an interrupted stage resumes before later work and non-authority cannot claim")
    func interruptionResumesWithoutPromotion() {
        var plan = DeferredCachedSystemWorkPlan()
        #expect(plan.claimNext(isAuthoritative: false) == nil)
        let ingredients = plan.claimNext(isAuthoritative: true)
        #expect(ingredients == .ingredientsMigration)
        plan.abandon(.ingredientsMigration)
        #expect(plan.claimNext(isAuthoritative: true) == .ingredientsMigration)
    }

    @Test("a retryable migration keeps its stage until a completed receipt promotes the plan")
    func retryableMigrationDoesNotPromoteLaterWork() {
        var plan = DeferredCachedSystemWorkPlan()
        #expect(plan.claimNext(isAuthoritative: true) == .ingredientsMigration)
        plan.abandon(.ingredientsMigration)
        #expect(plan.claimNext(isAuthoritative: true) == .ingredientsMigration)
        plan.complete(.ingredientsMigration)
        #expect(plan.claimNext(isAuthoritative: true) == .recipesMigration)
    }

    @Test("teardown discards one session plan rather than promoting its progress")
    func teardownDoesNotLeakStageStateToSuccessor() {
        var oldSession = DeferredCachedSystemWorkPlan()
        let first = oldSession.claimNext(isAuthoritative: true)
        #expect(first == .ingredientsMigration)
        oldSession.complete(.ingredientsMigration)
        oldSession.discard()

        var successor = DeferredCachedSystemWorkPlan()
        #expect(successor.claimNext(isAuthoritative: true) == .ingredientsMigration)
    }

    @Test("a retryable owner-current-week claim remains pending for a later authoritative foreground retry")
    func retryableOwnerCurrentWeekDoesNotCompleteTheDeferredPlan() {
        var plan = DeferredCachedSystemWorkPlan()
        #expect(plan.claimNext(isAuthoritative: true) == .ingredientsMigration)
        plan.complete(.ingredientsMigration)
        #expect(plan.claimNext(isAuthoritative: true) == .recipesMigration)
        plan.complete(.recipesMigration)
        #expect(plan.claimNext(isAuthoritative: true) == .ownerCurrentWeek)
        plan.abandon(.ownerCurrentWeek)
        #expect(plan.claimNext(isAuthoritative: true) == .ownerCurrentWeek)
    }

    @Test("a failed direct first fetch cannot continue into migration or repository wiring")
    func deniedDirectBootstrapStopsBeforePostFetchWork() {
        #expect(!DirectHouseholdBootstrapPolicy.shouldContinueAfterInitialStart(
            isCachedBootstrap: false,
            hasCurrentAuthority: false
        ))
        #expect(DirectHouseholdBootstrapPolicy.shouldContinueAfterInitialStart(
            isCachedBootstrap: false,
            hasCurrentAuthority: true
        ))
    }

    @Test("an authoritative foreground retry resumes pending deferred work without another fetch")
    func authoritativeForegroundRetryResumesDeferredWork() {
        #expect(CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: true,
            authority: .current(.now),
            hasPendingDeferredSystemWork: true
        ))
        #expect(CachedHouseholdRetryPlan.next(
            hasCurrentAuthority: true,
            hasPendingDeferredSystemWork: true
        ) == .resumeDeferredSystemWork)
    }
}

private actor P2fSuspensionGate {
    private var hasEntered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        hasEntered = true
        let waiters = entryWaiters
        entryWaiters = []
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { resumeWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !hasEntered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func resume() {
        resumeWaiter?.resume()
        resumeWaiter = nil
    }
}

@MainActor
private func p2fSessionEpochFixture() throws -> (state: AppState, session: HouseholdSession) {
    let state = AppState(
        modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
        cacheFirstLaunchEnabled: false
    )
    let session = HouseholdSession(householdID: "p2f-epoch-\(UUID().uuidString)")
    try #require(session.promoteCachedAuthority())
    state.householdSession = session
    return (state, session)
}

private func p2fWeek(id: String, start: Date, meals: [WeekMeal]) -> WeekSnapshot {
    let end = Calendar(identifier: .iso8601).date(byAdding: .day, value: 7, to: start) ?? start
    return WeekSnapshot(
        weekId: id,
        weekStart: start,
        weekEnd: end,
        status: "staging",
        notes: "",
        readyForAiAt: nil,
        approvedAt: nil,
        pricedAt: nil,
        updatedAt: start,
        stagedChangeCount: 0,
        feedbackCount: 0,
        exportCount: 0,
        meals: meals,
        groceryItems: [],
        nutritionTotals: [],
        weeklyTotals: nil
    )
}

private func p2fMeal() throws -> WeekMeal {
    let data = Data("""
    {
      "mealId": "p2f-carry-over-meal",
      "dayName": "Monday",
      "mealDate": 0,
      "slot": "dinner",
      "recipeName": "Carry-over",
      "scaleMultiplier": 1,
      "source": "user",
      "approved": false,
      "notes": "",
      "aiGenerated": false,
      "updatedAt": 0,
      "ingredients": [],
      "sides": [],
      "macros": null
    }
    """.utf8)
    return try JSONDecoder().decode(WeekMeal.self, from: data)
}

@Suite("P2f live AppState async authority fences", .serialized)
@MainActor
struct P2fAsyncAuthorityFenceTests {
    @Test("current-week creation returns typed denial without stale adoption after its carry-over write suspends")
    @MainActor
    func currentWeekContinuationRejectsAReplacedSessionAfterSuspension() async throws {
        let fixture = try p2fSessionEpochFixture()
        let successor = HouseholdSession(householdID: "p2f-current-week-successor-\(UUID().uuidString)")
        defer {
            fixture.session.detach()
            successor.detach()
        }
        let original = fixture.session
        let state = fixture.state
        let repository = WeekRepository(session: original)
        repository.reload()
        state.weekRepository = repository
        state.groceryRepository = GroceryRepository(session: original)
        let now = Date()
        state.currentWeek = p2fWeek(
            id: "p2f-carried-week",
            start: now,
            meals: [try p2fMeal()]
        )
        let gate = P2fSuspensionGate()
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: { _, _, _, _, _ in
                await gate.suspend()
                return state.currentWeek
            },
            fetchChanges: live.fetchChanges,
            drainChanges: live.drainChanges,
            prepareZoneWideShare: live.prepareZoneWideShare
        )
        let requestEpoch = state.sessionBootEpoch
        let continuation = Task { @MainActor in
            await state.ensureCurrentCloudKitWeek(session: original, requestEpoch: requestEpoch)
        }
        await gate.waitUntilSuspended()

        state.sessionBootEpoch += 1
        state.householdSession = successor
        state.currentWeek = p2fWeek(id: "p2f-successor-week", start: now, meals: [])
        await gate.resume()

        let result = await continuation.value
        #expect(result == .retryableNotAuthoritative)
        #expect(state.currentWeek?.weekId == "p2f-successor-week")
        #expect(state.syncPhase == .idle)
    }

    @Test("backup restore throws typed denial and leaves its reload/sync tail unpublished after fetch suspension")
    @MainActor
    func backupContinuationRejectsTeardownAfterSuspension() async throws {
        let fixture = try p2fSessionEpochFixture()
        defer { fixture.session.detach() }
        let state = fixture.state
        let gate = P2fSuspensionGate()
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: live.saveCurrentWeekCarryOver,
            fetchChanges: { _ in await gate.suspend() },
            drainChanges: { _, _ in },
            prepareZoneWideShare: live.prepareZoneWideShare
        )
        let backup = HouseholdBackup(capturedAt: .now, appBuild: "P2f", role: "owner", records: [])
        let continuation = Task { @MainActor in
            do {
                try await state.restoreHousehold(from: backup)
                return Result<Void, Error>.success(())
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()

        state.sessionBootEpoch += 1
        state.householdSession = nil
        await gate.resume()

        switch await continuation.value {
        case .success:
            Issue.record("stale backup restore reported success")
        case .failure(let error):
            #expect(error as? CachedHouseholdSystemOperationResult == .retryableNotAuthoritative)
        }
        #expect(state.syncPhase == .loading)
        #expect(state.householdSession == nil)
    }

    @Test("owner-share preparation throws typed denial without returning a package after its CloudKit suspension")
    @MainActor
    func ownerShareContinuationRejectsReplacedSessionAfterSuspension() async throws {
        let fixture = try p2fSessionEpochFixture()
        defer { fixture.session.detach() }
        let state = fixture.state
        let gate = P2fSuspensionGate()
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: live.saveCurrentWeekCarryOver,
            fetchChanges: live.fetchChanges,
            drainChanges: live.drainChanges,
            prepareZoneWideShare: { _, _ in
                await gate.suspend()
                return HouseholdSystemOperationExecutor.ZoneWideShare(
                    share: CKShare(recordZoneID: fixture.session.zoneID),
                    container: CKContainer(identifier: "iCloud.app.simmersmith.cloud")
                )
            }
        )
        state.lastErrorMessage = "pre-existing error"
        let continuation = Task { @MainActor in
            do {
                return Result<AppState.OwnerSharePackage?, Error>.success(
                    try await state.prepareOwnerShare(title: "P2f share")
                )
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()

        state.sessionBootEpoch += 1
        state.householdSession = nil
        await gate.resume()

        switch await continuation.value {
        case .success(let package):
            #expect(package == nil)
            Issue.record("stale owner-share preparation returned a package")
        case .failure(let error):
            #expect(error as? CachedHouseholdSystemOperationResult == .retryableNotAuthoritative)
        }
        #expect(state.lastErrorMessage == "pre-existing error")
    }
}

@Suite("P2f pantry-profile import authority fence", .serialized)
@MainActor
struct P2fPantryProfileImportAuthorityTests {
    @Test("a revoked exact session after a suspended pantry fetch cannot write private data, publish stale UI, or clear a successor token")
    func pantryProfileImportRejectsRevokedSessionAfterFetchSuspension() async {
        let gate = P2fSuspensionGate()
        let requestEpoch = 41
        var currentEpoch = requestEpoch
        var sessionMatches = true
        var hasCurrentAuthority = true
        var privateWriteCount = 0
        var receiptWriteCount = 0
        var tokenClearCount = 0
        var importState = "idle"
        var authToken = ""

        let migration = PantryProfileMigrationRunner(
            isCurrentAuthoritative: {
                currentEpoch == requestEpoch && sessionMatches && hasCurrentAuthority
            },
            hasReceipt: { false },
            fetchPantry: {
                await gate.suspend()
                return []
            },
            fetchAliases: { [] },
            fetchProfile: { throw CancellationError() },
            fetchIngredientPreferences: { [] },
            saveHouseholdData: { _, _ in },
            savePrivateData: { _, _, _ in
                privateWriteCount += 1
                return .init(attempted: 0, dropped: 0)
            },
            drainHouseholdData: {},
            stampReceipt: { _ in
                receiptWriteCount += 1
                return true
            }
        )
        let flow = PantryProfileImportFlow(
            isCurrentAuthoritative: {
                currentEpoch == requestEpoch && sessionMatches && hasCurrentAuthority
            },
            prepare: {
                importState = "running"
                authToken = ""
            },
            exchangeToken: { "stale-import-token" },
            saveImportToken: { authToken = $0 },
            migrate: { _ = await migration.run() },
            hasMigrationReceipt: { receiptWriteCount == 1 },
            publishCompletion: { succeeded in
                importState = succeeded ? "done" : "failed"
            },
            publishSignInFailure: { _ in
                importState = "failed"
            },
            clearImportToken: {
                tokenClearCount += 1
                authToken = ""
            },
            reloadImportedData: {}
        )

        let continuation = Task { @MainActor in
            await flow.run()
        }
        await gate.waitUntilSuspended()

        currentEpoch += 1
        sessionMatches = false
        hasCurrentAuthority = false
        importState = "successor import state"
        authToken = "successor-import-token"
        await gate.resume()
        await continuation.value

        #expect(privateWriteCount == 0)
        #expect(receiptWriteCount == 0)
        #expect(importState == "successor import state")
        #expect(authToken == "successor-import-token")
        #expect(tokenClearCount == 0)
    }

    @Test("a rejected household save stops before private writes, drain, and receipt")
    func rejectedHouseholdWriteIsRetryableBeforePrivateData() async {
        var privateWriteCount = 0
        var drainCount = 0
        var receiptWriteCount = 0
        let runner = PantryProfileMigrationRunner(
            isCurrentAuthoritative: { true },
            hasReceipt: { false },
            fetchPantry: { [] },
            fetchAliases: { [] },
            fetchProfile: { throw P2fPantryProfileMigrationTestError.expected },
            fetchIngredientPreferences: { [] },
            saveHouseholdData: { _, _ in throw P2fPantryProfileMigrationTestError.expected },
            savePrivateData: { _, _, _ in
                privateWriteCount += 1
                return .init(attempted: 0, dropped: 0)
            },
            drainHouseholdData: {
                drainCount += 1
            },
            stampReceipt: { _ in
                receiptWriteCount += 1
                return true
            }
        )

        let result = await runner.run()

        guard case .retryable = result else {
            Issue.record("rejected household write was not retryable")
            return
        }
        #expect(privateWriteCount == 0)
        #expect(drainCount == 0)
        #expect(receiptWriteCount == 0)
    }

    @Test("a failed household drain withholds the private receipt after staged private writes")
    func failedDrainIsRetryableAndWithholdsReceipt() async {
        var privateWriteCount = 0
        var receiptWriteCount = 0
        let runner = PantryProfileMigrationRunner(
            isCurrentAuthoritative: { true },
            hasReceipt: { false },
            fetchPantry: { [] },
            fetchAliases: { [] },
            fetchProfile: { throw P2fPantryProfileMigrationTestError.expected },
            fetchIngredientPreferences: { [] },
            saveHouseholdData: { _, _ in },
            savePrivateData: { _, _, _ in
                privateWriteCount += 1
                return .init(attempted: 0, dropped: 0)
            },
            drainHouseholdData: { throw P2fPantryProfileMigrationTestError.expected },
            stampReceipt: { _ in
                receiptWriteCount += 1
                return true
            }
        )

        let result = await runner.run()

        guard case .retryable = result else {
            Issue.record("failed household drain was not retryable")
            return
        }
        #expect(privateWriteCount == 1)
        #expect(receiptWriteCount == 0)
    }
}

private enum P2fPantryProfileMigrationTestError: Error {
    case expected
}

@Suite("P2f Week/Event import authority fences", .serialized)
@MainActor
struct P2fWeekEventImportAuthorityTests {
    @Test("a stale Week Apple sign-in cannot publish successor token or import UI state")
    func weekImportRejectsReplacedSessionAfterSignInSuspension() async {
        let gate = P2fSuspensionGate()
        let requestEpoch = 51
        var currentEpoch = requestEpoch
        var sessionMatches = true
        var hasCurrentAuthority = true
        var importState = "idle"
        var authToken = ""
        var migrationCount = 0
        var tokenClearCount = 0

        let flow = WeekEventImportFlow(
            isCurrentAuthoritative: {
                currentEpoch == requestEpoch && sessionMatches && hasCurrentAuthority
            },
            prepare: {
                importState = "running"
                authToken = ""
            },
            exchangeToken: {
                await gate.suspend()
                return "stale-week-token"
            },
            saveImportToken: { authToken = $0 },
            migrate: {
                migrationCount += 1
                return .complete
            },
            hasMigrationReceipt: { true },
            publishCompletion: { succeeded in
                importState = succeeded ? "done" : "failed"
            },
            publishSignInFailure: { _ in
                importState = "failed"
            },
            clearImportToken: {
                tokenClearCount += 1
                authToken = ""
            },
            reloadImportedData: {}
        )

        let continuation = Task { @MainActor in await flow.run() }
        await gate.waitUntilSuspended()

        currentEpoch += 1
        sessionMatches = false
        hasCurrentAuthority = false
        importState = "successor Week state"
        authToken = "successor-week-token"
        await gate.resume()

        let completion = await continuation.value
        #expect(completion == .retryable)
        #expect(importState == "successor Week state")
        #expect(authToken == "successor-week-token")
        #expect(migrationCount == 0)
        #expect(tokenClearCount == 0)
    }

    @Test("a stale Week Apple sign-in failure cannot publish successor import UI")
    func weekImportRejectsReplacedSessionAfterThrowingSignInSuspension() async {
        let gate = P2fSuspensionGate()
        let requestEpoch = 53
        var currentEpoch = requestEpoch
        var sessionMatches = true
        var hasCurrentAuthority = true
        var importState = "idle"
        var authToken = ""
        var migrationCount = 0

        let flow = WeekEventImportFlow(
            isCurrentAuthoritative: {
                currentEpoch == requestEpoch && sessionMatches && hasCurrentAuthority
            },
            prepare: {
                importState = "running"
                authToken = ""
            },
            exchangeToken: {
                await gate.suspend()
                throw P2fPantryProfileMigrationTestError.expected
            },
            saveImportToken: { authToken = $0 },
            migrate: {
                migrationCount += 1
                return .complete
            },
            hasMigrationReceipt: { true },
            publishCompletion: { succeeded in
                importState = succeeded ? "done" : "failed"
            },
            publishSignInFailure: { _ in
                importState = "failed"
            },
            clearImportToken: { authToken = "" },
            reloadImportedData: {}
        )

        let continuation = Task { @MainActor in await flow.run() }
        await gate.waitUntilSuspended()

        currentEpoch += 1
        sessionMatches = false
        hasCurrentAuthority = false
        importState = "successor Week state"
        authToken = "successor-week-token"
        await gate.resume()

        let completion = await continuation.value
        #expect(completion == .retryable)
        #expect(importState == "successor Week state")
        #expect(authToken == "successor-week-token")
        #expect(migrationCount == 0)
    }

    @Test("a stale Event migration cannot clear a successor token or publish/reload successor UI")
    func eventImportRejectsReplacedSessionAfterMigrationSuspension() async {
        let gate = P2fSuspensionGate()
        let requestEpoch = 52
        var currentEpoch = requestEpoch
        var sessionMatches = true
        var hasCurrentAuthority = true
        var importState = "idle"
        var authToken = ""
        var tokenClearCount = 0
        var reloadCount = 0

        let flow = WeekEventImportFlow(
            isCurrentAuthoritative: {
                currentEpoch == requestEpoch && sessionMatches && hasCurrentAuthority
            },
            prepare: {
                importState = "running"
                authToken = ""
            },
            exchangeToken: { "stale-event-token" },
            saveImportToken: { authToken = $0 },
            migrate: {
                await gate.suspend()
                return .complete
            },
            hasMigrationReceipt: { true },
            publishCompletion: { succeeded in
                importState = succeeded ? "done" : "failed"
            },
            publishSignInFailure: { _ in
                importState = "failed"
            },
            clearImportToken: {
                tokenClearCount += 1
                authToken = ""
            },
            reloadImportedData: { reloadCount += 1 }
        )

        let continuation = Task { @MainActor in await flow.run() }
        await gate.waitUntilSuspended()

        currentEpoch += 1
        sessionMatches = false
        hasCurrentAuthority = false
        importState = "successor Event state"
        authToken = "successor-event-token"
        await gate.resume()

        let completion = await continuation.value
        #expect(completion == .retryable)
        #expect(importState == "successor Event state")
        #expect(authToken == "successor-event-token")
        #expect(tokenClearCount == 0)
        #expect(reloadCount == 0)
    }
}

private struct P2fCoreFix5ExecutorFailure: LocalizedError {
    let operation: String

    var errorDescription: String? { "Injected \(operation) failure" }
}

@Suite("P2f core correction 5 async failure paths", .serialized)
@MainActor
struct P2fCoreFix5AsyncFailureTests {
    @Test("current-week carry-over failure stays retryable and does not replace the in-memory week")
    func currentWeekExecutorFailureDoesNotAdoptPartiallyCreatedWeek() async throws {
        let fixture = try p2fSessionEpochFixture()
        defer { fixture.session.detach() }
        let state = fixture.state
        let repository = WeekRepository(session: fixture.session)
        repository.reload()
        state.weekRepository = repository
        state.groceryRepository = GroceryRepository(session: fixture.session)
        let existingWeek = p2fWeek(
            id: "p2f-core-fix5-existing-week",
            start: Date(),
            meals: [try p2fMeal()]
        )
        state.currentWeek = existingWeek
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: { _, _, _, _, _ in
                throw P2fCoreFix5ExecutorFailure(operation: "current-week carry-over")
            },
            fetchChanges: live.fetchChanges,
            drainChanges: live.drainChanges,
            prepareZoneWideShare: live.prepareZoneWideShare
        )

        let result = await state.ensureCurrentCloudKitWeek(
            session: fixture.session,
            requestEpoch: state.sessionBootEpoch
        )

        #expect(result == .retryableNotAuthoritative)
        #expect(state.currentWeek?.weekId == existingWeek.weekId)
    }

    @Test("current-week nil carry-over stays retryable and does not replace the in-memory week")
    func currentWeekNilCarryOverDoesNotAdoptPartiallyCreatedWeek() async throws {
        let fixture = try p2fSessionEpochFixture()
        defer { fixture.session.detach() }
        let state = fixture.state
        let repository = WeekRepository(session: fixture.session)
        repository.reload()
        state.weekRepository = repository
        state.groceryRepository = GroceryRepository(session: fixture.session)
        let existingWeek = p2fWeek(
            id: "p2f-core-fix6-existing-week",
            start: Date(),
            meals: [try p2fMeal()]
        )
        state.currentWeek = existingWeek
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: { _, _, _, _, _ in nil },
            fetchChanges: live.fetchChanges,
            drainChanges: live.drainChanges,
            prepareZoneWideShare: live.prepareZoneWideShare
        )

        let result = await state.ensureCurrentCloudKitWeek(
            session: fixture.session,
            requestEpoch: state.sessionBootEpoch
        )

        #expect(result == .retryableNotAuthoritative)
        #expect(state.currentWeek?.weekId == existingWeek.weekId)
    }

    @Test("a stale backup fetch failure returns typed denial without touching successor UI state")
    func backupFailingAwaitRejectsReplacedSessionBeforePropagatingExecutorError() async throws {
        let fixture = try p2fSessionEpochFixture()
        let successor = HouseholdSession(householdID: "p2f-core-fix5-backup-successor-\(UUID().uuidString)")
        defer {
            fixture.session.detach()
            successor.detach()
        }
        let state = fixture.state
        let gate = P2fSuspensionGate()
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: live.saveCurrentWeekCarryOver,
            fetchChanges: { _ in
                await gate.suspend()
                throw P2fCoreFix5ExecutorFailure(operation: "backup fetch")
            },
            drainChanges: live.drainChanges,
            prepareZoneWideShare: live.prepareZoneWideShare
        )
        let backup = HouseholdBackup(capturedAt: .now, appBuild: "P2f", role: "owner", records: [])
        let continuation = Task { @MainActor in
            do {
                try await state.restoreHousehold(from: backup)
                return Result<Void, Error>.success(())
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()

        state.sessionBootEpoch += 1
        state.householdSession = successor
        state.lastErrorMessage = "successor backup error"
        state.syncPhase = .offline
        await gate.resume()

        switch await continuation.value {
        case .success:
            Issue.record("stale backup failure reported success")
        case .failure(let error):
            #expect(error as? CachedHouseholdSystemOperationResult == .retryableNotAuthoritative)
        }
        #expect(state.householdSession === successor)
        #expect(state.lastErrorMessage == "successor backup error")
        #expect(state.syncPhase == .offline)
    }

    @Test("a stale owner-share failure returns typed denial without replacing successor error state")
    func ownerShareFailingAwaitRejectsReplacedSessionBeforePublishingExecutorError() async throws {
        let fixture = try p2fSessionEpochFixture()
        let successor = HouseholdSession(householdID: "p2f-core-fix5-share-successor-\(UUID().uuidString)")
        defer {
            fixture.session.detach()
            successor.detach()
        }
        let state = fixture.state
        let gate = P2fSuspensionGate()
        let live = state.householdSystemOperationExecutor
        state.householdSystemOperationExecutor = HouseholdSystemOperationExecutor(
            saveCurrentWeekCarryOver: live.saveCurrentWeekCarryOver,
            fetchChanges: live.fetchChanges,
            drainChanges: live.drainChanges,
            prepareZoneWideShare: { _, _ in
                await gate.suspend()
                throw P2fCoreFix5ExecutorFailure(operation: "owner-share")
            }
        )
        let continuation = Task { @MainActor in
            do {
                return Result<AppState.OwnerSharePackage?, Error>.success(
                    try await state.prepareOwnerShare(title: "P2f core fix 5")
                )
            } catch {
                return .failure(error)
            }
        }
        await gate.waitUntilSuspended()

        state.sessionBootEpoch += 1
        state.householdSession = successor
        state.lastErrorMessage = "successor share error"
        await gate.resume()

        switch await continuation.value {
        case .success(let package):
            #expect(package == nil)
            Issue.record("stale owner-share failure returned a package")
        case .failure(let error):
            #expect(error as? CachedHouseholdSystemOperationResult == .retryableNotAuthoritative)
        }
        #expect(state.householdSession === successor)
        #expect(state.lastErrorMessage == "successor share error")
    }
}

struct P2eParticipantIdentityTests {
    @Test("participant recovery keeps the exact household identity from its durable scope")
    func recoveryIdentityPrecedesZoneFallback() {
        #expect(ParticipantHouseholdIDPolicy.resolve(
            cachedHouseholdID: nil,
            recoveryHouseholdID: "recovered-household",
            fallbackZoneName: "household-zone"
        ) == "recovered-household")
        #expect(ParticipantHouseholdIDPolicy.resolve(
            cachedHouseholdID: "cached-household",
            recoveryHouseholdID: "recovered-household",
            fallbackZoneName: "household-zone"
        ) == "cached-household")
        #expect(ParticipantHouseholdIDPolicy.resolve(
            cachedHouseholdID: nil,
            recoveryHouseholdID: nil,
            fallbackZoneName: "household-zone"
        ) == "household-zone")
    }
}

struct P2eSessionCallbackBufferTests {
    @Test("session callback buffer drains engine-derived authority events once and in order after dispatcher install")
    func sessionCallbackBufferOrdering() {
        let buffer = OrderedCallbackBuffer<String>()
        var delivered: [String] = []
        buffer.submit("store")
        buffer.submit("durability")
        buffer.submit("saved")
        buffer.install { delivered.append($0) }
        #expect(delivered == ["store", "durability", "saved"])
    }
}

struct P2eDirectAuthorityTests {
    @Test("owner and participant recovery publish direct then exact pending then terminal intervention")
    func recoveryAuthorityOrdering() {
        let now = Date(timeIntervalSince1970: 200)
        let expected: [HouseholdAuthorityEvent] = [
            .directReady(now),
            .pending(count: 2),
            .intervention("1 durable change needs attention.")
        ]
        #expect(DirectHouseholdAuthorityPlan.events(
            isSynchronized: true, pendingCount: 2, interventionCount: 1, now: now
        ) == expected)
        #expect(DirectHouseholdAuthorityPlan.events(
            isSynchronized: true, pendingCount: 2, interventionCount: 1, now: now
        ) == expected)
        let terminal = expected.reduce(HouseholdAuthorityState.none) { state, event in
            HouseholdAuthorityReducer.reduce(
                state, event: event, epoch: 1, currentEpoch: 1, sessionMatches: true, now: now)
        }
        #expect(terminal == .intervention(message: "1 durable change needs attention."))
    }

    @Test("direct offline boot publishes degraded authority instead of current")
    func offlineDirectBootDoesNotClaimCurrent() {
        let events = DirectHouseholdAuthorityPlan.events(
            isSynchronized: false, pendingCount: 0, interventionCount: 0, now: .now)
        #expect(events == [.degraded("Household sync is offline.")])
    }
}

struct P2eAuthorityReducerTests {
    private let cachedAt = Date(timeIntervalSince1970: 100)
    private let currentAt = Date(timeIntervalSince1970: 200)

    @Test("cached content enters reconciliation and successful fetch becomes current")
    func cachedToCurrent() {
        let reconciling = HouseholdAuthorityReducer.reduce(
            .none, event: .cachedReady(cachedAt), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(reconciling == .reconciling(cachedAt: cachedAt))
        let current = HouseholdAuthorityReducer.reduce(
            reconciling, event: .reconciliationSucceeded(currentAt), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(current == .current(currentAt))
    }

    @Test("intervention outranks pending work and stale sessions cannot publish")
    func interventionAndStaleNoop() {
        let current = HouseholdAuthorityReducer.reduce(
            .none, event: .directReady(currentAt), epoch: 4, currentEpoch: 4, sessionMatches: true)
        let pending = HouseholdAuthorityReducer.reduce(
            current, event: .pending(count: 2), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(pending == .pending(count: 2))
        let intervention = HouseholdAuthorityReducer.reduce(
            pending, event: .intervention("blocked"), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(intervention == .intervention(message: "blocked"))
        #expect(HouseholdAuthorityReducer.reduce(
            .none, event: .directReady(currentAt), epoch: 4, currentEpoch: 5, sessionMatches: false
        ) == .none)
    }

    @Test("intervention remains terminal until explicit resolution or teardown")
    func interventionIsTerminal() {
        let intervention = HouseholdAuthorityReducer.reduce(
            .none, event: .intervention("blocked"), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(HouseholdAuthorityReducer.reduce(
            intervention, event: .cachedReady(cachedAt), epoch: 4, currentEpoch: 4, sessionMatches: true
        ) == intervention)
        #expect(HouseholdAuthorityReducer.reduce(
            intervention, event: .pending(count: 2), epoch: 4, currentEpoch: 4, sessionMatches: true
        ) == intervention)
        let resolved = HouseholdAuthorityReducer.reduce(
            intervention, event: .resolveIntervention(currentAt), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(resolved == .current(currentAt))
    }

    @Test("pending work returns to current when the queue drains")
    func pendingReturnsToCurrent() {
        let current = HouseholdAuthorityReducer.reduce(
            .none, event: .directReady(currentAt), epoch: 4, currentEpoch: 4, sessionMatches: true)
        let pending = HouseholdAuthorityReducer.reduce(
            current, event: .pending(count: 2), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(HouseholdAuthorityReducer.reduce(
            pending, event: .pending(count: 0), epoch: 4, currentEpoch: 4, sessionMatches: true,
            now: currentAt
        ) == .current(currentAt))
    }

    @Test("cached retry returns to reconciliation before its next fetch outcome")
    func cachedRetryTransitionsThroughReconciliation() {
        let offline = HouseholdAuthorityReducer.reduce(
            .reconciling(cachedAt: cachedAt), event: .reconciliationFailed("offline"),
            epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(offline == .offlineCached(cachedAt: cachedAt))
        #expect(HouseholdAuthorityReducer.reduce(
            offline, event: .retry(currentAt), epoch: 4, currentEpoch: 4, sessionMatches: true
        ) == .reconciling(cachedAt: currentAt))
    }

    @Test("pending work observed during reconciliation remains pending after success")
    func reconciliationSuccessPreservesPendingWork() {
        let reconciling = HouseholdAuthorityReducer.reduce(
            .none, event: .cachedReady(cachedAt), epoch: 4, currentEpoch: 4, sessionMatches: true)
        let pending = HouseholdAuthorityReducer.reduce(
            reconciling, event: .pending(count: 3), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(pending == .pending(count: 3))
        #expect(HouseholdAuthorityReducer.reduce(
            pending, event: .reconciliationSucceeded(currentAt), epoch: 4, currentEpoch: 4, sessionMatches: true
        ) == .pending(count: 3))
    }

    @Test("teardown and reconciliation errors never resurrect authority")
    func teardownIsTerminalForSession() {
        let degraded = HouseholdAuthorityReducer.reduce(
            .reconciling(cachedAt: cachedAt), event: .reconciliationFailed("offline"), epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(degraded == .offlineCached(cachedAt: cachedAt))
        let none = HouseholdAuthorityReducer.reduce(
            degraded, event: .teardown, epoch: 4, currentEpoch: 4, sessionMatches: true)
        #expect(none == .none)
        #expect(HouseholdAuthorityReducer.reduce(
            none, event: .reconciliationSucceeded(currentAt), epoch: 4, currentEpoch: 5, sessionMatches: false
        ) == .none)
    }

    @Test("a stale teardown is a no-op")
    func staleTeardownDoesNotClearCurrentAuthority() {
        #expect(HouseholdAuthorityReducer.reduce(
            .current(currentAt), event: .teardown, epoch: 4, currentEpoch: 4, sessionMatches: false
        ) == .current(currentAt))
    }
}

#if canImport(CloudKit)
private struct P2fLifecycleTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func p2fLifecycleDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("p2f-app-lifecycle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func p2fOwnerLifecycleScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "p2f-owner-account",
        zoneOwnerName: CKCurrentUserDefaultName,
        zoneName: "household-p2f-owner",
        householdID: "p2f-owner",
        role: .owner,
        databaseScope: .private)
}

private func p2fParticipantLifecycleScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "p2f-participant-account",
        zoneOwnerName: "p2f-owner-account",
        zoneName: "household-p2f-shared",
        householdID: "p2f-shared",
        role: .participant,
        databaseScope: .shared)
}

private func p2fLifecycleExecutor(
    currentAccountRecordName: @escaping @MainActor () async throws -> String? = {
        "factory-account"
    },
    requestRootClear: @escaping (URL) throws -> Void = { _ in },
    completeRootClear: @escaping (URL) throws -> Void = { _ in },
    requestScopeClear: @escaping (MirrorScope, URL) throws -> Void = { _, _ in },
    completeScopeClear: @escaping (MirrorScope, URL) throws -> Void = { _, _ in },
    clearRoleEngineStateFiles: @escaping (URL) throws -> Void = { _ in },
    deleteAllHouseholdZones: @escaping @MainActor (String) async throws -> [String] = { _ in [] }
) -> HouseholdLifecycleExecutor {
    HouseholdLifecycleExecutor(
        currentAccountRecordName: currentAccountRecordName,
        requestRootClear: requestRootClear,
        completeRootClear: completeRootClear,
        requestScopeClear: requestScopeClear,
        completeScopeClear: completeScopeClear,
        clearRoleEngineStateFiles: clearRoleEngineStateFiles,
        deleteAllHouseholdZones: deleteAllHouseholdZones)
}

@Suite("P2f app lifecycle authority")
@MainActor
struct P2fAppLifecycleAuthorityTests {
    @Test("projection continuation fence rejects an epoch retired by lifecycle teardown")
    func staleProjectionEpochCannotRepublish() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let epoch = state.sessionBootEpoch
        #expect(state.householdProjectionEpochIsCurrent(epoch))

        state.beginEpochFirstHouseholdTransition(
            clearPersonalData: true,
            interventionMessage: "account changed")

        #expect(!state.householdProjectionEpochIsCurrent(epoch))
    }

    @Test("epoch-first transition detaches every visible household and personal projection synchronously")
    func epochFirstTransitionDetachesBeforeSuspension() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let week = p2fWeek(id: "visible-week", start: .now, meals: [])
        state.currentWeek = week
        state.browsedWeek = week
        state.checkedGroceryItemIDs = ["visible-check"]
        state.recipeMemories = ["visible-recipe": []]
        state.pendingLeftoverHouseholdIDs = ["visible-leftover"]
        state.forkedHouseholdIDs = ["visible-fork"]
        state.assistantErrorByThreadID = ["visible-thread": "visible-error"]
        state.personalDataReadiness = .ready
        state.householdLaunchPhase = .ready
        state.householdAuthority = .current(.now)
        let epoch = state.sessionBootEpoch

        state.beginEpochFirstHouseholdTransition(
            clearPersonalData: true,
            interventionMessage: "Lifecycle teardown in progress.")

        #expect(state.sessionBootEpoch == epoch + 1)
        #expect(state.householdLaunchPhase == .resolving)
        #expect(state.currentWeek == nil)
        #expect(state.browsedWeek == nil)
        #expect(state.checkedGroceryItemIDs.isEmpty)
        #expect(state.recipeMemories.isEmpty)
        #expect(state.pendingLeftoverHouseholdIDs.isEmpty)
        #expect(state.forkedHouseholdIDs.isEmpty)
        #expect(state.assistantErrorByThreadID.isEmpty)
        #expect(state.personalDataReadiness == .unavailable)
        #expect(state.householdAuthority == .intervention(
            message: "Lifecycle teardown in progress."))
    }

    @Test("valid pending lifecycle transaction suppresses legacy cache and denies boot and share entry")
    func validTransactionSuppressesLegacyCacheAndEntry() throws {
        let directory = try p2fLifecycleDirectory()
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false,
            householdLifecycleDirectoryURL: directory)
        let week = p2fWeek(id: "legacy-week", start: .now, meals: [])
        try state.cacheStore.saveCurrentWeek(week)
        let transaction = try HouseholdLifecycleTransaction(
            kind: .accountBoundary,
            scope: nil)
        try state.householdLifecycleTransactionStore.begin(transaction)

        state.loadCachedData()

        #expect(state.currentWeek == nil)
        #expect(!state.householdLifecycleAllowsEntry())
        #expect(state.householdLifecycleGateState() == .pending(transaction))
    }

    @Test("malformed transaction bytes remain intact while cache, boot, and share stay denied")
    func malformedTransactionFailsClosedWithoutRewritingBytes() throws {
        let directory = try p2fLifecycleDirectory()
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: false,
            householdLifecycleDirectoryURL: directory)
        let bytes = Data("not-a-lifecycle-transaction".utf8)
        try bytes.write(to: state.householdLifecycleTransactionStore.fileURL, options: .atomic)
        let week = p2fWeek(id: "legacy-week", start: .now, meals: [])
        try state.cacheStore.saveCurrentWeek(week)

        state.loadCachedData()

        #expect(state.currentWeek == nil)
        #expect(!state.householdLifecycleAllowsEntry())
        #expect(state.householdLifecycleGateState() == .malformed)
        #expect(try Data(contentsOf: state.householdLifecycleTransactionStore.fileURL) == bytes)
    }

    @Test("participant revocation persists the transaction before marker and exact-scope invalidation")
    func participantRevocationUsesExactScopeAndDurableMarker() throws {
        let directory = try p2fLifecycleDirectory()
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: directory)
        let scope = p2fParticipantLifecycleScope()
        #expect(state.saveParticipantMarker(.init(
            zoneName: scope.zoneName,
            ownerName: scope.zoneOwnerName,
            accountRecordName: scope.accountRecordName)))
        var observed: [String] = []
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            requestScopeClear: { requested, _ in
                let pendingKind = try state.householdLifecycleTransactionStore.pending()?.kind
                #expect(pendingKind == .participantRevocation)
                #expect(requested == scope)
                observed.append("scope-request")
            })

        #expect(state.handleHouseholdLifecycleEvent(
            .participantRevocation,
            scope: scope,
            scheduleReplay: false))

        #expect(observed == ["scope-request"])
        #expect(state.loadParticipantMarker() == nil)
        #expect(try state.householdLifecycleTransactionStore.pending()?.scope == scope)
        #expect(state.householdLaunchPhase == .resolving)
    }

    @Test("account root-request failure remains pending and non-ready")
    func accountRootFailureRemainsIntervention() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        state.householdLaunchPhase = .ready
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            requestRootClear: { _ in
                throw P2fLifecycleTestError(message: "root request failed")
            })

        #expect(!state.handleHouseholdLifecycleEvent(
            .accountBoundary(.switchedAccounts),
            scope: nil,
            scheduleReplay: false))

        #expect(state.householdLaunchPhase == .resolving)
        guard case .intervention = state.householdAuthority else {
            Issue.record("account invalidation failure must remain intervention")
            return
        }
        #expect(try state.householdLifecycleTransactionStore.pending()?.kind == .accountBoundary)
    }

    @Test("unexpected owner deletion reasserts the exact request on replay before completion")
    func ownerDeletionCompletesExactScopeBeforeDiscoveryOutcome() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let scope = p2fOwnerLifecycleScope()
        var observed: [String] = []
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            requestScopeClear: { requested, _ in
                #expect(requested == scope)
                observed.append("scope-request")
            },
            completeScopeClear: { completed, _ in
                #expect(completed == scope)
                observed.append("scope-complete")
            })
        #expect(state.handleHouseholdLifecycleEvent(
            .unexpectedOwnerZoneDeletion,
            scope: scope,
            scheduleReplay: false))

        let outcome = await state.completePendingHouseholdLifecycleBoundary()

        #expect(observed == ["scope-request", "scope-request", "scope-complete"])
        #expect(outcome == .unexpectedOwnerZoneDeletion)
        #expect(try state.householdLifecycleTransactionStore.pending() == nil)
    }

    @Test("factory-reset-owned owner deletion cannot replace or duplicate the reset transaction")
    func resetOwnedOwnerDeletionIsIgnored() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        let epoch = state.sessionBootEpoch

        #expect(!state.handleHouseholdLifecycleEvent(
            .unexpectedOwnerZoneDeletion,
            scope: p2fOwnerLifecycleScope(),
            scheduleReplay: false))

        #expect(state.sessionBootEpoch == epoch)
        #expect(try state.householdLifecycleTransactionStore.pending() == transaction)
    }

    @Test("an exact lifecycle boundary upgrades atomically to a later account boundary")
    func exactBoundaryUpgradesToAccountBoundary() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let scope = p2fParticipantLifecycleScope()
        state.householdLifecycleExecutor = p2fLifecycleExecutor()
        #expect(state.handleHouseholdLifecycleEvent(
            .participantRevocation,
            scope: scope,
            scheduleReplay: false))
        #expect(state.handleHouseholdLifecycleEvent(
            .accountBoundary(.signedOut),
            scope: nil,
            scheduleReplay: false))

        let stored = try state.householdLifecycleTransactionStore.pending()
        let pending = try #require(stored)
        #expect(pending.kind == .accountBoundary)
        #expect(pending.scope == nil)
    }

    @Test("Session relay preserves a stronger account event after the first event tears Session down")
    func sessionRelaySurvivesFirstEventTeardown() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        var session: HouseholdSession? = HouseholdSession(
            householdID: "relay-retirement")
        state.householdSession = try #require(session)
        state.householdLaunchPhase = .ready
        var observed: [String] = []
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            requestRootClear: { _ in observed.append("root-request") },
            completeRootClear: { _ in
                throw P2fLifecycleTestError(message: "hold pending for assertion")
            },
            requestScopeClear: { _, _ in observed.append("scope-request") })
        state.installLifecycleDispatcher(
            for: try #require(session),
            epoch: state.sessionBootEpoch)

        session?.submitLifecycleSnapshotForTesting(
            .participantRevocation,
            scope: p2fParticipantLifecycleScope())
        session?.submitLifecycleSnapshotForTesting(
            .accountBoundary(.switchedAccounts),
            scope: nil)
        weak var retiredSession = session
        session = nil
        for _ in 0..<32 { await Task.yield() }

        let stored = try state.householdLifecycleTransactionStore.pending()
        let pending = try #require(stored)
        #expect(pending.kind == .accountBoundary)
        #expect(pending.scope == nil)
        #expect(state.householdSession == nil)
        #expect(observed.contains("scope-request"))
        #expect(observed.contains("root-request"))
        #expect(retiredSession == nil)
    }
}

@Suite("P2f durable participant marker")
struct P2fDurableParticipantMarkerTests {
    @Test("save and clear are durable and a cleared marker cannot reappear")
    func markerSaveClearRoundTrip() throws {
        let directory = try p2fLifecycleDirectory()
        let store = ParticipantMarkerStore(
            fileURL: directory.appendingPathComponent("participant-marker.json"))
        let marker = try DurableParticipantMarker(
            zoneName: "household-shared",
            ownerName: "owner-record",
            accountRecordName: "participant-account")

        try store.save(marker)
        #expect(try store.load() == marker)
        try store.clear()
        #expect(try store.load() == nil)

        let reconstructed = ParticipantMarkerStore(fileURL: store.fileURL)
        #expect(try reconstructed.load() == nil)
    }
}

@Suite("P2f accepted-share durable handoff")
@MainActor
struct P2fAcceptedShareDurableHandoffTests {
    @Test("accepted share persists its account-bound marker before owner parking or publication")
    func markerPrecedesAdoptionBoundary() async throws {
        let directory = try p2fLifecycleDirectory()
        let store = ParticipantMarkerStore(
            fileURL: directory.appendingPathComponent("participant-marker.json"))
        let marker = try DurableParticipantMarker(
            zoneName: "household-shared",
            ownerName: "owner-record",
            accountRecordName: "participant-account")
        var observed: [String] = []
        let runner = AcceptedShareAdoptionBoundaryRunner(
            persistMarker: {
                observed.append("marker")
                do {
                    try store.save(marker)
                    return true
                } catch {
                    return false
                }
            },
            adoptSharedZone: {
                let persisted = try? store.load()
                #expect(persisted == marker)
                observed.append("owner-park-and-publication")
                return 7
            })

        #expect(await runner.run() == .adopted(publicationEpoch: 7))
        #expect(observed == ["marker", "owner-park-and-publication"])
    }

    @Test("marker persistence failure never reaches owner parking")
    func markerFailureLeavesOwnerBoundaryUntouched() async {
        var adoptionCount = 0
        let runner = AcceptedShareAdoptionBoundaryRunner(
            persistMarker: { false },
            adoptSharedZone: {
                adoptionCount += 1
                return 1
            })

        #expect(await runner.run() == .markerPersistenceFailed)
        #expect(adoptionCount == 0)
    }

    @Test("failed adoption retains the durable account-bound marker for restart recovery")
    func adoptionFailureRetainsMarker() async throws {
        let directory = try p2fLifecycleDirectory()
        let markerURL = directory.appendingPathComponent("participant-marker.json")
        let store = ParticipantMarkerStore(fileURL: markerURL)
        let marker = try DurableParticipantMarker(
            zoneName: "household-shared",
            ownerName: "owner-record",
            accountRecordName: "participant-account")
        let runner = AcceptedShareAdoptionBoundaryRunner(
            persistMarker: {
                do {
                    try store.save(marker)
                    return true
                } catch {
                    return false
                }
            },
            adoptSharedZone: { nil })

        #expect(await runner.run() == .adoptionFailed)

        let reconstructed = ParticipantMarkerStore(fileURL: markerURL)
        #expect(try reconstructed.load() == marker)
    }
}

@Suite("P2f factory-reset lifecycle ordering")
@MainActor
struct P2fFactoryResetLifecycleTests {
    @Test("reset orders begin, local invalidation, server deletion, completion, then mint")
    func successfulResetOrdering() async {
        var observed: [String] = []
        let runner = HouseholdFactoryResetBoundaryRunner(
            beginLocalInvalidation: { observed.append("begin") },
            completeLocalInvalidation: { observed.append("local") },
            deleteServerZones: {
                observed.append("server")
                return ["old-household"]
            },
            completeTransaction: { observed.append("complete") },
            mintReplacement: {
                observed.append("mint")
                return true
            })

        let outcome = await runner.run()

        #expect(outcome == .ready(deletedHouseholdIDs: ["old-household"]))
        #expect(observed == ["begin", "local", "server", "complete", "mint"])
    }

    @Test("server failure preserves the transaction boundary and performs zero mint")
    func serverFailureDoesNotCompleteOrMint() async {
        var observed: [String] = []
        let runner = HouseholdFactoryResetBoundaryRunner(
            beginLocalInvalidation: { observed.append("begin") },
            completeLocalInvalidation: { observed.append("local") },
            deleteServerZones: {
                observed.append("server")
                throw P2fLifecycleTestError(message: "offline")
            },
            completeTransaction: { observed.append("complete") },
            mintReplacement: {
                observed.append("mint")
                return true
            })

        let outcome = await runner.run()

        guard case .failed = outcome else {
            Issue.record("server failure must fail reset")
            return
        }
        #expect(observed == ["begin", "local", "server"])
    }

    @Test("live reset account switch during bound deletion keeps transaction pending and skips completion and mint")
    func liveResetRejectsAccountSwitchDuringDeletion() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        var accountCheckCount = 0
        var boundDeleteAccounts: [String] = []
        var completionCount = 0
        var mintCount = 0
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            currentAccountRecordName: {
                accountCheckCount += 1
                return accountCheckCount == 1 ? "factory-account" : "switched-account"
            },
            deleteAllHouseholdZones: { expectedAccount in
                boundDeleteAccounts.append(expectedAccount)
                return ["old-household"]
            })
        let runner = HouseholdFactoryResetBoundaryRunner(
            beginLocalInvalidation: {},
            completeLocalInvalidation: {},
            deleteServerZones: {
                try await state.deleteFactoryResetZonesBoundToAccount(
                    transaction: transaction,
                    isCurrent: {
                        (try? state.householdLifecycleTransactionStore.pending()) == transaction
                    })
            },
            completeTransaction: {
                completionCount += 1
                try state.householdLifecycleTransactionStore.complete(transaction)
            },
            mintReplacement: {
                mintCount += 1
                return true
            })

        guard case .failed = await runner.run() else {
            Issue.record("mid-delete account switch must fail the live reset")
            return
        }
        #expect(boundDeleteAccounts == ["factory-account"])
        #expect(completionCount == 0)
        #expect(mintCount == 0)
        #expect(try state.householdLifecycleTransactionStore.pending() == transaction)
    }

    @Test("account switch after reset completion stops replacement boot before discovery or mint")
    func replacementBootRejectsPostDeleteAccountSwitch() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let resetEpoch = state.sessionBootEpoch
        state.pendingLeftoverHouseholdIDs = ["discovery-tripwire"]
        var currentAccount = "reset-account"
        var identityLookupCount = 0
        var transactionCompletionCount = 0
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            currentAccountRecordName: {
                identityLookupCount += 1
                return currentAccount
            })
        let runner = HouseholdFactoryResetBoundaryRunner(
            beginLocalInvalidation: {},
            completeLocalInvalidation: {},
            deleteServerZones: { ["old-household"] },
            completeTransaction: {
                transactionCompletionCount += 1
                currentAccount = "switched-account"
            },
            mintReplacement: {
                await state.ensureSessionBootOp(
                    requestEpoch: resetEpoch,
                    expectedAccountRecordName: "reset-account")
                return state.householdSession != nil
            })

        guard case .failed = await runner.run() else {
            Issue.record("post-delete account switch must fail before replacement mint")
            return
        }
        #expect(transactionCompletionCount == 1)
        #expect(identityLookupCount == 1)
        #expect(state.pendingLeftoverHouseholdIDs == ["discovery-tripwire"])
        #expect(state.householdSession == nil)
        #expect(state.bootingHouseholdSession == nil)
        guard case .intervention(let message) = state.householdAuthority else {
            Issue.record("account mismatch must leave the app in intervention")
            return
        }
        #expect(message.contains("iCloud account changed"))
    }

    @Test("replacement minted after an account switch is rejected and leaves import required")
    func replacementAccountSwitchCannotImport() throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        try state.factoryResetImportMarkerStore.set()
        let newAccountScope = MirrorScope(
            accountRecordName: "new-account",
            zoneOwnerName: CKCurrentUserDefaultName,
            zoneName: "household-new-account",
            householdID: "new-account",
            role: .owner,
            databaseScope: .private)
        let replacement = try HouseholdSession(
            householdID: "new-account",
            initialMirrorScope: newAccountScope)
        #expect(replacement.promoteCachedAuthority())
        state.householdSession = replacement
        state.householdLaunchPhase = .ready

        #expect(!state.factoryResetReplacementSessionIsCurrent(
            replacement,
            requestEpoch: state.sessionBootEpoch,
            resetAccountRecordName: "reset-account"))
        #expect(state.factoryResetImportRequired)
    }

    @Test("tokenless reconstructed reset replay deletes once, stays not-done, and leaves import required")
    func reconstructedReplayNeverReportsDone() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        var deleteCount = 0
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            deleteAllHouseholdZones: { expectedAccount in
                #expect(expectedAccount == "factory-account")
                deleteCount += 1
                return ["old-household"]
            })

        let outcome = await state.completePendingHouseholdLifecycleBoundary()

        #expect(outcome == .factoryResetNeedsImport)
        #expect(deleteCount == 1)
        #expect(state.factoryResetImportRequired)
        guard case .failed = state.startFreshState else {
            Issue.record("tokenless replay must require the user to rerun import")
            return
        }
        #expect(try state.householdLifecycleTransactionStore.pending() == nil)
    }

    @Test("reconstructed reset refuses a different current account with zero remote deletion")
    func reconstructedReplayRejectsAccountSwitch() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "old-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        var deleteCount = 0
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            currentAccountRecordName: { "new-account" },
            deleteAllHouseholdZones: { _ in
                deleteCount += 1
                return []
            })

        let outcome = await state.completePendingHouseholdLifecycleBoundary()

        #expect(outcome == nil)
        #expect(deleteCount == 0)
        #expect(try state.householdLifecycleTransactionStore.pending() == transaction)
        #expect(!state.factoryResetImportRequired)
        #expect(state.householdLaunchPhase == .resolving)
    }

    @Test("epoch change during reconstructed account lookup leaves reset pending with zero delete")
    func reconstructedReplayRejectsStaleIdentityContinuation() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        let gate = P2fSuspensionGate()
        var deleteCount = 0
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            currentAccountRecordName: {
                await gate.suspend()
                return "factory-account"
            },
            deleteAllHouseholdZones: { _ in
                deleteCount += 1
                return []
            })

        let replay = Task { @MainActor in
            await state.completePendingHouseholdLifecycleBoundary()
        }
        await gate.waitUntilSuspended()
        state.beginEpochFirstHouseholdTransition(
            clearPersonalData: true,
            interventionMessage: "account changed")
        await gate.resume()
        let outcome = await replay.value

        #expect(outcome == nil)
        #expect(deleteCount == 0)
        #expect(try state.householdLifecycleTransactionStore.pending() == transaction)
    }

    @Test("tokenless replay account switch during bound deletion keeps transaction pending")
    func reconstructedReplayRejectsAccountSwitchDuringDeletion() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        var accountCheckCount = 0
        var boundDeleteAccounts: [String] = []
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            currentAccountRecordName: {
                accountCheckCount += 1
                return accountCheckCount == 1 ? "factory-account" : "switched-account"
            },
            deleteAllHouseholdZones: { expectedAccount in
                boundDeleteAccounts.append(expectedAccount)
                return ["old-household"]
            })

        #expect(await state.completePendingHouseholdLifecycleBoundary() == nil)
        #expect(boundDeleteAccounts == ["factory-account"])
        #expect(try state.householdLifecycleTransactionStore.pending() == transaction)
        #expect(!state.factoryResetImportRequired)
    }

    @Test("reconstructed server failure keeps reset pending and never creates import-complete evidence")
    func reconstructedServerFailureRemainsPending() async throws {
        let state = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            cacheFirstLaunchEnabled: true,
            householdLifecycleDirectoryURL: try p2fLifecycleDirectory())
        let transaction = try HouseholdLifecycleTransaction(
            kind: .factoryReset,
            scope: nil,
            remoteAccountRecordName: "factory-account")
        try state.householdLifecycleTransactionStore.begin(transaction)
        state.householdLifecycleExecutor = p2fLifecycleExecutor(
            deleteAllHouseholdZones: { _ in
                throw P2fLifecycleTestError(message: "offline")
            })

        #expect(await state.completePendingHouseholdLifecycleBoundary() == nil)
        #expect(try state.householdLifecycleTransactionStore.pending() == transaction)
        #expect(!state.factoryResetImportRequired)
        guard case .failed = state.startFreshState else {
            Issue.record("server failure must remain visible")
            return
        }
    }
}
#endif
