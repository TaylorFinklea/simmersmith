#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation

public struct HouseholdZoneRecoveryApplyAuthoritySnapshot: Equatable, Sendable {
    public let accountFingerprint: String
    public let sourceScope: MirrorScope
    public let targetScope: MirrorScope
    public let sessionEpoch: Int

    public init(
        accountFingerprint: String,
        sourceScope: MirrorScope,
        targetScope: MirrorScope,
        sessionEpoch: Int
    ) {
        self.accountFingerprint = accountFingerprint
        self.sourceScope = sourceScope
        self.targetScope = targetScope
        self.sessionEpoch = sessionEpoch
    }
}

/// Bridges recovery to the app's existing session authority. The immutable snapshot is evidence
/// only; `sessionAuthority` remains the single mutable source of write eligibility.
public protocol HouseholdZoneRecoveryApplySessionFence: Sendable {
    var sessionAuthority: HouseholdSessionAuthority { get }
    func currentAuthoritySnapshot() async throws -> HouseholdZoneRecoveryApplyAuthoritySnapshot
    func normalSessionIsParked() async -> Bool
}

public enum HouseholdZoneRecoveryApplyPreflightFailure: Equatable, Sendable {
    case manifest(HouseholdZoneRecoveryPlanError)
    case applyPlanMismatch
    case authorityChanged
    case notAuthoritative
    case normalSessionNotParked
    case sourceInputChanged
    case targetInputChanged
    case invalidReceipt
}

public enum HouseholdZoneRecoveryApplyStopReason: Equatable, Sendable {
    case transientTransport
    case partialFailure
    case authorityChanged
    case notAuthoritative
    case normalSessionNotParked
    case sourceChanged
    case targetChanged
    case permissionDenied
    case accountChanged
    case zoneChanged
    case schema
    case permanentTransport
    case assetCleanupFailed
}

public enum HouseholdZoneRecoveryApplyResult: Equatable, Sendable {
    case preflightRejected(HouseholdZoneRecoveryApplyPreflightFailure)
    case progress(HouseholdZoneRecoveryReceipt)
    case resumableStop(HouseholdZoneRecoveryReceipt?, HouseholdZoneRecoveryApplyStopReason)
    case conflict(HouseholdZoneRecoveryReceipt?, HouseholdZoneRecoveryIdentity?)
    case verifiedCompletion(HouseholdZoneRecoveryReceipt)
}

/// Executes deterministic Task-6 batches without exposing a delete capability. Approval-time
/// change-tag fingerprints fence the first write. From that write onward, the receipt-excluding
/// canonical digest over approved target identities is the resumable state boundary.
public struct HouseholdZoneRecoveryApplier {
    private enum AuthorityFailure {
        case changed
        case notAuthoritative
        case notParked
    }

    private enum InternalResult<Value> {
        case success(Value)
        case failure(HouseholdZoneRecoveryApplyResult)
    }

    private struct TargetSnapshot {
        let records: [CKRecord]
        let recordsByID: [CKRecord.ID: CKRecord]
    }

    private let manifest: HouseholdZoneRecoveryManifest
    private let approval: HouseholdZoneRecoveryApproval
    private let applyPlan: HouseholdZoneRecoveryApplyPlan
    private let capturedAuthority: HouseholdZoneRecoveryApplyAuthoritySnapshot
    private let sessionFence: any HouseholdZoneRecoveryApplySessionFence
    private let transport: any HouseholdZoneRecoveryApplyTransport
    private let clock: @Sendable () -> Date

    public init(
        manifest: HouseholdZoneRecoveryManifest,
        approval: HouseholdZoneRecoveryApproval,
        applyPlan: HouseholdZoneRecoveryApplyPlan,
        capturedAuthority: HouseholdZoneRecoveryApplyAuthoritySnapshot,
        sessionFence: any HouseholdZoneRecoveryApplySessionFence,
        transport: any HouseholdZoneRecoveryApplyTransport,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.manifest = manifest
        self.approval = approval
        self.applyPlan = applyPlan
        self.capturedAuthority = capturedAuthority
        self.sessionFence = sessionFence
        self.transport = transport
        self.clock = clock
    }

