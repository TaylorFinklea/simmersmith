#if canImport(CloudKit)
import CloudKit
import Foundation

// e0a P2 spec §3.1–3.2: read-only bootstrap catalog and materializer. The catalog receives the
// CloudKit-proved current account identity plus the requested role (and, for a participant, the
// marker's exact owner zone), scans anchored scope directories under the shadow-mirror root, and
// fail-closed selects at most one candidate. Every on-disk byte is untrusted until the full
// validation ladder holds; corruption quarantines only the exact scope. The catalog never
// trusts mtime and never persists an unscoped "last household" pointer.

public struct MirrorZoneReference: Equatable, Sendable {
    public let ownerName: String
    public let zoneName: String

    public init(ownerName: String, zoneName: String) {
        self.ownerName = ownerName
        self.zoneName = zoneName
    }
}

public enum MirrorBootstrapRequest: Equatable, Sendable {
    case owner(accountRecordName: String)
    /// `markerZone == nil` models an unavailable participant marker: it yields no cached
    /// bootstrap rather than guessing a zone.
    case participant(accountRecordName: String, markerZone: MirrorZoneReference?)
}

/// Privacy-safe anomaly diagnostics: counts only, never account/household/record identifiers.
public enum MirrorBootstrapDiagnostic: Equatable, Sendable {
    case multipleOwnerCandidates(count: Int)
}

/// One canonical `(CKRecord.ID, save|delete)` engine change reconstructed from the normalized
/// durable outbox — at most one per record identity.
public struct MirrorNormalizedPendingChange: Equatable, Hashable, Sendable {
    public let identity: MirrorRecordIdentity
    public let operation: MirrorOutboxIntent.Operation

    public init(identity: MirrorRecordIdentity, operation: MirrorOutboxIntent.Operation) {
        self.identity = identity
        self.operation = operation
    }
}

/// An immutable cached-resume bootstrap (spec §3.2). Everything here was validated against the
/// exact scope: decoded record clones whose assets resolve only to verified generation-local or
/// leased journal files, the decoded engine serialization, and the normalized durable plan.
public struct MirrorBootstrap {
    public let scope: MirrorScope
    public let generationID: String
    public let records: [CKRecord]
    public let engineStateSerialization: CKSyncEngine.State.Serialization
    public let zoneEnsured: Bool
    public let outbox: [MirrorOutboxIntent]
    public let pendingChanges: [MirrorNormalizedPendingChange]
    public let removalProofs: [MirrorOutboxRemovalProof]
    public let maxMutationGenerationByIdentity: [MirrorRecordIdentity: UInt64]
    public let journalHighWater: UInt64
    public let interventionCount: Int
    /// Cached UI data only until authority is established.
    public let receipts: MirrorReceiptIndex
    public let lease: MirrorGenerationLease
    public let observationContext: HouseholdSyncBootstrapObservationContext?
}

/// A recovery-only plan (spec §3.2): the same normalized intents, proofs, generations, and asset
/// leases as a cached bootstrap, but no renderable base records and no serialized engine state.
/// The nil-state control path must fetch first and overlay these intents before `.ready`.
public struct MirrorRecoveryPlan {
    public let scope: MirrorScope
    public let outbox: [MirrorOutboxIntent]
    public let pendingChanges: [MirrorNormalizedPendingChange]
    public let removalProofs: [MirrorOutboxRemovalProof]
    public let maxMutationGenerationByIdentity: [MirrorRecordIdentity: UInt64]
    public let journalHighWater: UInt64
    public let interventionCount: Int
    public let lease: MirrorGenerationLease

    public init(
        scope: MirrorScope,
        outbox: [MirrorOutboxIntent],
        pendingChanges: [MirrorNormalizedPendingChange],
        removalProofs: [MirrorOutboxRemovalProof],
        maxMutationGenerationByIdentity: [MirrorRecordIdentity: UInt64],
        journalHighWater: UInt64,
        interventionCount: Int,
        lease: MirrorGenerationLease
    ) {
        self.scope = scope
        self.outbox = outbox
        self.pendingChanges = pendingChanges
        self.removalProofs = removalProofs
        self.maxMutationGenerationByIdentity = maxMutationGenerationByIdentity
        self.journalHighWater = journalHighWater
        self.interventionCount = interventionCount
        self.lease = lease
    }
}

