#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

// e0a P2 spec §3.3: the engine-seam reconciliation core. Everything here is deliberately
// package-testable — canonical projection of the public CKSyncEngine pending cases, the
// delegate gate, and the durable-plan reconciler — because the unsigned package host cannot
// construct any CloudKit container. The real-engine application of these decisions is proven
// by the app-target suite (HouseholdSyncEngineBootstrapTests).

private let seamZone = CKRecordZone.ID(zoneName: "household", ownerName: "user-a")

private func seamRecordID(_ name: String, zone: CKRecordZone.ID = seamZone) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zone)
}

private func seamIdentity(
    _ name: String,
    type: String = "Recipe",
    zone: CKRecordZone.ID = seamZone
) -> MirrorRecordIdentity {
    MirrorRecordIdentity(
        recordType: type,
        recordName: name,
        zoneOwnerName: zone.ownerName,
        zoneName: zone.zoneName)
}

// MARK: - Canonical projection

@Test("engine pending cases project to canonical record-ID-level changes")
func enginePendingCaseProjection() throws {
    let save = MirrorEnginePendingChange(.saveRecord(seamRecordID("r1")))
    #expect(save == MirrorEnginePendingChange(
        recordName: "r1", zoneOwnerName: "user-a", zoneName: "household", operation: .save))

    let delete = MirrorEnginePendingChange(.deleteRecord(seamRecordID("r2")))
    #expect(delete == MirrorEnginePendingChange(
        recordName: "r2", zoneOwnerName: "user-a", zoneName: "household", operation: .delete))

    // The canonical value converts back into the exact public engine case.
    let restored = try #require(save).pendingRecordZoneChange
    #expect(restored == .saveRecord(seamRecordID("r1")))
    let restoredDelete = try #require(delete).pendingRecordZoneChange
    #expect(restoredDelete == .deleteRecord(seamRecordID("r2")))
}

@Test("normalized plan entries project at record-ID level, dropping the record type")
func normalizedPlanProjectionDropsRecordType() {
    let a = MirrorEnginePendingChange(MirrorNormalizedPendingChange(
        identity: seamIdentity("r1", type: "Recipe"), operation: .save))
    let b = MirrorEnginePendingChange(MirrorNormalizedPendingChange(
        identity: seamIdentity("r1", type: "GroceryItem"), operation: .save))
    // CKRecord.ID equivalence ignores recordType — both identities collapse to one change.
    #expect(a == b)
    #expect(a.recordID == seamRecordID("r1"))
}

@Test("engine database cases project to canonical zone-level changes")
func engineDatabaseCaseProjection() {
    let save = MirrorEngineDatabaseChange(.saveZone(CKRecordZone(zoneID: seamZone)))
    #expect(save == .saveZone(zoneOwnerName: "user-a", zoneName: "household"))

    let delete = MirrorEngineDatabaseChange(.deleteZone(seamZone))
    #expect(delete == .deleteZone(zoneOwnerName: "user-a", zoneName: "household"))
}

// MARK: - Delegate gate

@Test("a resolved gate answers immediately with its terminal outcome")
func gateAnswersImmediatelyOnceResolved() async {
    let opened = MirrorBootstrapDelegateGate()
    opened.resolve(.open)
    #expect(opened.resolvedOutcome == .open)
    #expect(await opened.awaitOutcome() == .open)

    let rejected = MirrorBootstrapDelegateGate()
    rejected.resolve(.rejected)
    #expect(rejected.resolvedOutcome == .rejected)
    #expect(await rejected.awaitOutcome() == .rejected)
}

@Test("waiters suspend on an unresolved gate and release together on resolution")
func gateHoldsWaitersUntilResolution() async throws {
    let gate = MirrorBootstrapDelegateGate()
    let released = SeamCounter()

    let waiters = (0..<3).map { _ in
        Task {
            let outcome = await gate.awaitOutcome()
            await released.increment()
            return outcome
        }
    }
    // Give every waiter time to reach the gate; none may pass while unresolved.
    for _ in 0..<50 { await Task.yield() }
    #expect(await released.value == 0)
    #expect(gate.resolvedOutcome == nil)

    gate.resolve(.open)
    for waiter in waiters {
        #expect(await waiter.value == .open)
    }
    #expect(await released.value == 3)
}

