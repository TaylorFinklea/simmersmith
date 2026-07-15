#if canImport(CloudKit)
import CloudKit
import Foundation

/// Builds a scope only once the signed-in CloudKit identity is known. P1 deliberately returns
/// nil for an unknown identity so shadow capture cannot delay active-engine construction or
/// risk cross-account reuse.
public enum ShadowMirrorScopeFactory {
    public static func make(
        accountRecordName: String?,
        zoneID: CKRecordZone.ID,
        householdID: String,
        role: MirrorRole
    ) -> MirrorScope? {
        guard let accountRecordName, !accountRecordName.isEmpty else { return nil }
        return MirrorScope(
            accountRecordName: accountRecordName,
            zoneOwnerName: zoneID.ownerName,
            zoneName: zoneID.zoneName,
            householdID: householdID,
            role: role,
            databaseScope: role == .owner ? .private : .shared)
    }
}

/// One immutable boundary captured under `HouseholdSyncEngine`'s mirror gate. Publication may
/// happen after that gate is released because the outbox/tombstone high-water is fixed here;
/// later WAL transitions remain above it and replay over the installed generation.
struct ShadowMirrorPublication: @unchecked Sendable {
    let records: [CKRecord]
    let engineState: MirrorEngineState
    let recoveryState: ShadowMirrorCheckpointRecoveryState
}

/// The synchronous side of P1 shadow capture. The active engine owns its store and remains the
/// source of truth; this object only serializes immutable observations into a scoped writer.
/// It never returns records to the active store.
public final class ShadowMirrorRuntime: @unchecked Sendable {
    private struct FetchSnapshot {
        let records: [CKRecord]
        let coverageRevision: UInt64
    }

    private struct StateSnapshot {
        let serialization: Data
        let coverageRevision: UInt64
        let zoneEnsured: Bool
    }

    private let writer: ShadowMirrorCheckpointWriter
    private let lock = NSLock()
    private var fetchEpochOpen = false
    private var completedFetch: FetchSnapshot?
    private var stateHistory: [StateSnapshot] = []
    private var publicationOutstanding = false
    private var fenced = false
    private var cacheReady = true

    public init(writer: ShadowMirrorCheckpointWriter) {
        self.writer = writer
    }

    public var isCacheReady: Bool {
        lock.withLock { cacheReady && !fenced }
    }

    /// A missed local mutation cannot be reconstructed from a later record snapshot alone.
    /// Persist that fact by quarantining the scope, not just by disabling this runtime in RAM.
    public func invalidate() {
        lock.withLock { quarantineLocked() }
    }

    public func beginFetchEpoch() {
        lock.lock(); defer { lock.unlock() }
        guard !fenced else { return }
        fetchEpochOpen = true
        completedFetch = nil
        // A WAL or verification failure is sticky for this writer. A later full fetch cannot
        // reconstruct an exact local outbox (especially a delete whose record is now absent).
    }

    func completeFetchEpoch(
        records: [CKRecord],
        coverageRevision: UInt64,
        zoneEnsured _: Bool
    ) throws -> ShadowMirrorPublication? {
        lock.lock(); defer { lock.unlock() }
        guard !fenced else { return nil }
        guard fetchEpochOpen else { return nil }
        fetchEpochOpen = false
        completedFetch = FetchSnapshot(
            records: records.map { $0.copy() as! CKRecord },
            coverageRevision: coverageRevision)
        return try capturePublicationIfCovered()
    }

    func observeStateUpdate(
        _ serialization: Data,
        coverageRevision: UInt64,
        zoneEnsured: Bool
    ) throws -> ShadowMirrorPublication? {
        lock.lock(); defer { lock.unlock() }
        guard !fenced else { return nil }
        stateHistory.append(StateSnapshot(
            serialization: serialization,
            coverageRevision: coverageRevision,
            zoneEnsured: zoneEnsured))
        if stateHistory.count > 256 {
            stateHistory.removeFirst(stateHistory.count - 256)
        }
        return try capturePublicationIfCovered()
    }