public struct MirrorRecoveryCandidate {
    public let plan: MirrorRecoveryPlan
    public let writer: ShadowMirrorCheckpointWriter

    public init(plan: MirrorRecoveryPlan, writer: ShadowMirrorCheckpointWriter) {
        self.plan = plan
        self.writer = writer
    }
}

public struct MirrorBootstrapCatalogResult {
    public enum Outcome {
        case cached(MirrorBootstrap, writer: ShadowMirrorCheckpointWriter)
        case recoveryOnly(MirrorRecoveryPlan, writer: ShadowMirrorCheckpointWriter)
        case none
    }

    public let outcome: Outcome
    public let diagnostics: [MirrorBootstrapDiagnostic]

    /// The context attached to a cached result, if any. It is carried by `MirrorBootstrap` into
    /// `MirrorBootstrapCandidate`; no caller needs to manually pair an observer with a clock.
    public var observationContext: HouseholdSyncBootstrapObservationContext? {
        guard case .cached(let bootstrap, _) = outcome else { return nil }
        return bootstrap.observationContext
    }
}

public enum ShadowMirrorBootstrapCatalog {
    private struct Candidate {
        let scope: MirrorScope
        let directory: URL
        let needsAnchorBackfill: Bool
    }

    public static func open(
        request: MirrorBootstrapRequest,
        rootDirectory: URL,
        observationContext: HouseholdSyncBootstrapObservationContext? = nil
    ) -> MirrorBootstrapCatalogResult {
        if case .participant(_, nil) = request {
            return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
        }
        let matching = scanCandidates(in: rootDirectory).filter { matches(request, $0.scope) }
        if case .owner = request, matching.count > 1 {
            return MirrorBootstrapCatalogResult(
                outcome: .none,
                diagnostics: [.multipleOwnerCandidates(count: matching.count)])
        }
        guard matching.count == 1, let selected = matching.first else {
            return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
        }
        let observer = observationContext?.observer
        observer?(.checkpointSelected)
        let validationStart = observationContext?.clock()
        if selected.needsAnchorBackfill {
            // One-time durable backfill through the P2b anchor primitive, allowed only after
            // the candidate's full bundle validation during the scan above.
            guard (try? ShadowMirrorCheckpointWriter.persistScopeAnchor(
                for: selected.scope, in: selected.directory)) != nil else {
                observer?(.candidateRejected(quarantined: false))
                return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
            }
        }
        do {
            let writer = try ShadowMirrorCheckpointWriter(
                scope: selected.scope, rootDirectory: rootDirectory)
            let normalized = try writer.normalizeForBootstrapSynchronously()
            guard normalized.snapshot.hasValidatedAnchor else {
                // Writer-side recovery quarantined the corrupt scope; fail closed.
                observer?(.candidateRejected(quarantined: true))
                return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
            }
            let validationDuration = validationStart.map {
                HouseholdSyncBootstrapObservationSupport.elapsed(
                    since: $0,
                    clock: observationContext!.clock)
            } ?? 0
            observer?(.bundleValidated(durationNanoseconds: validationDuration))
            let scopeDirectory = rootDirectory
                .appendingPathComponent(selected.scope.cacheKey, isDirectory: true)
            if let bundle = normalized.snapshot.current {
                // Legacy participant generations may carry an old Boolean `zoneEnsured` set
                // by a local save. They retain their WAL as recovery-only, but never render
                // cached content until a matching successful fetch writes typed proof.
                if selected.scope.role == .participant,
                   bundle.engineState.participantFetchProof?.isVerified != true {
                    let lease = writer.acquireGenerationLeaseSynchronously(
                        generationID: nil,
                        pinnedJournalAssetSequences: Set(
                            normalized.snapshot.recoveryState.outbox.map(\.sequence)))
                    do {
                        let plan = try ShadowMirrorBootstrapMaterializer.materializeRecoveryPlan(
                            normalized: normalized,
                            scopeDirectory: scopeDirectory,
                            lease: lease)
                        return MirrorBootstrapCatalogResult(
                            outcome: .recoveryOnly(plan, writer: writer), diagnostics: [])
                    } catch {
                        writer.quarantineAndReleaseGenerationLeaseSynchronously(lease.id)
                        observer?(.candidateRejected(quarantined: true))
                        return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
                    }
                }
                let lease = writer.acquireGenerationLeaseSynchronously(
                    generationID: bundle.manifest.generationID,
                    pinnedJournalAssetSequences: Set(
                        normalized.snapshot.recoveryState.outbox.map(\.sequence)))
                do {
                    let materializationStart = observationContext?.clock()
                    let bootstrap = try ShadowMirrorBootstrapMaterializer.materializeCached(
                        bundle: bundle,
                        normalized: normalized,
                        scopeDirectory: scopeDirectory,
                        lease: lease,
                        observationContext: observationContext)
                    let materializationDuration = materializationStart.map {
                        HouseholdSyncBootstrapObservationSupport.elapsed(
                            since: $0,
                            clock: observationContext!.clock)
                    } ?? 0
                    observer?(.bootstrapMaterialized(
                        durationNanoseconds: materializationDuration,
                        recordCount: bootstrap.records.count))
                    return MirrorBootstrapCatalogResult(
                        outcome: .cached(bootstrap, writer: writer),
                        diagnostics: [])
                } catch {
                    writer.quarantineAndReleaseGenerationLeaseSynchronously(lease.id)
                    observer?(.candidateRejected(quarantined: true))
                    return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
                }
            }
            if normalized.snapshot.isRecoveryOnly {
                let lease = writer.acquireGenerationLeaseSynchronously(
                    generationID: nil,
                    pinnedJournalAssetSequences: Set(
                        normalized.snapshot.recoveryState.outbox.map(\.sequence)))
                do {
                    let plan = try ShadowMirrorBootstrapMaterializer.materializeRecoveryPlan(
                        normalized: normalized,
                        scopeDirectory: scopeDirectory,
                        lease: lease)
                    return MirrorBootstrapCatalogResult(
                        outcome: .recoveryOnly(plan, writer: writer), diagnostics: [])
                } catch {
                    writer.quarantineAndReleaseGenerationLeaseSynchronously(lease.id)
                    observer?(.candidateRejected(quarantined: true))
                    return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
                }
            }
            observer?(.candidateRejected(quarantined: false))
            return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
        } catch {
            observer?(.candidateRejected(quarantined: true))
            return MirrorBootstrapCatalogResult(outcome: .none, diagnostics: [])
        }
    }