@Test("the first terminal outcome wins; a later resolve cannot flip the gate")
func gateOutcomeLatches() async {
    let gate = MirrorBootstrapDelegateGate()
    gate.resolve(.rejected)
    gate.resolve(.open)
    #expect(gate.resolvedOutcome == .rejected)
    #expect(await gate.awaitOutcome() == .rejected)
}

private actor SeamCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

// MARK: - Reconciliation planner

private func seamScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "user-a", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .owner, databaseScope: .private)
}

private func planEntry(
    _ name: String,
    _ operation: MirrorOutboxIntent.Operation,
    type: String = "Recipe",
    zone: CKRecordZone.ID = seamZone
) -> MirrorNormalizedPendingChange {
    MirrorNormalizedPendingChange(
        identity: seamIdentity(name, type: type, zone: zone), operation: operation)
}

private func proof(
    _ name: String,
    _ operation: MirrorOutboxIntent.Operation,
    reason: MirrorOutboxRemovalProof.Reason,
    zone: CKRecordZone.ID = seamZone
) -> MirrorOutboxRemovalProof {
    MirrorOutboxRemovalProof(
        identity: seamIdentity(name, zone: zone),
        operation: operation,
        sequence: 7,
        mutationGeneration: 1,
        reason: reason)
}

private func serialized(
    _ name: String,
    _ operation: MirrorOutboxIntent.Operation,
    zone: CKRecordZone.ID = seamZone
) -> MirrorEnginePendingChange {
    MirrorEnginePendingChange(recordID: seamRecordID(name, zone: zone), operation: operation)
}

@Test("a serialized set that exactly matches the plan needs no reconciliation actions")
func reconcilerExactMatchNeedsNoActions() throws {
    let actions = try MirrorBootstrapReconciler.planRecordZoneReconciliation(
        serialized: [serialized("r1", .save), serialized("r2", .delete)],
        plan: [planEntry("r1", .save), planEntry("r2", .delete)],
        removalProofs: [],
        scope: seamScope())
    #expect(actions.removals.isEmpty)
    #expect(actions.additions.isEmpty)
}

@Test("a stale serialized pending is removed only under a durable removal proof")
func reconcilerRemovesOnlyWithProof() throws {
    let proven = try MirrorBootstrapReconciler.planRecordZoneReconciliation(
        serialized: [serialized("r1", .save), serialized("r2", .save)],
        plan: [planEntry("r1", .save)],
        removalProofs: [proof("r2", .save, reason: .acknowledged)],
        scope: seamScope())
    #expect(proven.removals == [serialized("r2", .save)])
    #expect(proven.additions.isEmpty)

    #expect(throws: MirrorBootstrapReconciliationError.unprovenSerializedPending(
        serialized("r2", .save))
    ) {
        try MirrorBootstrapReconciler.planRecordZoneReconciliation(
            serialized: [serialized("r1", .save), serialized("r2", .save)],
            plan: [planEntry("r1", .save)],
            removalProofs: [],
            scope: seamScope())
    }
}

@Test("a proof for the same record ID but the wrong operation does not license removal")
func reconcilerProofOperationMustMatch() {
    #expect(throws: MirrorBootstrapReconciliationError.unprovenSerializedPending(
        serialized("r2", .save))
    ) {
        try MirrorBootstrapReconciler.planRecordZoneReconciliation(
            serialized: [serialized("r2", .save)],
            plan: [],
            removalProofs: [proof("r2", .delete, reason: .acknowledged)],
            scope: seamScope())
    }
}

@Test("an opposite serialized operation is swapped for the plan's under a supersession proof")
func reconcilerSwapsOppositeOperation() throws {
    let actions = try MirrorBootstrapReconciler.planRecordZoneReconciliation(
        serialized: [serialized("r1", .save)],
        plan: [planEntry("r1", .delete)],
        removalProofs: [proof("r1", .save, reason: .supersededByNewerMutation)],
        scope: seamScope())
    #expect(actions.removals == [serialized("r1", .save)])
    #expect(actions.additions == [serialized("r1", .delete)])
}

@Test("a plan entry missing from the serialized state is added")
func reconcilerAddsMissingTarget() throws {
    let actions = try MirrorBootstrapReconciler.planRecordZoneReconciliation(
        serialized: [],
        plan: [planEntry("r3", .save)],
        removalProofs: [],
        scope: seamScope())
    #expect(actions.removals.isEmpty)
    #expect(actions.additions == [serialized("r3", .save)])
}

