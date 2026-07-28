#if canImport(CloudKit)
import CloudKit
import Foundation
import HouseholdRecords

public enum HouseholdZoneRecoveryApplyPlanError: Error, Equatable, Sendable {
    case invalidManifest(HouseholdZoneRecoveryPlanError)
    case unsupportedRecordType(String)
    case missingSourceRecord(String)
    case duplicateSourceRecord(String)
    case sourceRecordMismatch(String)
    case missingTargetRecord(String)
    case duplicateTargetRecord(String)
    case referenceOutsideSourceZone(field: String)
    case unsupportedApplicationValue(field: String)
    case missingAsset(field: String)
    case invalidAssetDigest(field: String)
    case assetStagingFailed(field: String)
    case invalidReceipt
    case unsupportedReceiptVersion
    case differentManifestDigest
    case targetDiverged
    case batchPlanDiverged
    case batchOutOfOrder
    case incompleteReceipt
    case batchCapacityUnsatisfiable
}

public enum HouseholdZoneRecoveryAssetLifetime: String, Codable, Equatable, Sendable {
    case untilCloudKitAcknowledgement = "until-cloudkit-acknowledgement"
}

public struct HouseholdZoneRecoveryStagedAsset: Equatable, Sendable {
    public let fieldName: String
    public let fileURL: URL
    public let byteCount: Int
    public let sha256: String
    public let lifetime: HouseholdZoneRecoveryAssetLifetime

    public init(
        fieldName: String,
        fileURL: URL,
        byteCount: Int,
        sha256: String,
        lifetime: HouseholdZoneRecoveryAssetLifetime = .untilCloudKitAcknowledgement
    ) {
        self.fieldName = fieldName
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sha256 = sha256
        self.lifetime = lifetime
    }
}

public struct HouseholdZoneRecoveryPreparedRecord {
    public let identity: HouseholdZoneRecoveryIdentity
    public let record: CKRecord
    public let assets: [HouseholdZoneRecoveryStagedAsset]

    public init(
        identity: HouseholdZoneRecoveryIdentity,
        record: CKRecord,
        assets: [HouseholdZoneRecoveryStagedAsset]
    ) {
        self.identity = identity
        self.record = record
        self.assets = assets
    }
}

public struct HouseholdZoneRecoveryApplyBatch {
    public let index: Int
    public let digest: String
    public let resultingTargetApplicationDigest: String
    public let records: [HouseholdZoneRecoveryPreparedRecord]

    public init(
        index: Int,
        digest: String,
        resultingTargetApplicationDigest: String,
        records: [HouseholdZoneRecoveryPreparedRecord]
    ) {
        self.index = index
        self.digest = digest
        self.resultingTargetApplicationDigest = resultingTargetApplicationDigest
        self.records = records
    }
}

/// Pure application-field reconstruction. A fresh CKRecord intentionally carries none of the
/// source record's CloudKit system metadata; only the same application keys used by the production
/// field-copy path are projected into the exact target zone.
enum HouseholdZoneRecoveryRecordReconstructor {
    static func applicationValue(
        _ value: Any,
        fieldName: String,
        sourceZoneID: CKRecordZone.ID,
        targetZoneID: CKRecordZone.ID
    ) throws -> CKRecordValue {
        if let reference = value as? CKRecord.Reference {
            return try projectedReference(
                reference,
                fieldName: fieldName,
                sourceZoneID: sourceZoneID,
                targetZoneID: targetZoneID)
        }
        if let references = value as? [CKRecord.Reference] {
            return try references.map {
                try projectedReference(
                    $0,
                    fieldName: fieldName,
                    sourceZoneID: sourceZoneID,
                    targetZoneID: targetZoneID)
            } as CKRecordValue
        }
        if let value = value as? String { return value as CKRecordValue }
        if let value = value as? Date { return value as CKRecordValue }
        if let value = value as? Data { return value as CKRecordValue }
        if let value = value as? NSNumber { return value as CKRecordValue }
        if let value = value as? CLLocation { return value as CKRecordValue }
        if let values = value as? [String] { return values as CKRecordValue }
        if let values = value as? [Date] { return values as CKRecordValue }
        if let values = value as? [Data] { return values as CKRecordValue }
        if let values = value as? [NSNumber] { return values as CKRecordValue }
        if let values = value as? [CLLocation] { return values as CKRecordValue }
        throw HouseholdZoneRecoveryApplyPlanError.unsupportedApplicationValue(field: fieldName)
    }

    private static func projectedReference(
        _ reference: CKRecord.Reference,
        fieldName: String,
        sourceZoneID: CKRecordZone.ID,
        targetZoneID: CKRecordZone.ID
    ) throws -> CKRecord.Reference {
        guard reference.recordID.zoneID == sourceZoneID else {
            throw HouseholdZoneRecoveryApplyPlanError.referenceOutsideSourceZone(field: fieldName)
        }
        return CKRecord.Reference(
            recordID: CKRecord.ID(
                recordName: reference.recordID.recordName,
                zoneID: targetZoneID),
            action: reference.action)
    }
}

public struct HouseholdZoneRecoveryReceiptIdentityAction:
    Codable, Equatable, Sendable
{
    public let identity: MirrorRecordIdentity
    public let action: HouseholdZoneRecoveryAction
    public let decision: HouseholdZoneRecoveryDecision?

    public init(
        identity: MirrorRecordIdentity,
        action: HouseholdZoneRecoveryAction,
        decision: HouseholdZoneRecoveryDecision?
    ) {
        self.identity = identity
        self.action = action
        self.decision = decision
    }
}

public struct HouseholdZoneRecoveryCompletedBatch: Codable, Equatable, Sendable {
    public let index: Int
    public let digest: String

    public init(index: Int, digest: String) {
        self.index = index
        self.digest = digest
    }
}

public enum HouseholdZoneRecoveryReceiptStatus:
    String, Codable, Equatable, Sendable
{
    case inProgress = "in-progress"
    case complete
}