    private static func scanCandidates(in rootDirectory: URL) -> [Candidate] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var candidates: [Candidate] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  child.lastPathComponent != "quarantine",
                  !child.lastPathComponent.hasPrefix(".") else { continue }
            let anchorURL = child.appendingPathComponent("scope.anchor")
            if FileManager.default.fileExists(atPath: anchorURL.path) {
                guard let data = try? Data(contentsOf: anchorURL),
                      let anchor = try? JSONDecoder().decode(MirrorScopeAnchor.self, from: data),
                      (try? anchor.validate(for: anchor.scope, in: child)) != nil else {
                    // A malformed candidate is never selectable; its own writer quarantines it
                    // when that exact scope is opened.
                    continue
                }
                candidates.append(Candidate(
                    scope: anchor.scope, directory: child, needsAnchorBackfill: false))
            } else if let scope = ShadowMirrorCheckpointWriter.validatedPreP2Scope(in: child) {
                candidates.append(Candidate(
                    scope: scope, directory: child, needsAnchorBackfill: true))
            }
            // A journal-only directory without an anchor is refused: it can never invent its
            // scope from the hashed directory name. Independent CloudKit discovery may later
            // open it by exact scope through the writer's recovery path.
        }
        return candidates
    }

    private static func matches(_ request: MirrorBootstrapRequest, _ scope: MirrorScope) -> Bool {
        switch request {
        case .owner(let accountRecordName):
            return scope.role == .owner
                && scope.databaseScope == .private
                && scope.accountRecordName == accountRecordName
        case .participant(let accountRecordName, let markerZone):
            guard let markerZone else { return false }
            return scope.role == .participant
                && scope.databaseScope == .shared
                && scope.accountRecordName == accountRecordName
                && scope.zoneOwnerName == markerZone.ownerName
                && scope.zoneName == markerZone.zoneName
        }
    }
}