    /// Publish a previously captured boundary without holding the engine mirror gate. Later
    /// local mutations may append WAL frames concurrently, but the writer retains every frame
    /// above `recoveryState.lastIntentSequence` when it compacts this generation.
    func publish(_ initialPublication: ShadowMirrorPublication) async throws {
        var pending: ShadowMirrorPublication? = initialPublication
        while let publication = pending {
            guard lock.withLock({ cacheReady && !fenced }) else {
                lock.withLock { publicationOutstanding = false }
                return
            }
            do {
                try await writer.publish(
                    records: publication.records,
                    engineState: publication.engineState,
                    recoveryState: publication.recoveryState)
            } catch {
                lock.withLock {
                    cacheReady = false
                    publicationOutstanding = false
                }
                throw error
            }

            guard lock.withLock({ !fenced }) else {
                lock.withLock { publicationOutstanding = false }
                return
            }
            do {
                try await verifySameLaunchRoundTrip(publication)
            } catch {
                let shouldQuarantine = lock.withLock { () -> Bool in
                    publicationOutstanding = false
                    guard !fenced else { return false }
                    cacheReady = false
                    fenced = true
                    return true
                }
                if shouldQuarantine {
                    try? writer.fenceAndQuarantineSynchronously()
                }
                throw error
            }

            do {
                pending = try lock.withLock {
                    publicationOutstanding = false
                    return try capturePublicationIfCovered()
                }
            } catch {
                invalidate()
                throw error
            }
        }
    }

    /// WAL transitions are completed before their active-store mutation. A shadow write failure
    /// is diagnostic-only in P1: the caller keeps the unchanged full-fetch experience and this
    /// runtime permanently stops publishing checkpoints for the scope.
    @discardableResult
    public func appendSaveBeforeMutation(_ record: CKRecord, mutationGeneration: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fenced, cacheReady else { return false }
        let changedKeys = Set(record.changedKeys())
        let presentKeys = Set(record.allKeys())
        do {
            _ = try writer.appendSaveSynchronously(
                record,
                mutationGeneration: mutationGeneration,
                changedFields: Array(changedKeys.intersection(presentKeys)),
                clearedFields: Array(changedKeys.subtracting(presentKeys)))
            return true
        } catch {
            quarantineLocked()
            return false
        }
    }

    @discardableResult
    public func appendDeleteBeforeMutation(
        _ tombstone: MirrorRecordIdentity,
        mutationGeneration: UInt64
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fenced, cacheReady else { return false }
        do {
            _ = try writer.appendDeleteSynchronously(tombstone, mutationGeneration: mutationGeneration)
            return true
        } catch {
            quarantineLocked()
            return false
        }
    }

    @discardableResult
    public func markSent(recordID: CKRecord.ID, mutationGeneration: UInt64) -> Bool {
        transitionDelivery(
            recordID: recordID,
            mutationGeneration: mutationGeneration,
            requireState: .pending) { intent in
                _ = try writer.markSentSynchronously(
                    sequence: intent.sequence,
                    mutationGeneration: mutationGeneration)
            }
    }

    @discardableResult
    public func acknowledge(
        recordID: CKRecord.ID,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord? = nil
    ) -> Bool {
        transitionDelivery(
            recordID: recordID,
            mutationGeneration: mutationGeneration,
            requireState: .sent) { intent in
                _ = try writer.acknowledgeSynchronously(
                    sequence: intent.sequence,
                    mutationGeneration: mutationGeneration,
                    rebasedRecord: rebasedRecord)
            }
    }

    @discardableResult
    public func markDeliveryFailure(
        recordID: CKRecord.ID,
        mutationGeneration: UInt64,
        permanent: Bool,
        rebasedRecord: CKRecord? = nil
    ) -> Bool {
        transitionDelivery(
            recordID: recordID,
            mutationGeneration: mutationGeneration,
            requireState: .sent) { intent in
                if permanent {
                    _ = try writer.markBlockedPermanentSynchronously(
                        sequence: intent.sequence,
                        mutationGeneration: mutationGeneration)
                } else {
                    _ = try writer.markTransientFailureSynchronously(
                        sequence: intent.sequence,
                        mutationGeneration: mutationGeneration,
                        rebasedRecord: rebasedRecord)
                }
            }
    }

    public func park() {
        lock.lock(); defer { lock.unlock() }
        guard !fenced else { return }
        fenced = true
        writer.fenceSynchronously()
    }

    public func fence() {
        lock.lock(); defer { lock.unlock() }
        guard !fenced else { return }
        fenced = true
        writer.fenceSynchronously()
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        fenced = true
        try writer.fenceAndClearSynchronously()
        completedFetch = nil
        stateHistory = []
        cacheReady = false
    }

