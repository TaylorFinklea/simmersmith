import CloudKit
import Foundation
import HouseholdSync
import Testing

// e0a P2 spec §3.3 deterministic real-engine probe: P2 bootstrap resume is only viable if the
// public CKSyncEngine state contract holds on the pinned SDK — a non-automatic engine's pending
// changes survive a genuine `State.Serialization` round-trip into a second engine, and the
// public `state.add`/`state.remove` APIs reconcile that restored set. If this probe fails,
// P2c stops and P2d must not begin.
//
// This lives in the app-target suite, not the package suite: constructing any CKContainer in
// the unsigned `swift test` host hard-traps (EXC_BREAKPOINT inside CloudKit) before the engine
// exists, so the probe must run inside the entitled simulator-hosted app. The probe never
// syncs — `automaticallySync = false` and no send/fetch is requested — so it exercises only
// local engine state, regardless of iCloud account status.

private final class ProbeDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<CKSyncEngine.State.Serialization>.Continuation
    let serializations: AsyncStream<CKSyncEngine.State.Serialization>

    init() {
        (serializations, continuation) = AsyncStream.makeStream(
            of: CKSyncEngine.State.Serialization.self)
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        if case .stateUpdate(let update) = event {
            continuation.yield(update.stateSerialization)
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        nil
    }
}

private func makeNonAutomaticEngine(
    state: CKSyncEngine.State.Serialization?,
    delegate: ProbeDelegate
) -> CKSyncEngine {
    let database = CKContainer(identifier: MirrorScope.currentContainerIdentifier)
        .privateCloudDatabase
    var configuration = CKSyncEngine.Configuration(
        database: database,
        stateSerialization: state,
        delegate: delegate)
    configuration.automaticallySync = false
    return CKSyncEngine(configuration)
}

@Test("SDK probe: pending changes survive State.Serialization round-trip into a second engine")
func syncEngineStateSerializationContractHolds() async throws {
    let zone = CKRecordZone.ID(zoneName: "household", ownerName: CKCurrentUserDefaultName)
    let saveID = CKRecord.ID(recordName: "probe-save", zoneID: zone)
    let deleteID = CKRecord.ID(recordName: "probe-delete", zoneID: zone)
    let expected: Set<CKSyncEngine.PendingRecordZoneChange> =
        [.saveRecord(saveID), .deleteRecord(deleteID)]

    let sourceDelegate = ProbeDelegate()
    let sourceEngine = makeNonAutomaticEngine(state: nil, delegate: sourceDelegate)
    sourceEngine.state.add(pendingRecordZoneChanges: [
        .saveRecord(saveID),
        .deleteRecord(deleteID),
    ])
    #expect(Set(sourceEngine.state.pendingRecordZoneChanges) == expected)

    // The engine may emit several stateUpdate events; the contract is proven when any genuine
    // captured serialization — after an encode/decode round-trip — reconstructs the exact
    // pending set in a fresh non-automatic engine before the deadline.
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var restoredEngine: CKSyncEngine?
    var lastObserved: Set<CKSyncEngine.PendingRecordZoneChange> = []
    for await serialization in sourceDelegate.serializations {
        let encoded = try JSONEncoder().encode(serialization)
        let decoded = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self, from: encoded)
        let candidate = makeNonAutomaticEngine(state: decoded, delegate: ProbeDelegate())
        lastObserved = Set(candidate.state.pendingRecordZoneChanges)
        if lastObserved == expected {
            restoredEngine = candidate
            break
        }
        guard ContinuousClock.now < deadline else { break }
    }

    let restored = try #require(
        restoredEngine,
        "no captured State.Serialization reconstructed the pending set; last observed: \(lastObserved)")
    #expect(restored.state.pendingDatabaseChanges.isEmpty)

    // Public reconciliation contract: remove one restored operation, add a new one, and require
    // the reprojected set to reflect exactly that diff.
    let reconcileID = CKRecord.ID(recordName: "probe-reconcile", zoneID: zone)
    let reconciled: Set<CKSyncEngine.PendingRecordZoneChange> =
        [.saveRecord(saveID), .saveRecord(reconcileID)]
    restored.state.remove(pendingRecordZoneChanges: [.deleteRecord(deleteID)])
    restored.state.add(pendingRecordZoneChanges: [.saveRecord(reconcileID)])
    #expect(Set(restored.state.pendingRecordZoneChanges) == reconciled)

    // Removing an operation that is not pending must be a no-op, not a trap or a phantom entry.
    restored.state.remove(pendingRecordZoneChanges: [.deleteRecord(deleteID)])
    #expect(Set(restored.state.pendingRecordZoneChanges) == reconciled)
}