enum ShadowMirrorBootstrapMaterializer {
    static func materializeCached(
        bundle: MirrorCheckpointBundle,
        normalized: ShadowMirrorNormalizedBootstrapState,
        scopeDirectory: URL,
        lease: MirrorGenerationLease,
        observationContext: HouseholdSyncBootstrapObservationContext? = nil
    ) throws -> MirrorBootstrap {
        let scope = normalized.snapshot.scope
        try scope.validate()
        guard bundle.manifest.scope == scope else {
            throw MirrorCheckpointError.scopeMismatch
        }
        let recoveryState = normalized.snapshot.recoveryState
        try validateZoneMembership(
            scope: scope,
            identities: bundle.records.map(\.identity)
                + bundle.tombstones
                + bundle.receipts.receipts
                + bundle.outbox.map(intentIdentity)
                + recoveryState.outbox.map(intentIdentity)
                + recoveryState.tombstones)
        try validateUniqueRecordIDs(bundle.records.map(\.identity))
        let generationDirectory = scopeDirectory
            .appendingPathComponent("generations", isDirectory: true)
            .appendingPathComponent(bundle.manifest.generationID, isDirectory: true)
        let journalAssetRoot = scopeDirectory
            .appendingPathComponent("journal-assets", isDirectory: true)
        try validateAssetContainment(
            envelopes: bundle.records
                + bundle.outbox.compactMap(\.record)
                + recoveryState.outbox.compactMap(\.record),
            allowedRoots: [generationDirectory, journalAssetRoot])

        // Necessary but not sufficient (spec §3.2): the opaque bytes must decode as a
        // CKSyncEngine serialization; only P2d's engine-side reconciliation proves the decoded
        // state's pending set against this normalized durable plan.
        let serialization = try JSONDecoder().decode(
            CKSyncEngine.State.Serialization.self,
            from: bundle.engineState.serialization)

        // Materialize from the checkpoint records plus the writer's fully recovered state —
        // never from `loadCurrent` alone. Effective intents replay in sequence order; the
        // remote-delete-superseded payloads never reach projection.
        var store: [String: CKRecord] = [:]
        for envelope in bundle.records {
            store[recordIDKey(envelope.identity)] = try envelope.decode()
        }
        for intent in recoveryState.outbox.sorted(by: { $0.sequence < $1.sequence }) {
            switch intent.delivery.state {
            case .sent:
                throw MirrorCheckpointError.invalidOutbox(
                    "a sent row survived normalization")
            case .supersededByRemoteDelete:
                continue
            case .pending, .blockedPermanent:
                break
            }
            switch intent.operation {
            case .save:
                guard let envelope = intent.record else {
                    throw MirrorCheckpointError.invalidOutbox("save intent has no record")
                }
                store[recordIDKey(envelope.identity)] = try envelope.decode()
            case .delete:
                guard let tombstone = intent.tombstone else {
                    throw MirrorCheckpointError.invalidOutbox("delete intent has no tombstone")
                }
                store.removeValue(forKey: recordIDKey(tombstone))
            }
        }
        for tombstone in recoveryState.tombstones {
            guard store[recordIDKey(tombstone)] == nil else {
                throw MirrorCheckpointError.invalidOutbox(
                    "a tombstoned identity was resurrected by the overlay")
            }
        }

        let plan = try normalizedPlanValues(recoveryState: recoveryState)
        return MirrorBootstrap(
            scope: scope,
            generationID: bundle.manifest.generationID,
            records: store.keys.sorted().map { store[$0]! },
            engineStateSerialization: serialization,
            zoneEnsured: MirrorZoneEnsuredPolicy.value(
                role: scope.role,
                recoveredZoneEnsured: bundle.engineState.zoneEnsured,
                checkpointProof: bundle.engineState.participantFetchProof,
                fetch: .unverified),
            outbox: recoveryState.outbox,
            pendingChanges: plan.pendingChanges,
            removalProofs: normalized.removalProofs,
            maxMutationGenerationByIdentity: plan.maxGenerations,
            journalHighWater: recoveryState.lastIntentSequence,
            interventionCount: plan.interventionCount,
            receipts: bundle.receipts,
            lease: lease,
            observationContext: observationContext)
    }

