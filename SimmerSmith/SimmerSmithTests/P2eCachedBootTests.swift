import Foundation
import Testing
import SimmerSmithKit
@testable import SimmerSmith

@MainActor
struct P2eLaunchPolicyTests {
    @Test("shipping default stays off and App Store ignores local override")
    func productionPolicyFailsClosed() {
        #expect(CacheFirstLaunchPolicy.resolve(
            staticDefault: false,
            installOverride: true,
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

    @Test("leftover cleanup revalidates the exact authoritative owner at its destructive seam")
    func cleanupContinuationIsFailClosed() {
        #expect(LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: true,
            isOwner: true,
            isCachedBootstrap: false))
        #expect(!LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: false,
            isOwner: true,
            isCachedBootstrap: false))
        #expect(!LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: true,
            isOwner: false,
            isCachedBootstrap: false))
        #expect(!LeftoverHouseholdCleanupPolicy.allows(
            requestEpoch: 4,
            currentEpoch: 4,
            sessionMatches: true,
            isOwner: true,
            isCachedBootstrap: true))
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