@Test("a serialized pending outside the bootstrap zone fails closed even with a proof")
func reconcilerRejectsForeignZonePending() {
    let foreignZone = CKRecordZone.ID(zoneName: "household", ownerName: "user-z")
    #expect(throws: MirrorBootstrapReconciliationError.foreignZonePending(
        serialized("r9", .save, zone: foreignZone))
    ) {
        try MirrorBootstrapReconciler.planRecordZoneReconciliation(
            serialized: [serialized("r9", .save, zone: foreignZone)],
            plan: [],
            removalProofs: [proof("r9", .save, reason: .acknowledged, zone: foreignZone)],
            scope: seamScope())
    }
}

@Test("a durable plan that repeats a record ID or leaves the scope zone is an invariant breach")
func reconcilerRejectsInvalidPlan() {
    #expect(throws: MirrorBootstrapReconciliationError.planInvariantBreach) {
        try MirrorBootstrapReconciler.planRecordZoneReconciliation(
            serialized: [],
            plan: [
                planEntry("r1", .save, type: "Recipe"),
                planEntry("r1", .delete, type: "GroceryItem"),
            ],
            removalProofs: [],
            scope: seamScope())
    }

    let foreignZone = CKRecordZone.ID(zoneName: "household", ownerName: "user-z")
    #expect(throws: MirrorBootstrapReconciliationError.planInvariantBreach) {
        try MirrorBootstrapReconciler.planRecordZoneReconciliation(
            serialized: [],
            plan: [planEntry("r1", .save, zone: foreignZone)],
            removalProofs: [],
            scope: seamScope())
    }
}

@Test("cached resume requires an empty pending database set")
func reconcilerDatabaseStateMustBeEmpty() throws {
    try MirrorBootstrapReconciler.validateDatabaseState(serialized: [])

    #expect(throws: MirrorBootstrapReconciliationError.pendingDatabaseChangesPresent(count: 2)) {
        try MirrorBootstrapReconciler.validateDatabaseState(serialized: [
            .saveZone(zoneOwnerName: "user-a", zoneName: "household"),
            .deleteZone(zoneOwnerName: "user-a", zoneName: "household"),
        ])
    }
}

@Test("reprojection must equal the durable plan exactly, one operation per record ID")
func reconcilerReprojectionExactness() throws {
    try MirrorBootstrapReconciler.verifyExactReprojection(
        serialized: [serialized("r1", .save), serialized("r2", .delete)],
        plan: [planEntry("r2", .delete), planEntry("r1", .save)])

    #expect(throws: MirrorBootstrapReconciliationError.reprojectionMismatch) {
        try MirrorBootstrapReconciler.verifyExactReprojection(
            serialized: [serialized("r1", .save), serialized("r1", .delete)],
            plan: [planEntry("r1", .save)])
    }
    #expect(throws: MirrorBootstrapReconciliationError.reprojectionMismatch) {
        try MirrorBootstrapReconciler.verifyExactReprojection(
            serialized: [],
            plan: [planEntry("r1", .save)])
    }
}

// MARK: - Candidate identity validation

private func expectedOwnerIdentity() -> MirrorBootstrapExpectedIdentity {
    MirrorBootstrapExpectedIdentity(
        accountRecordName: "user-a",
        role: .owner,
        zone: MirrorZoneReference(ownerName: "user-a", zoneName: "household"),
        participantMarkerZone: nil)
}

