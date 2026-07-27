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
    public let records: [HouseholdZoneRecoveryPreparedRecord]

    public init(index: Int, digest: String, records: [HouseholdZoneRecoveryPreparedRecord]) {
        self.index = index
        self.digest = digest
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

public struct HouseholdZoneRecoveryReceipt: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let recordType = "HouseholdRecoveryReceipt"

    public let formatVersion: Int
    public let manifestDigest: String
    public let targetZoneOwnerName: String
    public let targetZoneName: String
    public let batchDigests: [String]
    public let completedBatchDigests: [String]
    public let expectedTargetFingerprint: String
    public let isTerminalComplete: Bool

    public static func recordName(manifestDigest: String) -> String {
        "recovery:\(manifestDigest)"
    }

    public init(
        formatVersion: Int = HouseholdZoneRecoveryReceipt.currentFormatVersion,
        manifestDigest: String,
        targetZoneOwnerName: String,
        targetZoneName: String,
        batchDigests: [String],
        completedBatchDigests: [String] = [],
        expectedTargetFingerprint: String,
        isTerminalComplete: Bool = false
    ) throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw HouseholdZoneRecoveryApplyPlanError.unsupportedReceiptVersion
        }
        guard !manifestDigest.isEmpty,
              !targetZoneOwnerName.isEmpty,
              !targetZoneName.isEmpty,
              !expectedTargetFingerprint.isEmpty,
              Set(batchDigests).count == batchDigests.count,
              completedBatchDigests.count <= batchDigests.count,
              Array(batchDigests.prefix(completedBatchDigests.count)) == completedBatchDigests,
              !isTerminalComplete || completedBatchDigests == batchDigests else {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
        self.formatVersion = formatVersion
        self.manifestDigest = manifestDigest
        self.targetZoneOwnerName = targetZoneOwnerName
        self.targetZoneName = targetZoneName
        self.batchDigests = batchDigests
        self.completedBatchDigests = completedBatchDigests
        self.expectedTargetFingerprint = expectedTargetFingerprint
        self.isTerminalComplete = isTerminalComplete
    }

    public init(record: CKRecord) throws {
        guard record.recordType == Self.recordType,
              let formatNumber = record["formatVersion"] as? NSNumber,
              let manifestDigest = record["manifestDigest"] as? String,
              let targetZoneOwnerName = record["targetZoneOwnerName"] as? String,
              let targetZoneName = record["targetZoneName"] as? String,
              let batchDigests = record["batchDigests"] as? [String],
              let completedBatchDigests = record["completedBatchDigests"] as? [String],
              let expectedTargetFingerprint = record["expectedTargetFingerprint"] as? String,
              let terminalNumber = record["isTerminalComplete"] as? NSNumber,
              record.recordID.recordName == Self.recordName(manifestDigest: manifestDigest),
              record.recordID.zoneID.ownerName == targetZoneOwnerName,
              record.recordID.zoneID.zoneName == targetZoneName else {
            throw HouseholdZoneRecoveryApplyPlanError.invalidReceipt
        }
        try self.init(
            formatVersion: formatNumber.intValue,
            manifestDigest: manifestDigest,
            targetZoneOwnerName: targetZoneOwnerName,
            targetZoneName: targetZoneName,
            batchDigests: batchDigests,
            completedBatchDigests: completedBatchDigests,
            expectedTargetFingerprint: expectedTargetFingerprint,
            isTerminalComplete: terminalNumber.boolValue)
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
        record["targetZoneOwnerName"] = targetZoneOwnerName as CKRecordValue
        record["targetZoneName"] = targetZoneName as CKRecordValue
        record["batchDigests"] = batchDigests as CKRecordValue
        record["completedBatchDigests"] = completedBatchDigests as CKRecordValue
        record["expectedTargetFingerprint"] = expectedTargetFingerprint as CKRecordValue
        record["isTerminalComplete"] = isTerminalComplete as CKRecordValue
        return record
    }

    public func recordingCompletedBatch(
        _ digest: String,
        resultingTargetFingerprint: String
    ) throws -> Self {
        guard !isTerminalComplete,
              completedBatchDigests.count < batchDigests.count,
              batchDigests[completedBatchDigests.count] == digest else {
            throw HouseholdZoneRecoveryApplyPlanError.batchOutOfOrder
        }
        return try Self(
            manifestDigest: manifestDigest,
            targetZoneOwnerName: targetZoneOwnerName,
            targetZoneName: targetZoneName,
            batchDigests: batchDigests,
            completedBatchDigests: completedBatchDigests + [digest],
            expectedTargetFingerprint: resultingTargetFingerprint)
    }

    public func markingTerminalComplete(observedTargetFingerprint: String) throws -> Self {
        guard completedBatchDigests == batchDigests else {
            throw HouseholdZoneRecoveryApplyPlanError.incompleteReceipt
        }
        guard observedTargetFingerprint == expectedTargetFingerprint else {
            throw HouseholdZoneRecoveryApplyPlanError.targetDiverged
        }
        if isTerminalComplete { return self }
        return try Self(
            manifestDigest: manifestDigest,
            targetZoneOwnerName: targetZoneOwnerName,
            targetZoneName: targetZoneName,
            batchDigests: batchDigests,
            completedBatchDigests: completedBatchDigests,
            expectedTargetFingerprint: expectedTargetFingerprint,
            isTerminalComplete: true)
    }
}