    public func apply(maximumBatchCount: Int = 1) async -> HouseholdZoneRecoveryApplyResult {
        do {
            try manifest.verify(approval)
        } catch let error as HouseholdZoneRecoveryPlanError {
            return .preflightRejected(.manifest(error))
        } catch {
            return .preflightRejected(.applyPlanMismatch)
        }
        guard maximumBatchCount >= 0,
              (try? manifest.digest()) == applyPlan.manifestDigest,
              applyPlan.initialTargetInputFingerprint == manifest.targetInputFingerprint,
              capturedAuthority.accountFingerprint == manifest.accountFingerprint,
              capturedAuthority.sourceScope == manifest.sourceScope,
              capturedAuthority.targetScope == manifest.targetScope else {
            return .preflightRejected(.applyPlanMismatch)
        }
        if let failure = await checkAuthorityAndParking() {
            return .preflightRejected(preflightFailure(failure))
        }

        let receiptID = CKRecord.ID(
            recordName: HouseholdZoneRecoveryReceipt.recordName(
                manifestDigest: applyPlan.manifestDigest),
            zoneID: applyPlan.targetZoneID)
        let initialTargetSnapshot: TargetSnapshot
        switch await fetchTargetSnapshot(receipt: nil) {
        case .success(let snapshot):
            initialTargetSnapshot = snapshot
        case .failure(let result):
            return result
        }
        let receiptRecord = initialTargetSnapshot.recordsByID[receiptID]

        var receipt: HouseholdZoneRecoveryReceipt
        let isFirstWrite: Bool
        if let receiptRecord {
            do {
                receipt = try HouseholdZoneRecoveryReceipt(record: receiptRecord)
            } catch {
                return .preflightRejected(.invalidReceipt)
            }
            let observed: String
            switch await observedTargetApplicationDigest(receipt: receipt) {
            case .success(let digest):
                observed = digest
            case .failure(let result):
                return result
            }
            do {
                receipt = try applyPlan.resume(
                    receipt: receipt,
                    observedTargetApplicationDigest: observed)
            } catch HouseholdZoneRecoveryApplyPlanError.targetDiverged {
                return .conflict(receipt, nil)
            } catch {
                return .preflightRejected(.invalidReceipt)
            }
            isFirstWrite = false
        } else {
            receipt = applyPlan.initialReceipt
            isFirstWrite = true
            if let rejection = await verifyApprovalFingerprints() {
                return rejection
            }
        }

        if receipt.isTerminalComplete {
            return await verifyTerminalReceipt(receipt)
        }

        if maximumBatchCount == 0 {
            return .progress(receipt)
        }

        var appliedBatchCount = 0
        var firstBatchStillNeedsInputFence = isFirstWrite
        while receipt.completedBatchDigests.count < applyPlan.batches.count,
              appliedBatchCount < maximumBatchCount {
            switch await observedTargetApplicationDigest(receipt: receipt) {
            case .success(let digest):
                guard digest == receipt.expectedTargetApplicationDigest else {
                    return conflictResult(receipt: receipt, observedRecords: nil)
                }
            case .failure(let result):
                return result
            }

            if let failure = await checkAuthorityAndParking() {
                return firstBatchStillNeedsInputFence
                    ? .preflightRejected(preflightFailure(failure))
                    : .resumableStop(receipt, stopReason(failure))
            }

            let batch = applyPlan.batches[receipt.completedBatchDigests.count]
            let nextReceipt: HouseholdZoneRecoveryReceipt
            do {
                nextReceipt = try receipt.recordingCompletedBatch(batch.digest)
            } catch {
                return .preflightRejected(.invalidReceipt)
            }
            let records: [CKRecord]
            switch await recordsForAtomicBatch(
                batch,
                currentReceipt: receipt,
                nextReceipt: nextReceipt) {
            case .success(let prepared):
                records = prepared
            case .failure(let result):
                return result
            }
            if firstBatchStillNeedsInputFence,
               let rejection = await verifyApprovalFingerprints() {
                return rejection
            }
            do {
                _ = try await transport.saveRecordsAtomically(
                    records,
                    in: applyPlan.targetZoneID)
            } catch {
                return stop(
                    for: error,
                    receipt: firstBatchStillNeedsInputFence ? nil : receipt)
            }
            receipt = nextReceipt
            appliedBatchCount += 1
            firstBatchStillNeedsInputFence = false

            if let failure = await checkAuthorityAndParking() {
                return .resumableStop(receipt, stopReason(failure))
            }
            switch await observedTargetApplicationDigest(receipt: receipt) {
            case .success(let digest):
                guard digest == batch.resultingTargetApplicationDigest,
                      digest == receipt.expectedTargetApplicationDigest else {
                    return .conflict(receipt, nil)
                }
            case .failure(let result):
                return result
            }
        }

        guard receipt.completedBatchDigests == receipt.batchDigests else {
            return .progress(receipt)
        }
        return await verifyAndComplete(
            receipt,
            needsInputFingerprintFence: firstBatchStillNeedsInputFence)
    }