@Test("the construction seam rechecks the live identity against the bootstrap scope")
func candidateValidationRechecksIdentity() throws {
    try MirrorBootstrapReconciler.validateCandidate(
        scope: seamScope(),
        zoneEnsured: true,
        expected: expectedOwnerIdentity(),
        engineZoneID: seamZone)

    let mismatches: [MirrorBootstrapExpectedIdentity] = [
        MirrorBootstrapExpectedIdentity(
            accountRecordName: "user-b", role: .owner,
            zone: MirrorZoneReference(ownerName: "user-a", zoneName: "household"),
            participantMarkerZone: nil),
        MirrorBootstrapExpectedIdentity(
            accountRecordName: "user-a", role: .participant,
            zone: MirrorZoneReference(ownerName: "user-a", zoneName: "household"),
            participantMarkerZone: MirrorZoneReference(ownerName: "user-a", zoneName: "household")),
        MirrorBootstrapExpectedIdentity(
            accountRecordName: "user-a", role: .owner,
            zone: MirrorZoneReference(ownerName: "user-x", zoneName: "household"),
            participantMarkerZone: nil),
        MirrorBootstrapExpectedIdentity(
            accountRecordName: "user-a", role: .owner,
            zone: MirrorZoneReference(ownerName: "user-a", zoneName: "other-zone"),
            participantMarkerZone: nil),
        // An owner candidate while a participant marker exists must never be selected.
        MirrorBootstrapExpectedIdentity(
            accountRecordName: "user-a", role: .owner,
            zone: MirrorZoneReference(ownerName: "user-a", zoneName: "household"),
            participantMarkerZone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household")),
    ]
    for expected in mismatches {
        #expect(throws: MirrorBootstrapReconciliationError.identityMismatch) {
            try MirrorBootstrapReconciler.validateCandidate(
                scope: seamScope(),
                zoneEnsured: true,
                expected: expected,
                engineZoneID: seamZone)
        }
    }

    // The engine's own zone must be the bootstrap scope's zone.
    #expect(throws: MirrorBootstrapReconciliationError.identityMismatch) {
        try MirrorBootstrapReconciler.validateCandidate(
            scope: seamScope(),
            zoneEnsured: true,
            expected: expectedOwnerIdentity(),
            engineZoneID: CKRecordZone.ID(zoneName: "household", ownerName: "user-z"))
    }
}

@Test("participant candidates require the marker's exact zone")
func candidateValidationParticipantMarker() throws {
    let scope = MirrorScope(
        accountRecordName: "user-b", zoneOwnerName: "owner-x", zoneName: "household",
        householdID: "household-x", role: .participant, databaseScope: .shared)
    let zone = CKRecordZone.ID(zoneName: "household", ownerName: "owner-x")

    try MirrorBootstrapReconciler.validateCandidate(
        scope: scope,
        zoneEnsured: true,
        expected: MirrorBootstrapExpectedIdentity(
            accountRecordName: "user-b", role: .participant,
            zone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household"),
            participantMarkerZone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household")),
        engineZoneID: zone)

    // A nil marker models an unavailable participant marker: never resume from cache.
    #expect(throws: MirrorBootstrapReconciliationError.identityMismatch) {
        try MirrorBootstrapReconciler.validateCandidate(
            scope: scope,
            zoneEnsured: true,
            expected: MirrorBootstrapExpectedIdentity(
                accountRecordName: "user-b", role: .participant,
                zone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household"),
                participantMarkerZone: nil),
            engineZoneID: zone)
    }

    #expect(throws: MirrorBootstrapReconciliationError.identityMismatch) {
        try MirrorBootstrapReconciler.validateCandidate(
            scope: scope,
            zoneEnsured: true,
            expected: MirrorBootstrapExpectedIdentity(
                accountRecordName: "user-b", role: .participant,
                zone: MirrorZoneReference(ownerName: "owner-x", zoneName: "household"),
                participantMarkerZone: MirrorZoneReference(ownerName: "owner-y", zoneName: "household")),
            engineZoneID: zone)
    }
}

@Test("cached resume requires recovered zoneEnsured")
func candidateValidationRequiresZoneEnsured() {
    #expect(throws: MirrorBootstrapReconciliationError.zoneNotEnsured) {
        try MirrorBootstrapReconciler.validateCandidate(
            scope: seamScope(),
            zoneEnsured: false,
            expected: expectedOwnerIdentity(),
            engineZoneID: seamZone)
    }
}

// MARK: - Generation seeding

@Test("local mutation generations seed above every recovered intent generation")
func generationSeedingResumesAboveRecoveredMax() {
    let seeded = MirrorBootstrapReconciler.seededLocalGenerations(from: [
        seamIdentity("r1", type: "Recipe"): 3,
        // Same record ID under a different record type collapses to the max.
        seamIdentity("r1", type: "GroceryItem"): 5,
        seamIdentity("r2"): 1,
    ])
    #expect(seeded == [
        seamRecordID("r1"): 5,
        seamRecordID("r2"): 1,
    ])
}
#endif
