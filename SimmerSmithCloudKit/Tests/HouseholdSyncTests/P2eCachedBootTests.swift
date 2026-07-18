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
        relay.emit(.participantRevoked)
        relay.emit(.accountChanged)

        relay.install((
            storeChanged: { events.append("store") },
            syncError: { _ in events.append("error") },
            recordSaved: { events.append("saved:\($0)") },
            durabilityFailure: { events.append("durability:\($0.message)") },
            participantRevoked: { events.append("revoked") },
            accountChanged: { events.append("account") }))

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
                accountChanged: { events.append("account") }))
            installationFinished.signal()
        }

        #expect(firstCallbackStarted.wait(timeout: .now() + 2) == .success)
        relay.emit(.recordSaved("later"))
        finishFirstCallback.signal()
        #expect(installationFinished.wait(timeout: .now() + 2) == .success)
        #expect(events.values == ["store-start", "store-end", "saved:later"])
    }
}

private final class CallbackEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
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
