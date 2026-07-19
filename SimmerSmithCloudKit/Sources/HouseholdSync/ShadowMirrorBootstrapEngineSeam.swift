#if canImport(CloudKit)
import CloudKit
import Foundation

// e0a P2 spec §3.3: the package-testable core of gated resumable engine construction. The
// projection types canonicalize the public CKSyncEngine pending cases to the record-ID level
// the durable plan speaks; the delegate gate holds every delegate entry point closed until the
// candidate engine's state has been proven against that plan.

/// One canonical engine-level pending change: `CKRecord.ID` (record name + zone) plus
/// operation. Deliberately type-free — `CKSyncEngine.PendingRecordZoneChange` carries no record
/// type, so reconciliation compares at CloudKit's own record-identifier equivalence.
public struct MirrorEnginePendingChange: Equatable, Hashable, Sendable {
    public let recordName: String
    public let zoneOwnerName: String
    public let zoneName: String
    public let operation: MirrorOutboxIntent.Operation

    public init(
        recordName: String,
        zoneOwnerName: String,
        zoneName: String,
        operation: MirrorOutboxIntent.Operation
    ) {
        self.recordName = recordName
        self.zoneOwnerName = zoneOwnerName
        self.zoneName = zoneName
        self.operation = operation
    }

    public init(recordID: CKRecord.ID, operation: MirrorOutboxIntent.Operation) {
        self.init(
            recordName: recordID.recordName,
            zoneOwnerName: recordID.zoneID.ownerName,
            zoneName: recordID.zoneID.zoneName,
            operation: operation)
    }

    /// Fails on an unknown future public case so the caller fails closed instead of guessing.
    public init?(_ change: CKSyncEngine.PendingRecordZoneChange) {
        switch change {
        case .saveRecord(let recordID):
            self.init(recordID: recordID, operation: .save)
        case .deleteRecord(let recordID):
            self.init(recordID: recordID, operation: .delete)
        @unknown default:
            return nil
        }
    }

    public init(_ normalized: MirrorNormalizedPendingChange) {
        self.init(
            recordName: normalized.identity.recordName,
            zoneOwnerName: normalized.identity.zoneOwnerName,
            zoneName: normalized.identity.zoneName,
            operation: normalized.operation)
    }

    public var recordID: CKRecord.ID {
        CKRecord.ID(
            recordName: recordName,
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: zoneOwnerName))
    }

    public var pendingRecordZoneChange: CKSyncEngine.PendingRecordZoneChange {
        switch operation {
        case .save: return .saveRecord(recordID)
        case .delete: return .deleteRecord(recordID)
        }
    }
}

/// Canonical zone-level projection of `CKSyncEngine.PendingDatabaseChange`. Cached resume
/// expects an empty set; the projection exists so a mismatch is diagnosable and an unknown
/// future case fails closed.
public enum MirrorEngineDatabaseChange: Equatable, Hashable, Sendable {
    case saveZone(zoneOwnerName: String, zoneName: String)
    case deleteZone(zoneOwnerName: String, zoneName: String)

    public init?(_ change: CKSyncEngine.PendingDatabaseChange) {
        switch change {
        case .saveZone(let zone):
            self = .saveZone(
                zoneOwnerName: zone.zoneID.ownerName, zoneName: zone.zoneID.zoneName)
        case .deleteZone(let zoneID):
            self = .deleteZone(zoneOwnerName: zoneID.ownerName, zoneName: zoneID.zoneName)
        @unknown default:
            return nil
        }
    }
}

/// The closed bootstrap delegate gate (spec §3.3). Every delegate entry point of a candidate
/// engine awaits this gate; construction resolves it exactly once — `open` after the engine's
/// direct state matches the durable plan, `rejected` on any validation failure. Terminal
/// outcomes latch: the first resolution wins and every later or earlier waiter observes it.
public final class MirrorBootstrapDelegateGate: @unchecked Sendable {
    public enum Outcome: Equatable, Sendable {
        case open
        case rejected
        /// A lifecycle boundary froze the candidate before activation. Cached content remains
        /// unactivated while queued delegate work is terminally released into discard behavior.
        case discarded
    }

    private let lock = NSLock()
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    public init() {}

    public var resolvedOutcome: Outcome? {
        lock.withLock { outcome }
    }

    public func awaitOutcome() async -> Outcome {
        if let outcome = resolvedOutcome { return outcome }
        return await withCheckedContinuation { continuation in
            let resolved: Outcome? = lock.withLock {
                if let outcome { return outcome }
                waiters.append(continuation)
                return nil
            }
            if let resolved { continuation.resume(returning: resolved) }
        }
    }