    private func verifyApprovalFingerprints() async -> HouseholdZoneRecoveryApplyResult? {
        let sourceFingerprint: String
        do {
            sourceFingerprint = try await transport.inputFingerprint(
                for: zoneID(for: manifest.sourceScope))
        } catch {
            return stop(for: error, receipt: nil)
        }
        if let failure = await checkAuthorityAndParking() {
            return .preflightRejected(preflightFailure(failure))
        }
        guard sourceFingerprint == manifest.sourceInputFingerprint else {
            return .preflightRejected(.sourceInputChanged)
        }

        let targetFingerprint: String
        do {
            targetFingerprint = try await transport.inputFingerprint(
                for: zoneID(for: manifest.targetScope))
        } catch {
            return stop(for: error, receipt: nil)
        }
        if let failure = await checkAuthorityAndParking() {
            return .preflightRejected(preflightFailure(failure))
        }
        guard targetFingerprint == manifest.targetInputFingerprint else {
            return .preflightRejected(.targetInputChanged)
        }
        return nil
    }

    private func verifyTerminalReceipt(
        _ receipt: HouseholdZoneRecoveryReceipt
    ) async -> HouseholdZoneRecoveryApplyResult {
        switch await verifiedFinalTargetDigest(receipt: receipt) {
        case .success(let digest):
            guard digest == receipt.expectedTargetApplicationDigest else {
                return conflictResult(receipt: receipt, observedRecords: nil)
            }
            return cleanupAssets(after: receipt)
        case .failure(let result):
            return result
        }
    }

    private func verifyAndComplete(
        _ receipt: HouseholdZoneRecoveryReceipt,
        needsInputFingerprintFence: Bool
    ) async -> HouseholdZoneRecoveryApplyResult {
        let observedDigest: String
        switch await verifiedFinalTargetDigest(receipt: receipt) {
        case .success(let digest):
            observedDigest = digest
        case .failure(let result):
            return result
        }
        let terminalReceipt: HouseholdZoneRecoveryReceipt
        do {
            terminalReceipt = try receipt.markingTerminalComplete(
                observedTargetApplicationDigest: observedDigest,
                completedAt: clock())
        } catch {
            return conflictResult(receipt: receipt, observedRecords: nil)
        }
        let terminalRecord: CKRecord
        switch await recordForReceiptSave(terminalReceipt, currentReceipt: receipt) {
        case .success(let record):
            terminalRecord = record
        case .failure(let result):
            return result
        }
        if needsInputFingerprintFence,
           let rejection = await verifyApprovalFingerprints() {
            return rejection
        }
        if let failure = await checkAuthorityAndParking() {
            return .resumableStop(receipt, stopReason(failure))
        }
        do {
            _ = try await transport.saveRecordsAtomically(
                [terminalRecord],
                in: applyPlan.targetZoneID)
        } catch {
            return stop(for: error, receipt: receipt)
        }
        if let failure = await checkAuthorityAndParking() {
            return .resumableStop(terminalReceipt, stopReason(failure))
        }
        return cleanupAssets(after: terminalReceipt)
    }