    static func materializeRecoveryPlan(
        normalized: ShadowMirrorNormalizedBootstrapState,
        scopeDirectory: URL,
        lease: MirrorGenerationLease
    ) throws -> MirrorRecoveryPlan {
        let scope = normalized.snapshot.scope
        try scope.validate()
        let recoveryState = normalized.snapshot.recoveryState
        try validateZoneMembership(
            scope: scope,
            identities: recoveryState.outbox.map(intentIdentity) + recoveryState.tombstones)
        try validateAssetContainment(
            envelopes: recoveryState.outbox.compactMap(\.record),
            allowedRoots: [
                scopeDirectory.appendingPathComponent("journal-assets", isDirectory: true),
            ])
        let plan = try normalizedPlanValues(recoveryState: recoveryState)
        return MirrorRecoveryPlan(
            scope: scope,
            outbox: recoveryState.outbox,
            pendingChanges: plan.pendingChanges,
            removalProofs: normalized.removalProofs,
            maxMutationGenerationByIdentity: plan.maxGenerations,
            journalHighWater: recoveryState.lastIntentSequence,
            interventionCount: plan.interventionCount,
            lease: lease)
    }

    private static func normalizedPlanValues(
        recoveryState: ShadowMirrorCheckpointRecoveryState
    ) throws -> (
        pendingChanges: [MirrorNormalizedPendingChange],
        maxGenerations: [MirrorRecordIdentity: UInt64],
        interventionCount: Int
    ) {
        var pendingChanges: [MirrorNormalizedPendingChange] = []
        var maxGenerations: [MirrorRecordIdentity: UInt64] = [:]
        var interventionCount = 0
        for intent in recoveryState.outbox.sorted(by: { $0.sequence < $1.sequence }) {
            let identity = intentIdentity(intent)
            maxGenerations[identity] = max(
                maxGenerations[identity] ?? 0, intent.mutationGeneration)
            switch intent.delivery.state {
            case .pending:
                pendingChanges.append(MirrorNormalizedPendingChange(
                    identity: identity, operation: intent.operation))
            case .blockedPermanent, .supersededByRemoteDelete:
                interventionCount += 1
            case .sent:
                throw MirrorCheckpointError.invalidOutbox("a sent row survived normalization")
            }
        }
        let pendingIDs = pendingChanges.map { recordIDKey($0.identity) }
        guard Set(pendingIDs).count == pendingIDs.count else {
            throw MirrorCheckpointError.invalidOutbox(
                "more than one retryable engine change for a record ID")
        }
        return (pendingChanges, maxGenerations, interventionCount)
    }

    private static func validateZoneMembership(
        scope: MirrorScope,
        identities: [MirrorRecordIdentity]
    ) throws {
        for identity in identities {
            guard identity.zoneOwnerName == scope.zoneOwnerName,
                  identity.zoneName == scope.zoneName else {
                throw MirrorCheckpointError.scopeMismatch
            }
        }
    }

    private static func validateUniqueRecordIDs(_ identities: [MirrorRecordIdentity]) throws {
        let recordIDs = identities.map(recordIDKey)
        guard Set(recordIDs).count == recordIDs.count else {
            throw MirrorCheckpointError.invalidManifest
        }
    }

    private static func validateAssetContainment(
        envelopes: [ShadowMirrorRecordEnvelope],
        allowedRoots: [URL]
    ) throws {
        let roots = allowedRoots.map { $0.standardizedFileURL.path }
        for envelope in envelopes where !envelope.assets.isEmpty {
            let path = URL(fileURLWithPath: envelope.assetDirectoryPath).standardizedFileURL.path
            guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
                throw MirrorCheckpointError.invalidManifest
            }
        }
    }

    /// CKRecord.ID equivalence: recordName plus zone, deliberately ignoring recordType so two
    /// envelopes can never collide on the same CloudKit record identifier under different types.
    private static func recordIDKey(_ identity: MirrorRecordIdentity) -> String {
        "\(identity.zoneOwnerName)|\(identity.zoneName)|\(identity.recordName)"
    }

    private static func intentIdentity(_ intent: MirrorOutboxIntent) -> MirrorRecordIdentity {
        switch intent.operation {
        case .save: return intent.record!.identity
        case .delete: return intent.tombstone!
        }
    }
}

