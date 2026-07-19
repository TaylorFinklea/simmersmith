import Foundation
import CloudKit
import Testing
@testable import HouseholdSync

struct P2eParticipantProofTests {
    @Test("participant proof is earned only from a matching successful zone event")
    func productionFetchEventProof() {
        let expected = CKRecordZone.ID(zoneName: "household", ownerName: "owner")
        #expect(MirrorParticipantFetchObservation.proof(
            role: .participant, expectedZoneID: expected, fetchedZoneID: expected, error: nil
        ) == .verified)
        #expect(MirrorParticipantFetchObservation.proof(
            role: .participant, expectedZoneID: expected,
            fetchedZoneID: CKRecordZone.ID(zoneName: "other", ownerName: "owner"), error: nil
        ) == .unverified)
        #expect(MirrorParticipantFetchObservation.proof(
            role: .participant, expectedZoneID: expected, fetchedZoneID: expected,
            error: CKError(.networkFailure)
        ) == .failed)
        #expect(MirrorParticipantFetchObservation.proof(
            role: .participant, expectedZoneID: expected, fetchedZoneID: nil, error: nil
        ) == .unverified)
    }

    @Test("a verified participant fetch is zoneEnsured eligible")
    func verifiedParticipantFetchProducesProof() {
        #expect(MirrorZoneEnsuredPolicy.value(
            role: .participant, recoveredZoneEnsured: false, fetch: .verified
        ))
        #expect(!MirrorZoneEnsuredPolicy.value(
            role: .participant, recoveredZoneEnsured: false, fetch: .failed
        ))
        #expect(!MirrorZoneEnsuredPolicy.value(
            role: .participant, recoveredZoneEnsured: false, fetch: .unverified
        ))
        // A legacy Boolean may have been set by an old participant local save. It is not typed
        // fetch proof and therefore cannot make cached participant content eligible.
        #expect(!MirrorZoneEnsuredPolicy.value(
            role: .participant, recoveredZoneEnsured: true, fetch: .unverified
        ))
        #expect(MirrorZoneEnsuredPolicy.value(
            role: .participant,
            recoveredZoneEnsured: false,
            checkpointProof: MirrorParticipantFetchCheckpointProof(fetch: .verified),
            fetch: .unverified
        ))
    }

    @Test("owner zone semantics remain unchanged")
    func ownerUsesRecoveredZoneState() {
        #expect(MirrorZoneEnsuredPolicy.value(
            role: .owner, recoveredZoneEnsured: true, fetch: .failed
        ))
        #expect(!MirrorZoneEnsuredPolicy.value(
            role: .owner, recoveredZoneEnsured: false, fetch: .verified
        ))
    }
}