    private func observedTargetApplicationDigest(
        receipt: HouseholdZoneRecoveryReceipt
    ) async -> InternalResult<String> {
        switch await fetchApprovedTargetRecords(receipt: receipt) {
        case .success(let records):
            do {
                let digest = try applyPlan.targetApplicationDigest(records: records)
                guard digest == receipt.expectedTargetApplicationDigest else {
                    return .failure(conflictResult(
                        receipt: receipt,
                        observedRecords: records))
                }
                return .success(digest)
            } catch {
                return .failure(conflictResult(
                    receipt: receipt,
                    observedRecords: records))
            }
        case .failure(let result):
            return .failure(result)
        }
    }

    private func verifiedFinalTargetDigest(
        receipt: HouseholdZoneRecoveryReceipt
    ) async -> InternalResult<String> {
        let records: [CKRecord]
        switch await fetchApprovedTargetRecords(receipt: receipt) {
        case .success(let fetched):
            records = fetched
        case .failure(let result):
            return .failure(result)
        }
        guard records.count == applyPlan.approvedTargetIdentities.count,
              referencesAreExactTargetZone(in: records) else {
            return .failure(conflictResult(receipt: receipt, observedRecords: records))
        }
        do {
            let digest = try applyPlan.targetApplicationDigest(records: records)
            guard digest == applyPlan.expectedFinalTargetApplicationDigest else {
                return .failure(conflictResult(receipt: receipt, observedRecords: records))
            }
            return .success(digest)
        } catch {
            return .failure(conflictResult(receipt: receipt, observedRecords: records))
        }
    }

    private func fetchApprovedTargetRecords(
        receipt: HouseholdZoneRecoveryReceipt
    ) async -> InternalResult<[CKRecord]> {
        switch await fetchTargetSnapshot(receipt: receipt) {
        case .success(let snapshot):
            let expectedIDs = Set(applyPlan.approvedTargetIdentities.map {
                CKRecord.ID(recordName: $0.recordName, zoneID: applyPlan.targetZoneID)
            })
            return .success(snapshot.records.filter { expectedIDs.contains($0.recordID) })
        case .failure(let result):
            return .failure(result)
        }
    }