    private func capturePublicationIfCovered() throws -> ShadowMirrorPublication? {
        guard cacheReady, !publicationOutstanding, let completedFetch,
              let latestState = stateHistory.last(where: {
                  $0.coverageRevision <= completedFetch.coverageRevision
              }) else {
            return nil
        }
        let publication = ShadowMirrorPublication(
            records: completedFetch.records,
            engineState: MirrorEngineState(
                serialization: latestState.serialization,
                coverageRevision: latestState.coverageRevision,
                zoneEnsured: latestState.zoneEnsured),
            recoveryState: try writer.recoveryStateSynchronously())
        publicationOutstanding = true
        self.completedFetch = nil
        stateHistory.removeAll { $0.coverageRevision < latestState.coverageRevision }
        return publication
    }

    private func verifySameLaunchRoundTrip(_ publication: ShadowMirrorPublication) async throws {
        guard let reloaded = try await writer.loadCurrent() else {
            throw MirrorCheckpointError.invalidManifest
        }
        let isolatedStore = HouseholdLocalStore()
        for envelope in reloaded.records {
            isolatedStore.setRecord(try envelope.decode())
        }
        let isolatedRecords = isolatedStore.allRecords()
        let expectedReceipts = MirrorReceiptIndex(receipts: publication.records
            .filter { $0.recordType == "MigrationReceipt" }
            .map(MirrorRecordIdentity.init))
        let expectedDigest = try ShadowMirrorCanonicalDigest.bundle(
            records: publication.records,
            tombstones: publication.recoveryState.tombstones,
            outbox: publication.recoveryState.outbox,
            receipts: expectedReceipts)
        let isolatedDigest = try ShadowMirrorCanonicalDigest.bundle(
            records: isolatedRecords,
            tombstones: reloaded.tombstones,
            outbox: reloaded.outbox,
            receipts: reloaded.receipts)
        let expectedAssetDigests = try Self.assetDigests(publication.records)
        guard reloaded.manifest.logicalDigest == expectedDigest,
              isolatedDigest == expectedDigest,
              isolatedRecords.count == publication.records.count,
              Self.recordTypeCounts(isolatedRecords) == Self.recordTypeCounts(publication.records),
              reloaded.receipts == expectedReceipts,
              reloaded.manifest.assetDigests == expectedAssetDigests else {
            throw MirrorCheckpointError.invalidManifest
        }
    }

    private func transitionDelivery(
        recordID: CKRecord.ID,
        mutationGeneration: UInt64,
        requireState: MirrorDeliveryState.State,
        transition: (MirrorOutboxIntent) throws -> Void
    ) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !fenced, cacheReady else { return false }
        do {
            guard let intent = try writer.recoveryStateSynchronously().outbox
                .reversed()
                .first(where: {
                    $0.mutationGeneration == mutationGeneration
                        && $0.delivery.state == requireState
                        && Self.matches($0, recordID: recordID)
                }) else {
                quarantineLocked()
                return false
            }
            try transition(intent)
            return true
        } catch {
            quarantineLocked()
            return false
        }
    }

    private func quarantineLocked() {
        guard !fenced else {
            cacheReady = false
            return
        }
        cacheReady = false
        fenced = true
        try? writer.fenceAndQuarantineSynchronously()
    }

    private static func recordTypeCounts(_ records: [CKRecord]) -> [String: Int] {
        Dictionary(grouping: records, by: \.recordType).mapValues(\.count)
    }

    private static func assetDigests(_ records: [CKRecord]) throws -> [String: String] {
        var result: [String: String] = [:]
        for record in records {
            let identity = MirrorRecordIdentity(record)
            for fieldName in record.allKeys().sorted() {
                guard let asset = record[fieldName] as? CKAsset,
                      let url = asset.fileURL else { continue }
                let bytes = try Data(contentsOf: url)
                result["\(identity.sortKey)|\(fieldName)"] = ShadowMirrorDigest.sha256(bytes)
            }
        }
        return result
    }

    private static func matches(_ intent: MirrorOutboxIntent, recordID: CKRecord.ID) -> Bool {
        let identity: MirrorRecordIdentity?
        switch intent.operation {
        case .save:
            identity = intent.record?.identity
        case .delete:
            identity = intent.tombstone
        }
        return identity?.recordName == recordID.recordName
            && identity?.zoneOwnerName == recordID.zoneID.ownerName
            && identity?.zoneName == recordID.zoneID.zoneName
    }
}
#endif