    @discardableResult
    public func resolve(_ outcome: Outcome) -> Bool {
        let resolution: (won: Bool, released: [CheckedContinuation<Outcome, Never>]) = lock.withLock {
            guard self.outcome == nil else { return (false, []) }
            self.outcome = outcome
            let released = waiters
            waiters = []
            return (true, released)
        }
        for waiter in resolution.released {
            waiter.resume(returning: outcome)
        }
        return resolution.won
    }
}

/// One immutable verified bootstrap handed to the engine construction seam: the materialized
/// snapshot, its continuing checkpoint writer (which holds the generation lease and keeps
/// journaling after resume), and the live CloudKit-proved identity the seam rechecks.
public struct MirrorBootstrapCandidate {
    public let bootstrap: MirrorBootstrap
    public let writer: ShadowMirrorCheckpointWriter
    public let expectedIdentity: MirrorBootstrapExpectedIdentity
    public let observationContext: HouseholdSyncBootstrapObservationContext?

    public init(
        bootstrap: MirrorBootstrap,
        writer: ShadowMirrorCheckpointWriter,
        expectedIdentity: MirrorBootstrapExpectedIdentity
    ) {
        self.bootstrap = bootstrap
        self.writer = writer
        self.expectedIdentity = expectedIdentity
        self.observationContext = bootstrap.observationContext
    }
}

public enum MirrorBootstrapEngineError: Error, Equatable {
    /// `activateBootstrapCandidate` was called on a non-bootstrap engine or after the gate
    /// already resolved.
    case activationUnavailable
}

/// The live CloudKit-proved identity the construction seam rechecks against the bootstrap
/// scope, even though the catalog already checked it (spec §3.3).
public struct MirrorBootstrapExpectedIdentity: Equatable, Sendable {
    public let accountRecordName: String
    public let role: MirrorRole
    public let zone: MirrorZoneReference
    public let participantMarkerZone: MirrorZoneReference?

    public init(
        accountRecordName: String,
        role: MirrorRole,
        zone: MirrorZoneReference,
        participantMarkerZone: MirrorZoneReference?
    ) {
        self.accountRecordName = accountRecordName
        self.role = role
        self.zone = zone
        self.participantMarkerZone = participantMarkerZone
    }
}

public enum MirrorBootstrapReconciliationError: Error, Equatable {
    /// The durable plan itself violated its invariants (duplicate record ID, foreign zone) —
    /// upstream materialization should have made this impossible.
    case planInvariantBreach
    /// A serialized pending change references a zone outside the bootstrap scope.
    case foreignZonePending(MirrorEnginePendingChange)
    /// A serialized pending change has neither a durable target nor a durable removal proof.
    case unprovenSerializedPending(MirrorEnginePendingChange)
    /// The public pending enum gained a case this build cannot canonicalize.
    case unknownPendingChangeCase
    case unknownDatabaseChangeCase
    /// Cached resume expects an empty pending-database set.
    case pendingDatabaseChangesPresent(count: Int)
    /// The post-reconciliation engine state does not exactly equal the durable plan.
    case reprojectionMismatch
    /// The live account/role/zone/marker identity does not match the bootstrap scope.
    case identityMismatch
    /// Cached resume requires the recovered `zoneEnsured` flag.
    case zoneNotEnsured
}

/// Pure reconciliation core (spec §3.3 step 4–5). Decides — without touching an engine — which
/// serialized pending operations to remove, which durable-plan operations to add, and when to
/// fail closed instead. `HouseholdSyncEngine` applies the returned actions through the public
/// `state.remove`/`state.add` APIs and re-verifies the reprojected state.
public enum MirrorBootstrapReconciler {
    public struct Actions: Equatable, Sendable {
        public let removals: [MirrorEnginePendingChange]
        public let additions: [MirrorEnginePendingChange]

        public init(removals: [MirrorEnginePendingChange], additions: [MirrorEnginePendingChange]) {
            self.removals = removals
            self.additions = additions
        }
    }