struct P2eCallbackRelayTests {
    @Test("automatic callbacks buffer through handler installation and drain once in arrival order")
    func callbackBufferDrainsInOrder() {
        let relay = HouseholdSyncEngineCallbackRelay()
        let events = CallbackEventLog()
        relay.emit(.storeChanged)
        relay.emit(.durabilityFailure(MirrorDurabilityFailure(message: "durability")))
        relay.emit(.recordSaved("recipe-1"))
        relay.emit(.lifecycle(.participantRevocation))
        relay.emit(.lifecycle(.accountBoundary(.signedOut)))

        relay.install((
            storeChanged: { events.append("store") },
            syncError: { _ in events.append("error") },
            recordSaved: { events.append("saved:\($0)") },
            durabilityFailure: { events.append("durability:\($0.message)") },
            participantRevoked: { events.append("revoked") },
            accountChanged: { events.append("account") },
            lifecycleEvent: nil))

        #expect(events.values == [
            "store", "durability:durability", "saved:recipe-1", "revoked", "account"
        ])
    }

    @Test("an event emitted during buffer drain cannot overtake an older callback")
    func concurrentEmissionPreservesArrivalOrder() {
        let relay = HouseholdSyncEngineCallbackRelay()
        let events = CallbackEventLog()
        let firstCallbackStarted = DispatchSemaphore(value: 0)
        let finishFirstCallback = DispatchSemaphore(value: 0)
        let installationFinished = DispatchSemaphore(value: 0)
        relay.emit(.storeChanged)

        DispatchQueue.global().async {
            relay.install((
                storeChanged: {
                    events.append("store-start")
                    firstCallbackStarted.signal()
                    _ = finishFirstCallback.wait(timeout: .now() + 2)
                    events.append("store-end")
                },
                syncError: { _ in events.append("error") },
                recordSaved: { events.append("saved:\($0)") },
                durabilityFailure: { _ in events.append("durability") },
                participantRevoked: { events.append("revoked") },
                accountChanged: { events.append("account") },
                lifecycleEvent: nil))
            installationFinished.signal()
        }

        #expect(firstCallbackStarted.wait(timeout: .now() + 2) == .success)
        relay.emit(.recordSaved("later"))
        finishFirstCallback.signal()
        #expect(installationFinished.wait(timeout: .now() + 2) == .success)
        #expect(events.values == ["store-start", "store-end", "saved:later"])
    }

    @Test("typed lifecycle callbacks preserve distinct kinds and arrival order")
    func typedLifecycleCallbacksRemainDistinct() {
        let relay = HouseholdSyncEngineCallbackRelay()
        let events = LifecycleCallbackLog()
        relay.emit(.lifecycle(.participantRevocation))
        relay.emit(.lifecycle(.unexpectedOwnerZoneDeletion))
        relay.emit(.lifecycle(.accountBoundary(.switchedAccounts)))

        relay.install((
            storeChanged: nil,
            syncError: nil,
            recordSaved: nil,
            durabilityFailure: nil,
            participantRevoked: { events.appendLegacy() },
            accountChanged: { events.appendLegacy() },
            lifecycleEvent: { events.append($0) }))

        #expect(events.values == [
            .participantRevocation,
            .unexpectedOwnerZoneDeletion,
            .accountBoundary(.switchedAccounts),
        ])
        #expect(events.legacyCount == 0)
    }

    @Test("lifecycle before cached activation discards the gate without losing buffered order")
    func lifecycleBeforeActivationDiscardsGateAndRetainsEvent() async {
        let gate = MirrorBootstrapDelegateGate()
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: true)
        let fence = HouseholdSyncLifecycleFence(authority: authority)
        let relay = HouseholdSyncEngineCallbackRelay()
        let events = CallbackEventLog()
        relay.emit(.storeChanged)

        fence.transition(
            to: .unexpectedOwnerZoneDeletion,
            fenceCacheMutation: { events.append("frozen") },
            emit: { relay.emit(.lifecycle($0)) })
        #expect(gate.resolve(.discarded))

        #expect(await gate.awaitOutcome() == .discarded)
        #expect(!authority.allowsAuthoritativeOperations)
        relay.install((
            storeChanged: { events.append("store") },
            syncError: nil,
            recordSaved: nil,
            durabilityFailure: nil,
            participantRevoked: nil,
            accountChanged: nil,
            lifecycleEvent: { event in events.append("lifecycle:\(event)") }))

        #expect(events.values == [
            "frozen", "store", "lifecycle:unexpectedOwnerZoneDeletion",
        ])
        #expect(!gate.resolve(.open))
        #expect(gate.resolvedOutcome == .discarded)
    }

    @Test("an unknown account transition remains a typed whole-account boundary")
    func unknownAccountTransitionIsFailClosed() {
        #expect(
            HouseholdSyncLifecycleEvent.accountBoundary(.unknown)
                == .accountBoundary(.unknown))
    }
}

private final class CallbackEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

private final class LifecycleCallbackLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HouseholdSyncLifecycleEvent] = []
    private var legacyStorage = 0

    var values: [HouseholdSyncLifecycleEvent] { lock.withLock { storage } }
    var legacyCount: Int { lock.withLock { legacyStorage } }
    func append(_ event: HouseholdSyncLifecycleEvent) {
        lock.withLock { storage.append(event) }
    }
    func appendLegacy() {
        lock.withLock { legacyStorage += 1 }
    }
}

struct P2eDataPlanePolicyTests {
    @Test("cached sessions deny destructive entry points while normal sessions allow them")
    func destructiveOperationsAreFailClosed() {
        #expect(!HouseholdDataPlanePolicy.allows(.delete, mode: .cached))
        #expect(!HouseholdDataPlanePolicy.allows(.deleteCascading, mode: .cached))
        #expect(!HouseholdDataPlanePolicy.allows(.zoneRecreation, mode: .cached))
        #expect(HouseholdDataPlanePolicy.allows(.save, mode: .cached))
        #expect(HouseholdDataPlanePolicy.allows(.delete, mode: .normal))
        #expect(HouseholdDataPlanePolicy.allows(.zoneRecreation, mode: .normal))
    }
}

struct P2fSessionAuthorityTests {
    @Test("cached authority is promoted once and stays revoked after teardown")
    func cachedAuthorityRequiresCurrentSessionPromotion() {
        let authority = HouseholdSessionAuthority(initiallyAuthoritative: false)

        #expect(authority.result(for: .save) == .allowed)
        #expect(authority.result(for: .delete) == .notAuthoritative)
        #expect(authority.result(for: .deleteCascading) == .notAuthoritative)
        #expect(authority.result(for: .zoneRecreation) == .notAuthoritative)
        #expect(authority.promote())
        #expect(authority.result(for: .delete) == .allowed)
        #expect(authority.result(for: .deleteCascading) == .allowed)
        #expect(authority.result(for: .zoneRecreation) == .allowed)
        #expect(!authority.promote())

        authority.revoke()
        #expect(authority.result(for: .delete) == .notAuthoritative)
        #expect(authority.result(for: .save) == .notAuthoritative)
    }

}

struct P2fDestructiveResultTests {
    @Test("destructive denials remain typed retryable errors for app callers")
    func destructiveResultIsUserPropagatable() {
        let result: HouseholdDataPlaneResult = .notAuthoritative
        #expect(result.errorDescription?.contains("reconciliation") == true)
    }
}