public struct HouseholdZoneRecoveryApplyPlan {
    public let manifestDigest: String
    public let targetZoneID: CKRecordZone.ID
    public let stagingDirectoryURL: URL
    public let batches: [HouseholdZoneRecoveryApplyBatch]
    public let initialReceipt: HouseholdZoneRecoveryReceipt

    public var records: [HouseholdZoneRecoveryPreparedRecord] {
        batches.flatMap(\.records)
    }

    public init(
        manifest: HouseholdZoneRecoveryManifest,
        approval: HouseholdZoneRecoveryApproval,
        sourceRecords: [CKRecord],
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

        let writableEntries = manifest.approvedEntries.filter(Self.requiresSourceWrite)
        let sources = try Self.indexSourceRecords(sourceRecords, sourceZoneID: sourceZoneID)
        var preparedByKey: [String: HouseholdZoneRecoveryPreparedRecord] = [:]
        for entry in writableEntries {
            let key = entry.identity.source.sortKey
            guard let source = sources[key] else {
                throw HouseholdZoneRecoveryApplyPlanError.missingSourceRecord(key)
            }
            let prepared = try Self.reconstruct(
                entry: entry,
                source: source,
                sourceZoneID: sourceZoneID,
                targetZoneID: targetZoneID,
                stagingDirectoryURL: stagingDirectoryURL)
            preparedByKey[key] = prepared
        }

        let layers = try Self.dependencyLayers(entries: writableEntries)
        var batches: [HouseholdZoneRecoveryApplyBatch] = []
        for (index, layer) in layers.enumerated() {
            let records = try layer.map { entry -> HouseholdZoneRecoveryPreparedRecord in
                guard let prepared = preparedByKey[entry.identity.source.sortKey] else {
                    throw HouseholdZoneRecoveryApplyPlanError.missingSourceRecord(
                        entry.identity.source.sortKey)
                }
                return prepared
            }
            let digest = try Self.batchDigest(
                manifestDigest: manifestDigest,
                index: index,
                records: records)
            batches.append(HouseholdZoneRecoveryApplyBatch(
                index: index,
                digest: digest,
                records: records))
        }

        self.manifestDigest = manifestDigest
        self.targetZoneID = targetZoneID
        self.stagingDirectoryURL = stagingDirectoryURL
        self.batches = batches
        self.initialReceipt = try HouseholdZoneRecoveryReceipt(
            manifestDigest: manifestDigest,
            targetZoneOwnerName: targetZoneID.ownerName,
            targetZoneName: targetZoneID.zoneName,
            batchDigests: batches.map(\.digest),
            expectedTargetFingerprint: manifest.targetInputFingerprint)
    }

    public func resume(
        receipt: HouseholdZoneRecoveryReceipt,
        observedTargetFingerprint: String
    ) throws -> HouseholdZoneRecoveryReceipt {
        guard receipt.manifestDigest == manifestDigest else {
            throw HouseholdZoneRecoveryApplyPlanError.differentManifestDigest
        }
        guard receipt.targetZoneOwnerName == targetZoneID.ownerName,
              receipt.targetZoneName == targetZoneID.zoneName,
              receipt.expectedTargetFingerprint == observedTargetFingerprint else {
            throw HouseholdZoneRecoveryApplyPlanError.targetDiverged
        }
        guard receipt.batchDigests == batches.map(\.digest) else {
            throw HouseholdZoneRecoveryApplyPlanError.batchPlanDiverged
        }
        return receipt
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