    public static func planRecordZoneReconciliation(
        serialized: [MirrorEnginePendingChange],
        plan: [MirrorNormalizedPendingChange],
        removalProofs: [MirrorOutboxRemovalProof],
        scope: MirrorScope
    ) throws -> Actions {
        let targets = try canonicalTargets(plan: plan, scope: scope)
        let serializedSet = Set(serialized)
        var removals: [MirrorEnginePendingChange] = []
        for change in serialized.sorted(by: orderChanges) {
            guard change.zoneOwnerName == scope.zoneOwnerName,
                  change.zoneName == scope.zoneName else {
                throw MirrorBootstrapReconciliationError.foreignZonePending(change)
            }
            if targets.contains(change) { continue }
            let proven = removalProofs.contains { proof in
                proof.identity.recordName == change.recordName
                    && proof.identity.zoneOwnerName == change.zoneOwnerName
                    && proof.identity.zoneName == change.zoneName
                    && proof.operation == change.operation
            }
            guard proven else {
                throw MirrorBootstrapReconciliationError.unprovenSerializedPending(change)
            }
            removals.append(change)
        }
        let additions = targets
            .subtracting(serializedSet)
            .sorted(by: orderChanges)
        return Actions(removals: removals, additions: additions)
    }

    public static func validateDatabaseState(serialized: [MirrorEngineDatabaseChange]) throws {
        guard serialized.isEmpty else {
            throw MirrorBootstrapReconciliationError.pendingDatabaseChangesPresent(
                count: serialized.count)
        }
    }

    public static func verifyExactReprojection(
        serialized: [MirrorEnginePendingChange],
        plan: [MirrorNormalizedPendingChange]
    ) throws {
        let targets = Set(plan.map(MirrorEnginePendingChange.init))
        guard serialized.count == targets.count,
              Set(serialized) == targets else {
            throw MirrorBootstrapReconciliationError.reprojectionMismatch
        }
    }

    public static func validateCandidate(
        scope: MirrorScope,
        zoneEnsured: Bool,
        expected: MirrorBootstrapExpectedIdentity,
        engineZoneID: CKRecordZone.ID
    ) throws {
        do {
            try scope.validate()
        } catch {
            throw MirrorBootstrapReconciliationError.identityMismatch
        }
        guard scope.accountRecordName == expected.accountRecordName,
              scope.role == expected.role,
              scope.zoneOwnerName == expected.zone.ownerName,
              scope.zoneName == expected.zone.zoneName,
              engineZoneID.ownerName == scope.zoneOwnerName,
              engineZoneID.zoneName == scope.zoneName else {
            throw MirrorBootstrapReconciliationError.identityMismatch
        }
        switch scope.role {
        case .owner:
            // An owner scope must never resume while a participant marker exists — the marker
            // means this device currently belongs to someone else's household.
            guard expected.participantMarkerZone == nil else {
                throw MirrorBootstrapReconciliationError.identityMismatch
            }
        case .participant:
            guard let marker = expected.participantMarkerZone,
                  marker.ownerName == scope.zoneOwnerName,
                  marker.zoneName == scope.zoneName else {
                throw MirrorBootstrapReconciliationError.identityMismatch
            }
        }
        guard zoneEnsured else {
            throw MirrorBootstrapReconciliationError.zoneNotEnsured
        }
    }

    /// Seeds the engine's per-record local mutation generations above every recovered intent
    /// generation, collapsing record types to CloudKit record-identifier equivalence.
    public static func seededLocalGenerations(
        from maxMutationGenerationByIdentity: [MirrorRecordIdentity: UInt64]
    ) -> [CKRecord.ID: Int] {
        var seeded: [CKRecord.ID: Int] = [:]
        for (identity, generation) in maxMutationGenerationByIdentity {
            let recordID = CKRecord.ID(
                recordName: identity.recordName,
                zoneID: CKRecordZone.ID(
                    zoneName: identity.zoneName, ownerName: identity.zoneOwnerName))
            seeded[recordID] = max(seeded[recordID] ?? 0, Int(clamping: generation))
        }
        return seeded
    }

    private static func canonicalTargets(
        plan: [MirrorNormalizedPendingChange],
        scope: MirrorScope
    ) throws -> Set<MirrorEnginePendingChange> {
        var targets: Set<MirrorEnginePendingChange> = []
        var recordIDs: Set<CKRecord.ID> = []
        for entry in plan {
            let change = MirrorEnginePendingChange(entry)
            guard change.zoneOwnerName == scope.zoneOwnerName,
                  change.zoneName == scope.zoneName,
                  recordIDs.insert(change.recordID).inserted else {
                throw MirrorBootstrapReconciliationError.planInvariantBreach
            }
            targets.insert(change)
        }
        return targets
    }

    private static func orderChanges(
        _ lhs: MirrorEnginePendingChange, _ rhs: MirrorEnginePendingChange
    ) -> Bool {
        (lhs.zoneOwnerName, lhs.zoneName, lhs.recordName, lhs.operation.rawValue)
            < (rhs.zoneOwnerName, rhs.zoneName, rhs.recordName, rhs.operation.rawValue)
    }
}
#endif