/// Fully validates a recovery-only overlay before the live store or engine state changes. The
/// nil-state caller applies the returned values synchronously, so an invalid second intent cannot
/// leave the first intent visible or enqueued.
enum MirrorRecoveryPlanOverlay {
    struct Application {
        let recordsToSave: [CKRecord]
        let recordIDsToDelete: [CKRecord.ID]
        let pendingChanges: [MirrorNormalizedPendingChange]
    }

    static func prepare(
        plan: MirrorRecoveryPlan,
        zoneID: CKRecordZone.ID
    ) throws -> Application {
        try plan.scope.validate()
        guard plan.scope.zoneOwnerName == zoneID.ownerName,
              plan.scope.zoneName == zoneID.zoneName else {
            throw MirrorCheckpointError.scopeMismatch
        }

        var recordsToSave: [CKRecord] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var expectedPending: [String: MirrorOutboxIntent.Operation] = [:]
        for intent in plan.outbox.sorted(by: { $0.sequence < $1.sequence }) {
            try intent.validate()
            let identity: MirrorRecordIdentity
            switch intent.operation {
            case .save:
                guard let envelope = intent.record else {
                    throw MirrorCheckpointError.invalidOutbox("save intent has no record")
                }
                identity = envelope.identity
                let record = try envelope.decode()
                guard MirrorRecordIdentity(record) == identity else {
                    throw MirrorCheckpointError.invalidOutbox("save envelope identity mismatch")
                }
                guard identity.zoneOwnerName == plan.scope.zoneOwnerName,
                      identity.zoneName == plan.scope.zoneName else {
                    throw MirrorCheckpointError.scopeMismatch
                }
                if intent.delivery.state != .supersededByRemoteDelete {
                    recordsToSave.append(record)
                }
            case .delete:
                guard let tombstone = intent.tombstone else {
                    throw MirrorCheckpointError.invalidOutbox("delete intent has no tombstone")
                }
                identity = tombstone
                guard identity.zoneOwnerName == plan.scope.zoneOwnerName,
                      identity.zoneName == plan.scope.zoneName else {
                    throw MirrorCheckpointError.scopeMismatch
                }
                if intent.delivery.state != .supersededByRemoteDelete {
                    recordIDsToDelete.append(CKRecord.ID(recordName: identity.recordName, zoneID: zoneID))
                }
            }

            switch intent.delivery.state {
            case .pending:
                let key = "\(identity.zoneOwnerName)|\(identity.zoneName)|\(identity.recordName)"
                guard expectedPending[key] == nil else {
                    throw MirrorCheckpointError.invalidOutbox(
                        "more than one retryable recovery intent for a record ID")
                }
                expectedPending[key] = intent.operation
            case .blockedPermanent, .supersededByRemoteDelete:
                break
            case .sent:
                throw MirrorCheckpointError.invalidOutbox(
                    "a sent row survived recovery normalization")
            }
        }

        var normalizedPending: [String: MirrorOutboxIntent.Operation] = [:]
        for change in plan.pendingChanges {
            let identity = change.identity
            guard identity.zoneOwnerName == plan.scope.zoneOwnerName,
                  identity.zoneName == plan.scope.zoneName else {
                throw MirrorCheckpointError.scopeMismatch
            }
            let key = "\(identity.zoneOwnerName)|\(identity.zoneName)|\(identity.recordName)"
            guard normalizedPending[key] == nil else {
                throw MirrorCheckpointError.invalidOutbox(
                    "duplicate normalized recovery pending change")
            }
            normalizedPending[key] = change.operation
        }
        guard normalizedPending == expectedPending else {
            throw MirrorCheckpointError.invalidOutbox(
                "normalized recovery pending changes do not match durable intents")
        }
        return Application(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete,
            pendingChanges: plan.pendingChanges)
    }
}
#endif