    private func fetchTargetSnapshot(
        receipt: HouseholdZoneRecoveryReceipt?
    ) async -> InternalResult<TargetSnapshot> {
        var cursor: HouseholdZoneRecoveryPageCursor?
        var cursorIDs = Set<String>()
        var records: [CKRecord] = []
        var recordIDs = Set<CKRecord.ID>()
        repeat {
            let page: HouseholdZoneRecoveryRecordPage
            do {
                page = try await transport.fetchRecordPage(
                    in: applyPlan.targetZoneID,
                    after: cursor,
                    desiredKeys: nil)
            } catch {
                return .failure(stop(for: error, receipt: receipt))
            }
            if let failure = await checkAuthorityAndParking() {
                return .failure(.resumableStop(receipt, stopReason(failure)))
            }
            guard page.zoneID == applyPlan.targetZoneID,
                  page.records.allSatisfy({ $0.recordID.zoneID == applyPlan.targetZoneID }) else {
                return .failure(.resumableStop(receipt, .zoneChanged))
            }
            guard page.partialFailureCount == 0 else {
                return .failure(.resumableStop(receipt, .partialFailure))
            }
            for record in page.records {
                guard recordIDs.insert(record.recordID).inserted else {
                    return .failure(.resumableStop(receipt, .partialFailure))
                }
                records.append(record)
            }
            cursor = page.nextCursor
            if let cursor, !cursorIDs.insert(cursor.identifier).inserted {
                return .failure(.resumableStop(receipt, .partialFailure))
            }
        } while cursor != nil
        return .success(TargetSnapshot(
            records: records,
            recordsByID: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) })))
    }

    private func recordForReceiptSave(
        _ nextReceipt: HouseholdZoneRecoveryReceipt,
        currentReceipt: HouseholdZoneRecoveryReceipt
    ) async -> InternalResult<CKRecord> {
        let snapshot: TargetSnapshot
        switch await fetchTargetSnapshot(receipt: currentReceipt) {
        case .success(let value):
            snapshot = value
        case .failure(let result):
            return .failure(result)
        }
        let payload = nextReceipt.makeRecord()
        guard let current = snapshot.recordsByID[payload.recordID] else {
            return .success(payload)
        }
        guard current.recordType == payload.recordType,
              (try? HouseholdZoneRecoveryReceipt(record: current)) == currentReceipt else {
            return .failure(.preflightRejected(.invalidReceipt))
        }
        let conditional = current.copy() as! CKRecord
        for key in payload.allKeys() {
            conditional[key] = payload[key]
        }
        return .success(conditional)
    }

    private func conflictResult(
        receipt: HouseholdZoneRecoveryReceipt?,
        observedRecords: [CKRecord]?
    ) -> HouseholdZoneRecoveryApplyResult {
        guard let receipt, let observedRecords,
              let observedDigests = try? applyPlan.targetRecordApplicationDigests(
                records: observedRecords) else {
            return .conflict(receipt, nil)
        }
        let expected = receipt.expectedTargetRecordApplicationDigests
        let differingKey = Set(expected.keys)
            .union(observedDigests.keys)
            .sorted()
            .first { expected[$0] != observedDigests[$0] }
        guard let differingKey,
              let entry = manifest.approvedEntries.first(where: {
                  $0.identity.target.sortKey == differingKey
              }) else {
            return .conflict(receipt, nil)
        }
        return .conflict(receipt, entry.identity)
    }

    private func cleanupAssets(
        after receipt: HouseholdZoneRecoveryReceipt
    ) -> HouseholdZoneRecoveryApplyResult {
        guard receipt.isTerminalComplete else { return .progress(receipt) }
        do {
            if FileManager.default.fileExists(atPath: applyPlan.stagingDirectoryURL.path) {
                try FileManager.default.removeItem(at: applyPlan.stagingDirectoryURL)
            }
            return .verifiedCompletion(receipt)
        } catch {
            return .resumableStop(receipt, .assetCleanupFailed)
        }
    }
    private func recordsForAtomicBatch(
        _ batch: HouseholdZoneRecoveryApplyBatch,
        currentReceipt: HouseholdZoneRecoveryReceipt,
        nextReceipt: HouseholdZoneRecoveryReceipt
    ) async -> InternalResult<[CKRecord]> {
        let snapshot: TargetSnapshot
        switch await fetchTargetSnapshot(receipt: currentReceipt) {
        case .success(let value):
            snapshot = value
        case .failure(let result):
            return .failure(result)
        }
        let approved = snapshot.records.filter { record in
            applyPlan.approvedTargetIdentities.contains {
                $0.recordName == record.recordID.recordName
                    && $0.recordType == record.recordType
            }
        }
        guard (try? applyPlan.targetApplicationDigest(records: approved))
            == currentReceipt.expectedTargetApplicationDigest else {
            return .failure(conflictResult(
                receipt: currentReceipt,
                observedRecords: approved))
        }

        var records: [CKRecord] = batch.records.map { prepared in
            guard let current = snapshot.recordsByID[prepared.record.recordID] else {
                return prepared.record
            }
            let conditional = current.copy() as! CKRecord
            HouseholdSyncEngine.applyFields(from: prepared.record, onto: conditional)
            return conditional
        }
        let receiptPayload = nextReceipt.makeRecord()
        if let current = snapshot.recordsByID[receiptPayload.recordID] {
            guard current.recordType == receiptPayload.recordType else {
                return .failure(.preflightRejected(.invalidReceipt))
            }
            let conditional = current.copy() as! CKRecord
            for key in receiptPayload.allKeys() {
                conditional[key] = receiptPayload[key]
            }
            records.append(conditional)
        } else {
            records.append(receiptPayload)
        }
        return .success(records)
    }

    private func checkAuthorityAndParking() async -> AuthorityFailure? {
        let beforeParking: HouseholdZoneRecoveryApplyAuthoritySnapshot
        do {
            beforeParking = try await sessionFence.currentAuthoritySnapshot()
        } catch {
            return .changed
        }
        guard beforeParking == capturedAuthority else { return .changed }
        guard sessionFence.sessionAuthority.allowsAuthoritativeOperations else {
            return .notAuthoritative
        }
        guard await sessionFence.normalSessionIsParked() else { return .notParked }
        let afterParking: HouseholdZoneRecoveryApplyAuthoritySnapshot
        do {
            afterParking = try await sessionFence.currentAuthoritySnapshot()
        } catch {
            return .changed
        }
        guard afterParking == capturedAuthority else { return .changed }
        guard sessionFence.sessionAuthority.allowsAuthoritativeOperations else {
            return .notAuthoritative
        }
        return nil
    }

    private func referencesAreExactTargetZone(in records: [CKRecord]) -> Bool {
        records.allSatisfy { record in
            record.allKeys().allSatisfy { referencesAreExactTargetZone(in: record[$0]) }
        }
    }

    private func referencesAreExactTargetZone(in value: Any?) -> Bool {
        if let reference = value as? CKRecord.Reference {
            return reference.recordID.zoneID == applyPlan.targetZoneID
        }
        if let values = value as? [Any] {
            return values.allSatisfy { referencesAreExactTargetZone(in: $0) }
        }
        return true
    }

    private func stop(
        for error: Error,
        receipt: HouseholdZoneRecoveryReceipt?
    ) -> HouseholdZoneRecoveryApplyResult {
        let error = HouseholdZoneRecoveryApplyTransportError.classify(error)
        switch error {
        case .transient:
            return .resumableStop(receipt, .transientTransport)
        case .partialFailure:
            return .resumableStop(receipt, .partialFailure)
        case .conflict:
            return .conflict(receipt, nil)
        case .permissionDenied:
            return .resumableStop(receipt, .permissionDenied)
        case .accountChanged:
            return .resumableStop(receipt, .accountChanged)
        case .zoneChanged:
            return .resumableStop(receipt, .zoneChanged)
        case .schema:
            return .resumableStop(receipt, .schema)
        case .invalidResponse, .permanentFailure:
            return .resumableStop(receipt, .permanentTransport)
        }
    }

    private func preflightFailure(
        _ failure: AuthorityFailure
    ) -> HouseholdZoneRecoveryApplyPreflightFailure {
        switch failure {
        case .changed: return .authorityChanged
        case .notAuthoritative: return .notAuthoritative
        case .notParked: return .normalSessionNotParked
        }
    }

    private func stopReason(_ failure: AuthorityFailure) -> HouseholdZoneRecoveryApplyStopReason {
        switch failure {
        case .changed: return .authorityChanged
        case .notAuthoritative: return .notAuthoritative
        case .notParked: return .normalSessionNotParked
        }
    }

    private func zoneID(for scope: MirrorScope) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: scope.zoneName, ownerName: scope.zoneOwnerName)
    }
}
#endif