public struct HouseholdZoneRecoveryReceipt: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let recordType = "HouseholdRecoveryReceipt"

    public let formatVersion: Int
    public let manifestDigest: String
    public let sourceInputFingerprint: String
    public let initialTargetInputFingerprint: String
    public let targetZoneOwnerName: String
    public let targetZoneName: String
    public let approvedIdentityActions: [HouseholdZoneRecoveryReceiptIdentityAction]
    public let batchDigests: [String]
    public let targetApplicationDigests: [String]
    public let targetRecordApplicationDigestProgress: [[String: String]]
    public let completedBatches: [HouseholdZoneRecoveryCompletedBatch]
    public let status: HouseholdZoneRecoveryReceiptStatus
    public let completedAt: Date?
    private let approvedIdentityActionsRecordData: Data
    private let batchDigestsRecordData: Data
    private let targetApplicationDigestsRecordData: Data
    private let targetRecordApplicationDigestProgressRecordData: Data
    private let completedBatchesRecordData: Data

    public var completedBatchDigests: [String] { completedBatches.map(\.digest) }
    public var isTerminalComplete: Bool { status == .complete }
    public var expectedTargetApplicationDigest: String {
        targetApplicationDigests[completedBatches.count]
    }
    public var expectedTargetRecordApplicationDigests: [String: String] {
        targetRecordApplicationDigestProgress[completedBatches.count]
    }

    public static func recordName(manifestDigest: String) -> String {
        "recovery:\(manifestDigest)"
    }

    public init(
        formatVersion: Int = HouseholdZoneRecoveryReceipt.currentFormatVersion,
        manifestDigest: String,
        sourceInputFingerprint: String,
        initialTargetInputFingerprint: String,
        targetZoneOwnerName: String,
        targetZoneName: String,
        approvedIdentityActions: [HouseholdZoneRecoveryReceiptIdentityAction],
        batchDigests: [String],
        targetApplicationDigests: [String],
        targetRecordApplicationDigestProgress: [[String: String]],
        completedBatches: [HouseholdZoneRecoveryCompletedBatch] = [],
        status: HouseholdZoneRecoveryReceiptStatus = .inProgress,
        completedAt: Date? = nil
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw HouseholdZoneRecoveryApplyPlanError.unsupportedReceiptVersion
        }
        let canonicalActions = approvedIdentityActions.sorted {
            $0.identity.sortKey < $1.identity.sortKey
        }
        let approvedKeys = approvedIdentityActions.map(\.identity.sortKey)
        let completedShapeIsValid = completedBatches.enumerated().allSatisfy {
            index, completed in
            completed.index == index
                && index < batchDigests.count
                && completed.digest == batchDigests[index]
        }
        let progressShapeIsValid = targetRecordApplicationDigestProgress.allSatisfy {
            Set($0.keys).isSubset(of: Set(approvedKeys))
                && $0.values.allSatisfy { !$0.isEmpty }
        }
        let terminalShapeIsValid: Bool
        switch status {
        case .inProgress:
            terminalShapeIsValid = completedAt == nil
        case .complete:
            terminalShapeIsValid =
                completedBatches.count == batchDigests.count && completedAt != nil
        }
        guard !manifestDigest.isEmpty,
              !sourceInputFingerprint.isEmpty,
              !initialTargetInputFingerprint.isEmpty,
              !targetZoneOwnerName.isEmpty,
              !targetZoneName.isEmpty,
              canonicalActions == approvedIdentityActions,
              Set(approvedKeys).count == approvedKeys.count,
              approvedIdentityActions.allSatisfy({
                  $0.identity.zoneOwnerName == targetZoneOwnerName
                    && $0.identity.zoneName == targetZoneName
                    && HouseholdZoneRecoveryClassifier.supportedProductionRecordTypes
                        .contains($0.identity.recordType)
                    && (($0.action == .conflict && $0.decision != nil)
                        || ($0.action != .conflict && $0.decision == nil))
              }),
              Set(batchDigests).count == batchDigests.count,
              batchDigests.allSatisfy({ !$0.isEmpty }),
              targetApplicationDigests.count == batchDigests.count + 1,
              targetApplicationDigests.allSatisfy({ !$0.isEmpty }),
              targetRecordApplicationDigestProgress.count == batchDigests.count + 1,
              progressShapeIsValid,
              Set(targetRecordApplicationDigestProgress.last.map { Array($0.keys) } ?? [])
                == Set(approvedKeys),
              completedBatches.count <= batchDigests.count,
              completedShapeIsValid,
              terminalShapeIsValid else {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
        let recordPayloads: (Data, Data, Data, Data, Data)
        do {
            recordPayloads = (
                try Self.encodeJSON(approvedIdentityActions),
                try Self.encodeJSON(batchDigests),
                try Self.encodeJSON(targetApplicationDigests),
                try Self.encodeJSON(targetRecordApplicationDigestProgress),
                try Self.encodeJSON(completedBatches))
        } catch {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
        self.formatVersion = formatVersion
        self.manifestDigest = manifestDigest
        self.sourceInputFingerprint = sourceInputFingerprint
        self.initialTargetInputFingerprint = initialTargetInputFingerprint
        self.targetZoneOwnerName = targetZoneOwnerName
        self.targetZoneName = targetZoneName
        self.approvedIdentityActions = approvedIdentityActions
        self.batchDigests = batchDigests
        self.targetApplicationDigests = targetApplicationDigests
        self.targetRecordApplicationDigestProgress =
            targetRecordApplicationDigestProgress
        self.completedBatches = completedBatches
        self.status = status
        self.completedAt = completedAt
        approvedIdentityActionsRecordData = recordPayloads.0
        batchDigestsRecordData = recordPayloads.1
        targetApplicationDigestsRecordData = recordPayloads.2
        targetRecordApplicationDigestProgressRecordData = recordPayloads.3
        completedBatchesRecordData = recordPayloads.4
    }

    public init(from decoder: Decoder) throws {
        let baseKeys: Set<String> = [
            "formatVersion",
            "manifestDigest",
            "sourceInputFingerprint",
            "initialTargetInputFingerprint",
            "targetZoneOwnerName",
            "targetZoneName",
            "approvedIdentityActions",
            "batchDigests",
            "targetApplicationDigests",
            "targetRecordApplicationDigestProgress",
            "completedBatches",
            "status",
        ]
        let container: KeyedDecodingContainer<AnyCodingKey>
        let payload: Payload
        do {
            container = try decoder.container(keyedBy: AnyCodingKey.self)
            let keys = Set(container.allKeys.map(\.stringValue))
            guard keys == baseKeys || keys == baseKeys.union(["completedAt"]) else {
                throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
            }
            payload = try Payload(from: decoder)
        } catch let error as HouseholdZoneRecoveryApplyPlanError {
            throw error
        } catch {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
        try self.init(
            formatVersion: payload.formatVersion,
            manifestDigest: payload.manifestDigest,
            sourceInputFingerprint: payload.sourceInputFingerprint,
            initialTargetInputFingerprint: payload.initialTargetInputFingerprint,
            targetZoneOwnerName: payload.targetZoneOwnerName,
            targetZoneName: payload.targetZoneName,
            approvedIdentityActions: payload.approvedIdentityActions,
            batchDigests: payload.batchDigests,
            targetApplicationDigests: payload.targetApplicationDigests,
            targetRecordApplicationDigestProgress:
                payload.targetRecordApplicationDigestProgress,
            completedBatches: payload.completedBatches,
            status: payload.status,
            completedAt: payload.completedAt)
    }

    public func encode(to encoder: Encoder) throws {
        try Payload(self).encode(to: encoder)
    }

    public init(record: CKRecord) throws {
        let baseKeys: Set<String> = [
            "formatVersion",
            "manifestDigest",
            "sourceInputFingerprint",
            "initialTargetInputFingerprint",
            "targetZoneOwnerName",
            "targetZoneName",
            "approvedIdentityActions",
            "batchDigests",
            "targetApplicationDigests",
            "targetRecordApplicationDigestProgress",
            "completedBatches",
            "status",
        ]
        let allKeys = Set(record.allKeys())
        guard record.recordType == Self.recordType,
              allKeys == baseKeys || allKeys == baseKeys.union(["completedAt"]),
              let formatNumber = record["formatVersion"] as? NSNumber,
              let manifestDigest = record["manifestDigest"] as? String,
              let sourceInputFingerprint = record["sourceInputFingerprint"] as? String,
              let initialTargetInputFingerprint =
                record["initialTargetInputFingerprint"] as? String,
              let targetZoneOwnerName = record["targetZoneOwnerName"] as? String,
              let targetZoneName = record["targetZoneName"] as? String,
              let approvedData = record["approvedIdentityActions"] as? Data,
              let batchData = record["batchDigests"] as? Data,
              let targetApplicationData = record["targetApplicationDigests"] as? Data,
              let targetRecordData =
                record["targetRecordApplicationDigestProgress"] as? Data,
              let completedData = record["completedBatches"] as? Data,
              let statusRawValue = record["status"] as? String,
              let status = HouseholdZoneRecoveryReceiptStatus(rawValue: statusRawValue),
              (status == .complete) == allKeys.contains("completedAt"),
              record.recordID.recordName == Self.recordName(manifestDigest: manifestDigest),
              record.recordID.zoneID.ownerName == targetZoneOwnerName,
              record.recordID.zoneID.zoneName == targetZoneName else {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
        do {
            try self.init(
                formatVersion: formatNumber.intValue,
                manifestDigest: manifestDigest,
                sourceInputFingerprint: sourceInputFingerprint,
                initialTargetInputFingerprint: initialTargetInputFingerprint,
                targetZoneOwnerName: targetZoneOwnerName,
                targetZoneName: targetZoneName,
                approvedIdentityActions: try Self.decodeJSON(
                    [HouseholdZoneRecoveryReceiptIdentityAction].self,
                    from: approvedData),
                batchDigests: try Self.decodeJSON([String].self, from: batchData),
                targetApplicationDigests: try Self.decodeJSON(
                    [String].self,
                    from: targetApplicationData),
                targetRecordApplicationDigestProgress: try Self.decodeJSON(
                    [[String: String]].self,
                    from: targetRecordData),
                completedBatches: try Self.decodeJSON(
                    [HouseholdZoneRecoveryCompletedBatch].self,
                    from: completedData),
                status: status,
                completedAt: record["completedAt"] as? Date)
        } catch let error as HouseholdZoneRecoveryApplyPlanError {
            throw error
        } catch {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
    }

    public func makeRecord() -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: targetZoneName, ownerName: targetZoneOwnerName)
        let record = CKRecord(
            recordType: Self.recordType,
            recordID: CKRecord.ID(
                recordName: Self.recordName(manifestDigest: manifestDigest),
                zoneID: zoneID))
        record["formatVersion"] = formatVersion as CKRecordValue
        record["manifestDigest"] = manifestDigest as CKRecordValue
        record["sourceInputFingerprint"] = sourceInputFingerprint as CKRecordValue
        record["initialTargetInputFingerprint"] =
            initialTargetInputFingerprint as CKRecordValue
        record["targetZoneOwnerName"] = targetZoneOwnerName as CKRecordValue
        record["targetZoneName"] = targetZoneName as CKRecordValue
        record["approvedIdentityActions"] =
            approvedIdentityActionsRecordData as CKRecordValue
        record["batchDigests"] = batchDigestsRecordData as CKRecordValue
        record["targetApplicationDigests"] =
            targetApplicationDigestsRecordData as CKRecordValue
        record["targetRecordApplicationDigestProgress"] =
            targetRecordApplicationDigestProgressRecordData as CKRecordValue
        record["completedBatches"] =
            completedBatchesRecordData as CKRecordValue
        record["status"] = status.rawValue as CKRecordValue
        record["completedAt"] = completedAt as CKRecordValue?
        return record
    }

    public func recordingCompletedBatch(_ digest: String) throws -> Self {
        let index = completedBatches.count
        guard status == .inProgress,
              index < batchDigests.count,
              batchDigests[index] == digest else {
            throw HouseholdZoneRecoveryApplyPlanError.batchOutOfOrder
        }
        return try Self(
            manifestDigest: manifestDigest,
            sourceInputFingerprint: sourceInputFingerprint,
            initialTargetInputFingerprint: initialTargetInputFingerprint,
            targetZoneOwnerName: targetZoneOwnerName,
            targetZoneName: targetZoneName,
            approvedIdentityActions: approvedIdentityActions,
            batchDigests: batchDigests,
            targetApplicationDigests: targetApplicationDigests,
            targetRecordApplicationDigestProgress:
                targetRecordApplicationDigestProgress,
            completedBatches: completedBatches + [
                HouseholdZoneRecoveryCompletedBatch(index: index, digest: digest),
            ])
    }

    public func markingTerminalComplete(
        observedTargetApplicationDigest: String,
        completedAt: Date
    ) throws -> Self {
        guard completedBatches.count == batchDigests.count else {
            throw HouseholdZoneRecoveryApplyPlanError.incompleteReceipt
        }
        guard observedTargetApplicationDigest == expectedTargetApplicationDigest else {
            throw HouseholdZoneRecoveryApplyPlanError.targetDiverged
        }
        if status == .complete {
            guard self.completedAt == completedAt else {
                throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
            }
            return self
        }
        return try Self(
            manifestDigest: manifestDigest,
            sourceInputFingerprint: sourceInputFingerprint,
            initialTargetInputFingerprint: initialTargetInputFingerprint,
            targetZoneOwnerName: targetZoneOwnerName,
            targetZoneName: targetZoneName,
            approvedIdentityActions: approvedIdentityActions,
            batchDigests: batchDigests,
            targetApplicationDigests: targetApplicationDigests,
            targetRecordApplicationDigestProgress:
                targetRecordApplicationDigestProgress,
            completedBatches: completedBatches,
            status: .complete,
            completedAt: completedAt)
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private struct Payload: Codable {
        let formatVersion: Int
        let manifestDigest: String
        let sourceInputFingerprint: String
        let initialTargetInputFingerprint: String
        let targetZoneOwnerName: String
        let targetZoneName: String
        let approvedIdentityActions: [HouseholdZoneRecoveryReceiptIdentityAction]
        let batchDigests: [String]
        let targetApplicationDigests: [String]
        let targetRecordApplicationDigestProgress: [[String: String]]
        let completedBatches: [HouseholdZoneRecoveryCompletedBatch]
        let status: HouseholdZoneRecoveryReceiptStatus
        let completedAt: Date?

        init(_ receipt: HouseholdZoneRecoveryReceipt) {
            formatVersion = receipt.formatVersion
            manifestDigest = receipt.manifestDigest
            sourceInputFingerprint = receipt.sourceInputFingerprint
            initialTargetInputFingerprint = receipt.initialTargetInputFingerprint
            targetZoneOwnerName = receipt.targetZoneOwnerName
            targetZoneName = receipt.targetZoneName
            approvedIdentityActions = receipt.approvedIdentityActions
            batchDigests = receipt.batchDigests
            targetApplicationDigests = receipt.targetApplicationDigests
            targetRecordApplicationDigestProgress =
                receipt.targetRecordApplicationDigestProgress
            completedBatches = receipt.completedBatches
            status = receipt.status
            completedAt = receipt.completedAt
        }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public struct HouseholdZoneRecoveryApplyPlan {
    public let manifestDigest: String
    public let targetZoneID: CKRecordZone.ID
    public let sourceInputFingerprint: String
    public let initialTargetInputFingerprint: String
    public let approvedTargetIdentities: [MirrorRecordIdentity]
    public let approvedIdentityActions: [HouseholdZoneRecoveryReceiptIdentityAction]
    public let targetRecordApplicationDigestProgress: [[String: String]]
    public let expectedFinalTargetApplicationDigest: String
    public let expectedFinalRecordApplicationDigests: [String: String]
    public let stagingDirectoryURL: URL
    public let batches: [HouseholdZoneRecoveryApplyBatch]
    public let initialReceipt: HouseholdZoneRecoveryReceipt

    /// CloudKit's hard per-request ceiling on the number of items (records) a single operation
    /// may carry.
    public static let maximumBatchItemCount = 400
    /// CloudKit's hard per-request ceiling on total encoded request bytes.
    public static let maximumBatchRequestBytes = 2_000_000
    /// CloudKit's hard per-record ceiling on a single record's encoded field bytes, excluding
    /// CKAsset payloads (which upload out of band). Distinct from `maximumBatchRequestBytes`:
    /// a request can stay under the request-wide cap while still carrying one record CloudKit
    /// will reject outright for exceeding this per-record cap.
    public static let maximumRecordBytes = 1_000_000
    /// Every atomic write also carries the resumable receipt record in the same CloudKit request
    /// (`HouseholdZoneRecoveryApplier.recordsForAtomicBatch`), so a batch's own record count must
    /// leave room for it under `maximumBatchItemCount`.
    public static let maximumBatchRecordCount = maximumBatchItemCount - 1
    /// Fixed allowance per request item (a prepared record or the receipt) covering CKRecord
    /// envelope bytes the field-level estimator doesn't itself measure: recordName, recordType,
    /// zoneID owner/zone names, and CloudKit protocol/JSON structural overhead.
    static let perItemFramingAllowanceBytes = 512
    /// Bound on the receipt-size/record-budget fixpoint below: enough rounds for the two-way
    /// feedback (fewer batches -> smaller receipt -> more room for records -> fewer batches) to
    /// settle for any real manifest shape, without looping unboundedly on a shape that never will.
    /// Internal rather than private so tests can override it directly through
    /// `planChunkedBatches(maximumIterations:)` to drive non-convergence deterministically.
    static let maximumBatchCapacityFixpointIterations = 8

    public var records: [HouseholdZoneRecoveryPreparedRecord] {
        batches.flatMap(\.records)
    }

    public init(
        manifest: HouseholdZoneRecoveryManifest,
        approval: HouseholdZoneRecoveryApproval,
        sourceRecords: [CKRecord],
        targetRecords: [CKRecord] = [],
        stagingRootURL: URL? = nil
    ) throws {
        do {
            try manifest.verify(approval)
        } catch let error as HouseholdZoneRecoveryPlanError {
            throw HouseholdZoneRecoveryApplyPlanError.invalidManifest(error)
        }
        let manifestDigest = try manifest.digest()
        let sourceZoneID = CKRecordZone.ID(
            zoneName: manifest.sourceScope.zoneName,
            ownerName: manifest.sourceScope.zoneOwnerName)
        let targetZoneID = CKRecordZone.ID(
            zoneName: manifest.targetScope.zoneName,
            ownerName: manifest.targetScope.zoneOwnerName)
        let root = try Self.stagingRoot(override: stagingRootURL)
        let stagingDirectoryURL = root.appendingPathComponent(manifestDigest, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: true)
        } catch {
            throw HouseholdZoneRecoveryApplyPlanError.assetStagingFailed(field: "")
        }

        let approvedEntries = manifest.approvedEntries
        let writableEntries = approvedEntries.filter(Self.requiresSourceWrite)
        let sources = try Self.indexSourceRecords(sourceRecords, sourceZoneID: sourceZoneID)
        let targets = try Self.indexTargetRecords(targetRecords, targetZoneID: targetZoneID)
        var preparedByKey: [String: HouseholdZoneRecoveryPreparedRecord] = [:]
        for entry in approvedEntries
        where entry.action != .conflict || entry.decision == .source
        {
            let key = entry.identity.source.sortKey
            guard let source = sources[key] else {
                throw HouseholdZoneRecoveryApplyPlanError.missingSourceRecord(key)
            }
            preparedByKey[key] = try Self.reconstruct(
                entry: entry,
                source: source,
                sourceZoneID: sourceZoneID,
                targetZoneID: targetZoneID,
                stagingDirectoryURL: stagingDirectoryURL)
        }

        var targetState: [String: CKRecord] = [:]
        for entry in approvedEntries {
            let targetKey = entry.identity.target.sortKey
            switch entry.action {
            case .copy:
                break
            case .skipIdentical:
                guard let prepared = preparedByKey[entry.identity.source.sortKey] else {
                    throw HouseholdZoneRecoveryApplyPlanError.missingSourceRecord(
                        entry.identity.source.sortKey)
                }
                targetState[targetKey] = prepared.record
            case .conflict:
                guard let target = targets[targetKey] else {
                    throw HouseholdZoneRecoveryApplyPlanError.missingTargetRecord(targetKey)
                }
                targetState[targetKey] = target
            }
        }

        let approvedTargetIdentities = approvedEntries
            .map(\.identity.target)
            .sorted { $0.sortKey < $1.sortKey }
        let approvedIdentityActions = approvedEntries.map {
            HouseholdZoneRecoveryReceiptIdentityAction(
                identity: $0.identity.target,
                action: $0.action,
                decision: $0.decision)
        }.sorted { $0.identity.sortKey < $1.identity.sortKey }
        var targetApplicationDigests = [
            try Self.targetApplicationDigest(
                manifestDigest: manifestDigest,
                approvedTargetIdentities: approvedTargetIdentities,
                recordsByKey: targetState)
        ]
        var targetRecordApplicationDigestProgress = [
            try Self.targetRecordApplicationDigests(
                approvedTargetIdentities: approvedTargetIdentities,
                recordsByKey: targetState)
        ]
        let layers = try Self.dependencyLayers(entries: writableEntries)
        let layerRecords = try layers.map { layer in
            try layer.map { entry -> HouseholdZoneRecoveryPreparedRecord in
                guard let prepared = preparedByKey[entry.identity.source.sortKey] else {
                    throw HouseholdZoneRecoveryApplyPlanError.missingSourceRecord(
                        entry.identity.source.sortKey)
                }
                return prepared
            }
        }
        let chunkedBatches = try Self.planChunkedBatches(
            layers: layers,
            layerRecords: layerRecords,
            manifestDigest: manifestDigest,
            sourceInputFingerprint: manifest.sourceInputFingerprint,
            initialTargetInputFingerprint: manifest.targetInputFingerprint,
            targetZoneID: targetZoneID,
            approvedIdentityActions: approvedIdentityActions)
        var batches: [HouseholdZoneRecoveryApplyBatch] = []
        for (index, records) in chunkedBatches.enumerated() {
            let digest = try Self.batchDigest(
                manifestDigest: manifestDigest,
                index: index,
                records: records)
            for prepared in records {
                targetState[prepared.identity.target.sortKey] = prepared.record
            }
            let resultingTargetApplicationDigest = try Self.targetApplicationDigest(
                manifestDigest: manifestDigest,
                approvedTargetIdentities: approvedTargetIdentities,
                recordsByKey: targetState)
            targetApplicationDigests.append(resultingTargetApplicationDigest)
            targetRecordApplicationDigestProgress.append(
                try Self.targetRecordApplicationDigests(
                    approvedTargetIdentities: approvedTargetIdentities,
                    recordsByKey: targetState))
            batches.append(HouseholdZoneRecoveryApplyBatch(
                index: index,
                digest: digest,
                resultingTargetApplicationDigest: resultingTargetApplicationDigest,
                records: records))
        }

        guard let finalRecordDigests =
            targetRecordApplicationDigestProgress.last else {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }

        self.manifestDigest = manifestDigest
        self.targetZoneID = targetZoneID
        self.sourceInputFingerprint = manifest.sourceInputFingerprint
        self.initialTargetInputFingerprint = manifest.targetInputFingerprint
        self.approvedTargetIdentities = approvedTargetIdentities
        self.approvedIdentityActions = approvedIdentityActions
        self.targetRecordApplicationDigestProgress =
            targetRecordApplicationDigestProgress
        self.expectedFinalTargetApplicationDigest =
            targetApplicationDigests[targetApplicationDigests.count - 1]
        self.expectedFinalRecordApplicationDigests = finalRecordDigests
        self.stagingDirectoryURL = stagingDirectoryURL
        self.batches = batches
        self.initialReceipt = try HouseholdZoneRecoveryReceipt(
            manifestDigest: manifestDigest,
            sourceInputFingerprint: manifest.sourceInputFingerprint,
            initialTargetInputFingerprint: manifest.targetInputFingerprint,
            targetZoneOwnerName: targetZoneID.ownerName,
            targetZoneName: targetZoneID.zoneName,
            approvedIdentityActions: approvedIdentityActions,
            batchDigests: batches.map(\.digest),
            targetApplicationDigests: targetApplicationDigests,
            targetRecordApplicationDigestProgress:
                targetRecordApplicationDigestProgress)
    }

    public func resume(
        receipt: HouseholdZoneRecoveryReceipt,
        observedTargetApplicationDigest: String
    ) throws -> HouseholdZoneRecoveryReceipt {
        guard receipt.manifestDigest == manifestDigest else {
            throw HouseholdZoneRecoveryApplyPlanError.differentManifestDigest
        }
        guard receipt.targetZoneOwnerName == targetZoneID.ownerName,
              receipt.targetZoneName == targetZoneID.zoneName,
              receipt.expectedTargetApplicationDigest == observedTargetApplicationDigest else {
            throw HouseholdZoneRecoveryApplyPlanError.targetDiverged
        }
        guard receipt.sourceInputFingerprint == sourceInputFingerprint,
              receipt.initialTargetInputFingerprint == initialTargetInputFingerprint,
              receipt.approvedIdentityActions == approvedIdentityActions,
              receipt.batchDigests == batches.map(\.digest),
              receipt.targetApplicationDigests
                == initialReceipt.targetApplicationDigests,
              receipt.targetRecordApplicationDigestProgress
                == targetRecordApplicationDigestProgress else {
            throw HouseholdZoneRecoveryApplyPlanError.batchPlanDiverged
        }
        return receipt
    }

    /// Canonicalizes only approved target identities and their application fields. Recovery
    /// receipts, unrelated records, change tags, parent/share metadata, and all other CloudKit
    /// system metadata are excluded by construction.
    public func targetApplicationDigest(records: [CKRecord]) throws -> String {
        let recordsByKey = try indexedApprovedTargetRecords(records)
        return try Self.targetApplicationDigest(
            manifestDigest: manifestDigest,
            approvedTargetIdentities: approvedTargetIdentities,
            recordsByKey: recordsByKey)
    }

    public func targetRecordApplicationDigests(
        records: [CKRecord]
    ) throws -> [String: String] {
        let recordsByKey = try indexedApprovedTargetRecords(records)
        return try Self.targetRecordApplicationDigests(
            approvedTargetIdentities: approvedTargetIdentities,
            recordsByKey: recordsByKey)
    }

    public func expectedFinalRecordApplicationDigest(
        for identity: MirrorRecordIdentity
    ) -> String? {
        expectedFinalRecordApplicationDigests[identity.sortKey]
    }

    private func indexedApprovedTargetRecords(
        _ records: [CKRecord]
    ) throws -> [String: CKRecord] {
        let expectedKeys = Set(approvedTargetIdentities.map(\.sortKey))
        var recordsByKey: [String: CKRecord] = [:]
        for record in records {
            let identity = MirrorRecordIdentity(record)
            guard expectedKeys.contains(identity.sortKey) else { continue }
            guard record.recordID.zoneID == targetZoneID else { continue }
            guard recordsByKey.updateValue(record, forKey: identity.sortKey) == nil else {
                throw HouseholdZoneRecoveryApplyPlanError.duplicateTargetRecord(
                    identity.sortKey)
            }
        }
        return recordsByKey
    }

    private static func requiresSourceWrite(_ entry: HouseholdZoneRecoveryEntry) -> Bool {
        entry.action == .copy || (entry.action == .conflict && entry.decision == .source)
    }

    private static func stagingRoot(override: URL?) throws -> URL {
        let root: URL
        if let override {
            root = override
        } else {
            let applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            root = applicationSupport.appendingPathComponent(
                "HouseholdZoneRecoveryAssets",
                isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private static func indexSourceRecords(
        _ records: [CKRecord],
        sourceZoneID: CKRecordZone.ID
    ) throws -> [String: CKRecord] {
        var result: [String: CKRecord] = [:]
        for record in records {
            guard record.recordID.zoneID == sourceZoneID else {
                throw HouseholdZoneRecoveryApplyPlanError.sourceRecordMismatch(
                    MirrorRecordIdentity(record).sortKey)
            }
            guard HouseholdZoneRecoveryClassifier.supportedProductionRecordTypes.contains(record.recordType) else {
                throw HouseholdZoneRecoveryApplyPlanError.unsupportedRecordType(record.recordType)
            }
            let key = MirrorRecordIdentity(record).sortKey
            guard result.updateValue(record, forKey: key) == nil else {
                throw HouseholdZoneRecoveryApplyPlanError.duplicateSourceRecord(key)
            }
        }
        return result
    }

    private static func indexTargetRecords(
        _ records: [CKRecord],
        targetZoneID: CKRecordZone.ID
    ) throws -> [String: CKRecord] {
        var result: [String: CKRecord] = [:]
        for record in records {
            guard record.recordID.zoneID == targetZoneID else {
                throw HouseholdZoneRecoveryApplyPlanError.sourceRecordMismatch(
                    MirrorRecordIdentity(record).sortKey)
            }
            guard HouseholdZoneRecoveryClassifier.supportedProductionRecordTypes
                .contains(record.recordType) else {
                continue
            }
            let key = MirrorRecordIdentity(record).sortKey
            guard result.updateValue(record, forKey: key) == nil else {
                throw HouseholdZoneRecoveryApplyPlanError.duplicateTargetRecord(key)
            }
        }
        return result
    }


    private static func reconstruct(
        entry: HouseholdZoneRecoveryEntry,
        source: CKRecord,
        sourceZoneID: CKRecordZone.ID,
        targetZoneID: CKRecordZone.ID,
        stagingDirectoryURL: URL
    ) throws -> HouseholdZoneRecoveryPreparedRecord {
        guard MirrorRecordIdentity(source) == entry.identity.source,
              entry.identity.target.recordType == source.recordType,
              entry.identity.target.recordName == source.recordID.recordName,
              entry.identity.target.zoneOwnerName == targetZoneID.ownerName,
              entry.identity.target.zoneName == targetZoneID.zoneName else {
            throw HouseholdZoneRecoveryApplyPlanError.sourceRecordMismatch(
                entry.identity.source.sortKey)
        }
        let target = CKRecord(
            recordType: source.recordType,
            recordID: CKRecord.ID(
                recordName: source.recordID.recordName,
                zoneID: targetZoneID))
        let fieldNames = try applicationFieldNames(for: source.recordType)
        var stagedAssets: [HouseholdZoneRecoveryStagedAsset] = []
        var observedAssetDigests: [String: String] = [:]
        for fieldName in fieldNames {
            guard let value = source[fieldName] else { continue }
            if let asset = value as? CKAsset {
                let staged = try stageAsset(
                    asset,
                    fieldName: fieldName,
                    identity: entry.identity,
                    expectedDigest: entry.assetDigests[fieldName],
                    stagingDirectoryURL: stagingDirectoryURL)
                target[fieldName] = CKAsset(fileURL: staged.fileURL)
                stagedAssets.append(staged)
                observedAssetDigests[fieldName] = staged.sha256
            } else {
                target[fieldName] = try HouseholdZoneRecoveryRecordReconstructor.applicationValue(
                    value,
                    fieldName: fieldName,
                    sourceZoneID: sourceZoneID,
                    targetZoneID: targetZoneID)
            }
        }
        guard observedAssetDigests == entry.assetDigests else {
            let field = Set(observedAssetDigests.keys)
                .symmetricDifference(entry.assetDigests.keys)
                .sorted().first ?? entry.assetDigests.keys.sorted().first ?? ""
            throw HouseholdZoneRecoveryApplyPlanError.invalidAssetDigest(field: field)
        }
        return HouseholdZoneRecoveryPreparedRecord(
            identity: entry.identity,
            record: target,
            assets: stagedAssets.sorted { $0.fieldName < $1.fieldName })
    }

    /// Mirrors the shipped codec/schema field sets. Recovery deliberately has no `allKeys`
    /// fallback: an approved record can still contain a historical or contaminated application
    /// key, and reconstructing that key would manufacture a field outside the production schema.
    private static func applicationFieldNames(for recordType: String) throws -> [String] {
        if let manifestType = HouseholdRecordType(recordTypeName: recordType) {
            return (manifestType.fields.map(\.name) + manifestType.refs.map(\.name)).sorted()
        }
        switch recordType {
        case "HouseholdProfile":
            return ["createdAt", "name"]
        case GroceryCodec.recordType:
            return [
                "baseIngredientID",
                "category",
                "checkedAtClock",
                "checkedBy",
                "createdAtClock",
                "eventQuantity",
                "ingredientName",
                "ingredientVariationID",
                "isChecked",
                "isUserAdded",
                "isUserRemoved",
                "modifiedAtClock",
                "normalizedName",
                "notes",
                "notesOverride",
                "quantityOverride",
                "quantityText",
                "resolutionStatus",
                "reviewFlag",
                "sourceMeals",
                "storeLabel",
                "totalQuantity",
                "unit",
                "unitOverride",
                "weekID",
            ]
        case EventGroceryCodec.recordType:
            return [
                "baseIngredientID",
                "category",
                "eventQuantity",
                "ingredientName",
                "ingredientVariationID",
                "mergedIntoGroceryItemID",
                "mergedIntoWeekID",
                "modifiedAtClock",
                "normalizedName",
                "notes",
                "quantityText",
                "resolutionStatus",
                "reviewFlag",
                "sourceMeals",
                "unit",
            ]
        case RecipeImageCodec.recordType:
            return ["generatedAt", "imageAsset", "mimeType", "prompt", "recipe"]
        case RecipeMemoryImageCodec.recordType:
            return ["createdAt", "imageAsset", "mimeType", "recipeMemory"]
        default:
            throw HouseholdZoneRecoveryApplyPlanError.unsupportedRecordType(recordType)
        }
    }

    private static func stageAsset(
        _ asset: CKAsset,
        fieldName: String,
        identity: HouseholdZoneRecoveryIdentity,
        expectedDigest: String?,
        stagingDirectoryURL: URL
    ) throws -> HouseholdZoneRecoveryStagedAsset {
        guard let sourceURL = asset.fileURL,
              let bytes = try? Data(contentsOf: sourceURL),
              !bytes.isEmpty else {
            throw HouseholdZoneRecoveryApplyPlanError.missingAsset(field: fieldName)
        }
        let digest = ShadowMirrorDigest.sha256(bytes)
        guard digest == expectedDigest else {
            throw HouseholdZoneRecoveryApplyPlanError.invalidAssetDigest(field: fieldName)
        }
        let filenameSeed = "\(identity.target.sortKey)|\(fieldName)"
        let filename = "asset-\(ShadowMirrorDigest.sha256(Data(filenameSeed.utf8))).bin"
        let destinationURL = stagingDirectoryURL.appendingPathComponent(filename)
        do {
            try bytes.write(to: destinationURL, options: .atomic)
            let stagedBytes = try Data(contentsOf: destinationURL)
            guard stagedBytes.count == bytes.count,
                  ShadowMirrorDigest.sha256(stagedBytes) == digest else {
                throw HouseholdZoneRecoveryApplyPlanError.invalidAssetDigest(field: fieldName)
            }
        } catch let error as HouseholdZoneRecoveryApplyPlanError {
            throw error
        } catch {
            throw HouseholdZoneRecoveryApplyPlanError.assetStagingFailed(field: fieldName)
        }
        return HouseholdZoneRecoveryStagedAsset(
            fieldName: fieldName,
            fileURL: destinationURL,
            byteCount: bytes.count,
            sha256: digest)
    }

    private static func targetRecordApplicationDigests(
        approvedTargetIdentities: [MirrorRecordIdentity],
        recordsByKey: [String: CKRecord]
    ) throws -> [String: String] {
        var digests: [String: String] = [:]
        for identity in approvedTargetIdentities {
            guard let record = recordsByKey[identity.sortKey] else { continue }
            digests[identity.sortKey] = try recordApplicationDigest(
                identity: identity,
                record: record)
        }
        return digests
    }

    private static func targetApplicationDigest(
        manifestDigest: String,
        approvedTargetIdentities: [MirrorRecordIdentity],
        recordsByKey: [String: CKRecord]
    ) throws -> String {
        var writer = CanonicalWriter()
        writer.append("household-zone-recovery-target-application-v1")
        writer.append(manifestDigest)
        writer.append(approvedTargetIdentities.count)
        for identity in approvedTargetIdentities {
            writer.append(identity)
            guard let record = recordsByKey[identity.sortKey] else {
                writer.append("missing")
                continue
            }
            writer.append("present")
            writer.append(try recordApplicationDigest(identity: identity, record: record))
        }
        return ShadowMirrorDigest.sha256(writer.data)
    }

    private static func recordApplicationDigest(
        identity: MirrorRecordIdentity,
        record: CKRecord
    ) throws -> String {
        guard MirrorRecordIdentity(record) == identity else {
            throw HouseholdZoneRecoveryApplyPlanError.sourceRecordMismatch(
                MirrorRecordIdentity(record).sortKey)
        }
        var writer = CanonicalWriter()
        writer.append("household-zone-recovery-target-record-application-v1")
        writer.append(identity)
        let fieldNames = try applicationFieldNames(for: record.recordType)
        writer.append(fieldNames.count)
        for fieldName in fieldNames {
            writer.append(fieldName)
            do {
                try writer.append(record[fieldName] as Any?)
            } catch {
                if record[fieldName] is CKAsset {
                    throw HouseholdZoneRecoveryApplyPlanError.invalidAssetDigest(
                        field: fieldName)
                }
                throw HouseholdZoneRecoveryApplyPlanError.unsupportedApplicationValue(
                    field: fieldName)
            }
        }
        return ShadowMirrorDigest.sha256(writer.data)
    }

    private static func batchDigest(
        manifestDigest: String,
        index: Int,
        records: [HouseholdZoneRecoveryPreparedRecord]
    ) throws -> String {
        var writer = CanonicalWriter()
        writer.append("household-zone-recovery-batch-v1")
        writer.append(manifestDigest)
        writer.append(index)
        writer.append(records.count)
        for prepared in records {
            writer.append(prepared.identity.target)
            let keys = prepared.record.allKeys().sorted()
            writer.append(keys.count)
            for key in keys {
                writer.append(key)
                do {
                    try writer.append(prepared.record[key] as Any?)
                } catch {
                    throw HouseholdZoneRecoveryApplyPlanError.unsupportedApplicationValue(field: key)
                }
            }
        }
        return ShadowMirrorDigest.sha256(writer.data)
    }

    /// Resolves the two-way feedback between batch count and receipt size: the receipt CloudKit
    /// co-writes with every batch (`HouseholdZoneRecoveryApplier.recordsForAtomicBatch`) carries
    /// the full per-batch digest history, so its size grows with the very batch count a smaller
    /// record budget produces. Starting from an optimistic single-batch guess, each round measures
    /// the receipt for the resulting batch count, shrinks the record budget by that amount, and
    /// re-chunks every layer; the loop returns as soon as the batch count stops changing. A
    /// shape that never settles, whose record budget goes non-positive, or whose receipt alone
    /// (plus its own framing) would break the per-record byte ceiling is rejected rather than
    /// emitting a batch CloudKit is guaranteed to reject. `maximumIterations` defaults to
    /// `maximumBatchCapacityFixpointIterations`; tests may pass a smaller bound to drive
    /// non-convergence deterministically.
    static func planChunkedBatches(
        layers: [[HouseholdZoneRecoveryEntry]],
        layerRecords: [[HouseholdZoneRecoveryPreparedRecord]],
        manifestDigest: String,
        sourceInputFingerprint: String,
        initialTargetInputFingerprint: String,
        targetZoneID: CKRecordZone.ID,
        approvedIdentityActions: [HouseholdZoneRecoveryReceiptIdentityAction],
        maximumIterations: Int = maximumBatchCapacityFixpointIterations
    ) throws -> [[HouseholdZoneRecoveryPreparedRecord]] {
        var assumedBatchCount = 1
        for _ in 0..<maximumIterations {
            let receiptBytes = try estimatedReceiptBytes(
                manifestDigest: manifestDigest,
                sourceInputFingerprint: sourceInputFingerprint,
                initialTargetInputFingerprint: initialTargetInputFingerprint,
                targetZoneID: targetZoneID,
                approvedIdentityActions: approvedIdentityActions,
                batchCount: assumedBatchCount)
            let recordByteBudget =
                maximumBatchRequestBytes - receiptBytes - perItemFramingAllowanceBytes
            guard recordByteBudget > 0,
                  receiptBytes + perItemFramingAllowanceBytes <= maximumRecordBytes else {
                throw HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable
            }
            var chunks: [[HouseholdZoneRecoveryPreparedRecord]] = []
            for (layer, records) in zip(layers, layerRecords) {
                chunks.append(contentsOf: try chunkedBatchRecords(
                    entries: layer,
                    records: records,
                    recordByteBudget: recordByteBudget))
            }
            guard !chunks.isEmpty else { return chunks }
            if chunks.count == assumedBatchCount { return chunks }
            assumedBatchCount = chunks.count
        }
        throw HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable
    }

    /// Measures the exact byte cost of the receipt shape the Applier co-writes for a plan with
    /// `batchCount` batches, by constructing a real `HouseholdZoneRecoveryReceipt` with the plan's
    /// actual approved-identity actions (the only receipt content already fixed before chunking)
    /// and placeholder — but real-length, real-hashed — digests standing in for the ones that
    /// don't exist until chunking completes. `completedBatches` is filled to its maximum size
    /// (every batch complete) because that is the actual largest receipt this plan ever writes:
    /// the co-written receipt after the final batch, just before terminal verification. Feeding
    /// the resulting record through `estimatedRecordBytes` reuses the identical per-field
    /// estimator applied to ordinary prepared records, so the two estimates stay consistent.
    static func estimatedReceiptBytes(
        manifestDigest: String,
        sourceInputFingerprint: String,
        initialTargetInputFingerprint: String,
        targetZoneID: CKRecordZone.ID,
        approvedIdentityActions: [HouseholdZoneRecoveryReceiptIdentityAction],
        batchCount: Int
    ) throws -> Int {
        let approvedKeys = approvedIdentityActions.map(\.identity.sortKey)
        let batchDigests = (0..<batchCount).map {
            ShadowMirrorDigest.sha256(Data("household-zone-recovery-capacity-batch-\($0)".utf8))
        }
        let targetApplicationDigests = (0...batchCount).map {
            ShadowMirrorDigest.sha256(Data("household-zone-recovery-capacity-target-\($0)".utf8))
        }
        let fullRecordDigestMap = Dictionary(uniqueKeysWithValues: approvedKeys.map {
            ($0, ShadowMirrorDigest.sha256(Data("household-zone-recovery-capacity-record-\($0)".utf8)))
        })
        let targetRecordApplicationDigestProgress = Array(
            repeating: fullRecordDigestMap,
            count: batchCount + 1)
        let completedBatches = batchDigests.enumerated().map {
            HouseholdZoneRecoveryCompletedBatch(index: $0.offset, digest: $0.element)
        }
        let syntheticReceipt = try HouseholdZoneRecoveryReceipt(
            manifestDigest: manifestDigest,
            sourceInputFingerprint: sourceInputFingerprint,
            initialTargetInputFingerprint: initialTargetInputFingerprint,
            targetZoneOwnerName: targetZoneID.ownerName,
            targetZoneName: targetZoneID.zoneName,
            approvedIdentityActions: approvedIdentityActions,
            batchDigests: batchDigests,
            targetApplicationDigests: targetApplicationDigests,
            targetRecordApplicationDigestProgress: targetRecordApplicationDigestProgress,
            completedBatches: completedBatches)
        return estimatedRecordBytes(for: syntheticReceipt.makeRecord())
    }

    /// Per-request framing allowance for `recordCount` prepared records plus the one receipt
    /// record every atomic write co-writes alongside them.
    static func framingAllowanceBytes(recordCount: Int) -> Int {
        (recordCount + 1) * perItemFramingAllowanceBytes
    }

    /// Splits one dependency layer's prepared records into ordered, capacity-bound batches.
    /// A required-dependency edge between two entries can only exist within the same layer when
    /// they belong to the same strongly-connected component computed by `dependencyLayers`
    /// (a genuine cycle) — any one-directional dependency forces its target into an earlier
    /// layer. Union-find recovers those same-component clusters so a cycle is never split across
    /// batches, while independent entries (the common case; every production dependency is a
    /// one-directional parent/child edge, so clusters are singletons in practice) are packed
    /// greedily in deterministic `sortKey` order. A cluster that alone exceeds any of the three
    /// CloudKit ceilings — record count, the shared per-batch byte budget, or one record's own
    /// `maximumRecordBytes` cap — can be neither split without breaking atomicity nor dropped,
    /// so it throws instead of ever emitting a batch CloudKit is guaranteed to reject.
    private static func chunkedBatchRecords(
        entries: [HouseholdZoneRecoveryEntry],
        records: [HouseholdZoneRecoveryPreparedRecord],
        recordByteBudget: Int
    ) throws -> [[HouseholdZoneRecoveryPreparedRecord]] {
        guard !entries.isEmpty else { return [] }
        let indexByTargetKey = Dictionary(uniqueKeysWithValues: entries.enumerated().map {
            ($0.element.identity.target.sortKey, $0.offset)
        })
        var parent = Array(entries.indices)
        func find(_ node: Int) -> Int {
            var root = node
            while parent[root] != root { root = parent[root] }
            var current = node
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            guard rootA != rootB else { return }
            parent[max(rootA, rootB)] = min(rootA, rootB)
        }
        for (index, entry) in entries.enumerated() {
            for dependency in entry.dependencies where dependency.requirement == .required {
                if let dependencyIndex = indexByTargetKey[dependency.identity.target.sortKey] {
                    union(index, dependencyIndex)
                }
            }
        }
        var clusterMembers: [Int: [Int]] = [:]
        for index in entries.indices {
            clusterMembers[find(index), default: []].append(index)
        }
        let orderedClusters = clusterMembers.values
            .map { $0.sorted() }
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }

        var chunks: [[HouseholdZoneRecoveryPreparedRecord]] = []
        var currentChunk: [HouseholdZoneRecoveryPreparedRecord] = []
        var currentRecordCount = 0
        var currentItemBytes = 0

        func flushCurrentChunk() {
            guard !currentChunk.isEmpty else { return }
            chunks.append(currentChunk)
            currentChunk = []
            currentRecordCount = 0
            currentItemBytes = 0
        }

        for cluster in orderedClusters {
            let clusterRecords = cluster.map { records[$0] }
            let clusterItemByteCosts = clusterRecords.map {
                perItemFramingAllowanceBytes + estimatedRecordBytes(for: $0.record)
            }
            guard clusterItemByteCosts.allSatisfy({ $0 <= maximumRecordBytes }) else {
                throw HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable
            }
            let clusterItemBytes = clusterItemByteCosts.reduce(0, +)
            let clusterRecordCount = clusterRecords.count
            guard clusterRecordCount <= maximumBatchRecordCount,
                  clusterItemBytes <= recordByteBudget else {
                throw HouseholdZoneRecoveryApplyPlanError.batchCapacityUnsatisfiable
            }
            let fitsCurrentChunk = currentChunk.isEmpty
                || (currentRecordCount + clusterRecordCount <= maximumBatchRecordCount
                    && currentItemBytes + clusterItemBytes <= recordByteBudget)
            if !fitsCurrentChunk {
                flushCurrentChunk()
            }
            currentChunk.append(contentsOf: clusterRecords)
            currentRecordCount += clusterRecordCount
            currentItemBytes += clusterItemBytes
        }
        flushCurrentChunk()
        return chunks
    }

    /// Fixed per-asset allowance counted against the byte budget in place of the asset's real
    /// size: CKAsset payloads upload out of band from the record's field data, so estimating
    /// their true byte count would over-count the atomic write this budget actually guards.
    private static let assetPayloadAllowanceBytes = 256

    /// Estimated encodable-field bytes for one CKRecord (a prepared record or a receipt record),
    /// excluding the per-item framing allowance applied separately by `framingAllowanceBytes`.
    static func estimatedRecordBytes(for record: CKRecord) -> Int {
        record.allKeys().reduce(0) { total, key in
            guard let value = record[key] else { return total }
            return total + key.utf8.count + estimatedFieldPayloadBytes(value)
        }
    }

    private static func estimatedFieldPayloadBytes(_ value: Any) -> Int {
        if value is CKAsset { return assetPayloadAllowanceBytes }
        if let value = value as? String { return value.utf8.count }
        if let value = value as? Data { return value.count }
        if value is Date { return 8 }
        if value is NSNumber { return 8 }
        if value is CLLocation { return 64 }
        if let value = value as? CKRecord.Reference { return referencePayloadBytes(value) }
        if let values = value as? [String] { return values.reduce(0) { $0 + $1.utf8.count } }
        if let values = value as? [Date] { return values.count * 8 }
        if let values = value as? [Data] { return values.reduce(0) { $0 + $1.count } }
        if let values = value as? [NSNumber] { return values.count * 8 }
        if let values = value as? [CLLocation] { return values.count * 64 }
        if let values = value as? [CKRecord.Reference] {
            return values.reduce(0) { $0 + referencePayloadBytes($1) }
        }
        return 0
    }

    private static func referencePayloadBytes(_ reference: CKRecord.Reference) -> Int {
        reference.recordID.recordName.utf8.count
            + reference.recordID.zoneID.zoneName.utf8.count
            + reference.recordID.zoneID.ownerName.utf8.count
            + 16
    }


    private static func dependencyLayers(
        entries: [HouseholdZoneRecoveryEntry]
    ) throws -> [[HouseholdZoneRecoveryEntry]] {
        let sortedEntries = entries.sorted { $0.identity.target.sortKey < $1.identity.target.sortKey }
        guard !sortedEntries.isEmpty else { return [] }
        let indexByKey = Dictionary(uniqueKeysWithValues: sortedEntries.enumerated().map {
            ($0.element.identity.target.sortKey, $0.offset)
        })
        var adjacency = Array(repeating: [Int](), count: sortedEntries.count)
        for (index, entry) in sortedEntries.enumerated() {
            adjacency[index] = entry.dependencies
                .filter { $0.requirement == .required }
                .compactMap { indexByKey[$0.identity.target.sortKey] }
                .sorted()
        }

        var nextIndex = 0
        var indices = Array<Int?>(repeating: nil, count: sortedEntries.count)
        var lowLinks = Array(repeating: 0, count: sortedEntries.count)
        var stack: [Int] = []
        var onStack = Set<Int>()
        var components: [[Int]] = []

        func connect(_ node: Int) {
            indices[node] = nextIndex
            lowLinks[node] = nextIndex
            nextIndex += 1
            stack.append(node)
            onStack.insert(node)

            for dependency in adjacency[node] {
                if indices[dependency] == nil {
                    connect(dependency)
                    lowLinks[node] = min(lowLinks[node], lowLinks[dependency])
                } else if onStack.contains(dependency), let dependencyIndex = indices[dependency] {
                    lowLinks[node] = min(lowLinks[node], dependencyIndex)
                }
            }

            if lowLinks[node] == indices[node] {
                var component: [Int] = []
                while let member = stack.popLast() {
                    onStack.remove(member)
                    component.append(member)
                    if member == node { break }
                }
                components.append(component.sorted())
            }
        }

        for node in sortedEntries.indices where indices[node] == nil {
            connect(node)
        }
        components.sort {
            sortedEntries[$0[0]].identity.target.sortKey
                < sortedEntries[$1[0]].identity.target.sortKey
        }
        var componentByNode: [Int: Int] = [:]
        for (componentIndex, component) in components.enumerated() {
            for node in component { componentByNode[node] = componentIndex }
        }
        var dependencies = Array(repeating: Set<Int>(), count: components.count)
        for (node, nodeDependencies) in adjacency.enumerated() {
            guard let component = componentByNode[node] else { continue }
            for dependencyNode in nodeDependencies {
                guard let dependencyComponent = componentByNode[dependencyNode],
                      dependencyComponent != component else { continue }
                dependencies[component].insert(dependencyComponent)
            }
        }

        var completed = Set<Int>()
        var layers: [[HouseholdZoneRecoveryEntry]] = []
        while completed.count < components.count {
            let ready = components.indices.filter {
                !completed.contains($0) && dependencies[$0].isSubset(of: completed)
            }
            guard !ready.isEmpty else {
                throw HouseholdZoneRecoveryApplyPlanError.batchPlanDiverged
            }
            let layerNodes = ready.flatMap { components[$0] }.sorted()
            layers.append(layerNodes.map { sortedEntries[$0] })
            completed.formUnion(ready)
        }
        return layers
    }
}
#endif
