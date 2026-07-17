#if canImport(CloudKit)
import CloudKit
import CoreFoundation
import CoreLocation
import CryptoKit
import Foundation

public enum MirrorDatabaseScope: String, Codable, Equatable, Hashable, Sendable {
    case `private`
    case shared
}

public enum MirrorRole: String, Codable, Equatable, Hashable, Sendable {
    case owner
    case participant
}

public struct MirrorScope: Codable, Equatable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public static let currentContainerIdentifier = "iCloud.app.simmersmith.cloud"

    public let formatVersion: Int
    public let containerIdentifier: String
    public let databaseScope: MirrorDatabaseScope
    public let accountRecordName: String
    public let zoneOwnerName: String
    public let zoneName: String
    public let householdID: String
    public let role: MirrorRole

    public init(
        accountRecordName: String,
        zoneOwnerName: String,
        zoneName: String,
        householdID: String,
        role: MirrorRole,
        databaseScope: MirrorDatabaseScope,
        containerIdentifier: String = MirrorScope.currentContainerIdentifier,
        formatVersion: Int = MirrorScope.currentFormatVersion
    ) {
        self.formatVersion = formatVersion
        self.containerIdentifier = containerIdentifier
        self.databaseScope = databaseScope
        self.accountRecordName = accountRecordName
        self.zoneOwnerName = zoneOwnerName
        self.zoneName = zoneName
        self.householdID = householdID
        self.role = role
    }

    public func matches(_ other: MirrorScope) -> Bool { self == other }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              containerIdentifier == Self.currentContainerIdentifier,
              !accountRecordName.isEmpty,
              !zoneOwnerName.isEmpty,
              !zoneName.isEmpty,
              !householdID.isEmpty,
              (role == .owner && databaseScope == .private)
                || (role == .participant && databaseScope == .shared) else {
            throw MirrorCheckpointError.scopeMismatch
        }
    }

    public var cacheKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(self)
        return ShadowMirrorDigest.sha256(data)
    }
}

public struct MirrorScopeAnchor: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let scope: MirrorScope
    public let cacheKey: String
    public let integrityDigest: String

    public init(scope: MirrorScope) throws {
        try scope.validate()
        formatVersion = Self.currentFormatVersion
        self.scope = scope
        cacheKey = scope.cacheKey
        integrityDigest = try Self.integrityDigest(
            formatVersion: formatVersion,
            scope: scope,
            cacheKey: cacheKey)
    }

    public func validate(for expectedScope: MirrorScope, in scopeDirectory: URL) throws {
        try expectedScope.validate()
        try scope.validate()
        guard formatVersion == Self.currentFormatVersion,
              scope == expectedScope,
              cacheKey == scope.cacheKey,
              scopeDirectory.lastPathComponent == cacheKey,
              integrityDigest == (try Self.integrityDigest(
                  formatVersion: formatVersion,
                  scope: scope,
                  cacheKey: cacheKey)) else {
            throw MirrorCheckpointError.scopeMismatch
        }
    }

    private static func integrityDigest(
        formatVersion: Int,
        scope: MirrorScope,
        cacheKey: String
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ShadowMirrorDigest.sha256(try encoder.encode(IntegrityPayload(
            formatVersion: formatVersion,
            scope: scope,
            cacheKey: cacheKey)))
    }

    private struct IntegrityPayload: Codable {
        let formatVersion: Int
        let scope: MirrorScope
        let cacheKey: String
    }
}

public struct MirrorRecordIdentity: Codable, Equatable, Hashable, Sendable {
    public let recordType: String
    public let recordName: String
    public let zoneOwnerName: String
    public let zoneName: String

    public init(recordType: String, recordName: String, zoneOwnerName: String, zoneName: String) {
        self.recordType = recordType
        self.recordName = recordName
        self.zoneOwnerName = zoneOwnerName
        self.zoneName = zoneName
    }

    public init(_ record: CKRecord) {
        self.init(
            recordType: record.recordType,
            recordName: record.recordID.recordName,
            zoneOwnerName: record.recordID.zoneID.ownerName,
            zoneName: record.recordID.zoneID.zoneName)
    }

    public var sortKey: String {
        "\(recordType)|\(zoneOwnerName)|\(zoneName)|\(recordName)"
    }
}

public struct MirrorAssetEnvelope: Codable, Equatable, Sendable {
    public let fieldName: String
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String

    public init(fieldName: String, relativePath: String, byteCount: Int, sha256: String) {
        self.fieldName = fieldName
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum ShadowMirrorRecordError: Error, Equatable, CustomStringConvertible {
    case missingAsset(String)
    case unreadableAsset(String)
    case invalidAsset(String)
    case invalidArchive
    case identityMismatch

    public var description: String {
        switch self {
        case .missingAsset(let field): return "Missing CKAsset file for \(field)"
        case .unreadableAsset(let field): return "Unreadable CKAsset file for \(field)"
        case .invalidAsset(let field): return "Invalid CKAsset envelope for \(field)"
        case .invalidArchive: return "Invalid secure CKRecord archive"
        case .identityMismatch: return "Archived CKRecord identity does not match its envelope"
        }
    }
}

public struct ShadowMirrorRecordEnvelope: Codable, Equatable, Sendable {
    public let identity: MirrorRecordIdentity
    public let archiveData: Data
    public let assets: [MirrorAssetEnvelope]
    public let assetDirectoryPath: String

    public init(
        identity: MirrorRecordIdentity,
        archiveData: Data,
        assets: [MirrorAssetEnvelope],
        assetDirectoryPath: String = ""
    ) {
        self.identity = identity
        self.archiveData = archiveData
        self.assets = assets
        self.assetDirectoryPath = assetDirectoryPath
    }

    public static func archive(_ record: CKRecord, in directory: URL) throws -> Self {
        let directory = directory.standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = record.copy() as! CKRecord
        var assets: [MirrorAssetEnvelope] = []
        for fieldName in record.allKeys().sorted() {
            guard let asset = record[fieldName] as? CKAsset else { continue }
            guard let sourceURL = asset.fileURL else {
                throw ShadowMirrorRecordError.missingAsset(fieldName)
            }
            let bytes: Data
            do {
                bytes = try Data(contentsOf: sourceURL)
            } catch {
                throw ShadowMirrorRecordError.unreadableAsset(fieldName)
            }
            guard !bytes.isEmpty else {
                throw ShadowMirrorRecordError.invalidAsset(fieldName)
            }
            let relativePath = assetFilename(record: record, fieldName: fieldName)
            let destinationURL = directory.appendingPathComponent(relativePath)
            do {
                try bytes.write(to: destinationURL, options: .atomic)
            } catch {
                throw ShadowMirrorRecordError.unreadableAsset(fieldName)
            }
            let digest = ShadowMirrorDigest.sha256(bytes)
            assets.append(MirrorAssetEnvelope(
                fieldName: fieldName,
                relativePath: relativePath,
                byteCount: bytes.count,
                sha256: digest))
            copy[fieldName] = CKAsset(fileURL: destinationURL)
        }
        let archiveData: Data
        do {
            archiveData = try NSKeyedArchiver.archivedData(
                withRootObject: copy, requiringSecureCoding: true)
        } catch {
            throw ShadowMirrorRecordError.invalidArchive
        }
        return Self(
            identity: MirrorRecordIdentity(record),
            archiveData: archiveData,
            assets: assets,
            assetDirectoryPath: directory.path)
    }

    public func decode() throws -> CKRecord {
        let indexedFields = assets.map(\.fieldName)
        guard Set(indexedFields).count == indexedFields.count,
              assets.allSatisfy({
                  !$0.fieldName.isEmpty
                    && !$0.relativePath.isEmpty
                    && $0.relativePath == URL(fileURLWithPath: $0.relativePath).lastPathComponent
                    && $0.relativePath != "."
                    && $0.relativePath != ".."
              }) else {
            throw ShadowMirrorRecordError.invalidArchive
        }
        for asset in assets {
            let url = URL(fileURLWithPath: assetDirectoryPath)
                .appendingPathComponent(asset.relativePath)
            let bytes: Data
            do {
                bytes = try Data(contentsOf: url)
            } catch {
                throw ShadowMirrorRecordError.unreadableAsset(asset.fieldName)
            }
            guard bytes.count == asset.byteCount,
                  ShadowMirrorDigest.sha256(bytes) == asset.sha256 else {
                throw ShadowMirrorRecordError.invalidAsset(asset.fieldName)
            }
        }
        let record: CKRecord
        do {
            record = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: archiveData)
                ?? { throw ShadowMirrorRecordError.invalidArchive }()
        } catch let error as ShadowMirrorRecordError {
            throw error
        } catch {
            throw ShadowMirrorRecordError.invalidArchive
        }
        guard MirrorRecordIdentity(record) == identity else {
            throw ShadowMirrorRecordError.identityMismatch
        }
        let archivedAssetFields = Set(record.allKeys().filter { record[$0] is CKAsset })
        guard archivedAssetFields == Set(indexedFields) else {
            throw ShadowMirrorRecordError.invalidArchive
        }
        for asset in assets {
            guard let archivedAsset = record[asset.fieldName] as? CKAsset,
                  let url = archivedAsset.fileURL,
                  url.path == URL(fileURLWithPath: assetDirectoryPath)
                    .appendingPathComponent(asset.relativePath).path else {
                throw ShadowMirrorRecordError.invalidAsset(asset.fieldName)
            }
        }
        return record
    }

    private static func assetFilename(record: CKRecord, fieldName: String) -> String {
        let key = "\(record.recordID.zoneID.ownerName)|\(record.recordID.zoneID.zoneName)|\(record.recordID.recordName)|\(fieldName)"
        return "asset-\(ShadowMirrorDigest.sha256(Data(key.utf8))).bin"
    }
}

public struct MirrorDeliveryState: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case pending
        case sent
        case blockedPermanent
        case supersededByRemoteDelete
    }

    public let state: State
    public let sentSequence: UInt64?
    public let sentGeneration: UInt64?

    public init(state: State, sentSequence: UInt64? = nil, sentGeneration: UInt64? = nil) {
        self.state = state
        self.sentSequence = sentSequence
        self.sentGeneration = sentGeneration
    }

    public static let pending = Self(state: .pending)

    public static func sent(sequence: UInt64, generation: UInt64) -> Self {
        Self(state: .sent, sentSequence: sequence, sentGeneration: generation)
    }

    public static func blockedPermanent(sequence: UInt64, generation: UInt64) -> Self {
        Self(state: .blockedPermanent, sentSequence: sequence, sentGeneration: generation)
    }

    /// Terminal: a remote delete superseded this local save before authority. The archived
    /// payload stays available to diagnostics/recovery evidence only — it is excluded from
    /// projection overlay, tombstones, and engine pending changes, and contributes to
    /// intervention rather than a retryable pending count.
    public static func supersededByRemoteDelete(sequence: UInt64, generation: UInt64) -> Self {
        Self(state: .supersededByRemoteDelete, sentSequence: sequence, sentGeneration: generation)
    }
}

public struct MirrorOutboxIntent: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case save
        case delete
    }

    public let sequence: UInt64
    public let mutationGeneration: UInt64
    public let operation: Operation
    public let record: ShadowMirrorRecordEnvelope?
    public let tombstone: MirrorRecordIdentity?
    public let changedFields: [String]
    public let clearedFields: [String]
    public let delivery: MirrorDeliveryState

    public init(
        sequence: UInt64,
        mutationGeneration: UInt64,
        operation: Operation,
        record: ShadowMirrorRecordEnvelope? = nil,
        tombstone: MirrorRecordIdentity? = nil,
        changedFields: [String] = [],
        clearedFields: [String] = [],
        delivery: MirrorDeliveryState = .pending
    ) {
        self.sequence = sequence
        self.mutationGeneration = mutationGeneration
        self.operation = operation
        self.record = record
        self.tombstone = tombstone
        self.changedFields = Array(Set(changedFields)).sorted()
        self.clearedFields = Array(Set(clearedFields)).sorted()
        self.delivery = delivery
    }

    public func validate() throws {
        guard sequence > 0, mutationGeneration > 0 else {
            throw MirrorCheckpointError.invalidOutbox("non-positive sequence or mutation generation")
        }
        switch operation {
        case .save:
            guard record != nil, tombstone == nil else {
                throw MirrorCheckpointError.invalidOutbox("save must contain one record and no tombstone")
            }
            guard Set(changedFields).isDisjoint(with: Set(clearedFields)) else {
                throw MirrorCheckpointError.invalidOutbox("changed and cleared fields overlap")
            }
        case .delete:
            guard record == nil, tombstone != nil,
                  changedFields.isEmpty, clearedFields.isEmpty else {
                throw MirrorCheckpointError.invalidOutbox("delete must contain one tombstone and no field payload")
            }
        }
        switch delivery.state {
        case .pending:
            guard delivery.sentSequence == nil, delivery.sentGeneration == nil else {
                throw MirrorCheckpointError.invalidOutbox("pending delivery carries a send stamp")
            }
        case .sent, .blockedPermanent, .supersededByRemoteDelete:
            guard delivery.sentSequence == sequence,
                  delivery.sentGeneration == mutationGeneration else {
                throw MirrorCheckpointError.invalidOutbox("delivery stamp does not identify the exact intent")
            }
            guard delivery.state != .supersededByRemoteDelete || operation == .save else {
                throw MirrorCheckpointError.invalidOutbox("remote-delete supersession requires a save intent")
            }
        }
    }
}

/// Durable evidence that a post-checkpoint transition removed (or terminally resolved) a local
/// intent. P2d's engine reconciliation may drop a serialized pending change only when one of
/// these proofs — or a terminal outbox row — covers it; a stale serialized pending without a
/// proof is an invariant breach that fails closed.
public struct MirrorOutboxRemovalProof: Codable, Equatable, Hashable, Sendable {
    public enum Reason: String, Codable, Equatable, Hashable, Sendable {
        case acknowledged
        case terminalFailure
        case remoteDeleteSupersession
        case supersededByNewerMutation
    }

    public let identity: MirrorRecordIdentity
    public let operation: MirrorOutboxIntent.Operation
    public let sequence: UInt64
    public let mutationGeneration: UInt64
    public let reason: Reason

    public init(
        identity: MirrorRecordIdentity,
        operation: MirrorOutboxIntent.Operation,
        sequence: UInt64,
        mutationGeneration: UInt64,
        reason: Reason
    ) {
        self.identity = identity
        self.operation = operation
        self.sequence = sequence
        self.mutationGeneration = mutationGeneration
        self.reason = reason
    }
}

public struct MirrorReceiptIndex: Codable, Equatable, Sendable {
    public let receipts: [MirrorRecordIdentity]

    public init(receipts: [MirrorRecordIdentity]) {
        self.receipts = receipts.sorted {
            ($0.zoneOwnerName, $0.zoneName, $0.recordName) < ($1.zoneOwnerName, $1.zoneName, $1.recordName)
        }
    }

    @discardableResult
    public func validated(by records: [CKRecord]) throws -> Bool {
        guard Set(receipts).count == receipts.count,
              receipts.allSatisfy({ $0.recordType == "MigrationReceipt" }) else {
            throw MirrorCheckpointError.invalidManifest
        }
        let indexed = Set(receipts)
        let available = Set(records
            .filter { $0.recordType == "MigrationReceipt" }
            .map(MirrorRecordIdentity.init))
        guard indexed == available else {
            let unmatched = indexed.symmetricDifference(available)
                .sorted { $0.sortKey < $1.sortKey }
                .first
            throw MirrorCheckpointError.missingReceipt(unmatched?.recordName ?? "unknown")
        }
        return true
    }
}

public struct MirrorEngineState: Codable, Equatable, Sendable {
    public let serialization: Data
    public let coverageRevision: UInt64
    public let zoneEnsured: Bool

    public init(serialization: Data, coverageRevision: UInt64, zoneEnsured: Bool) {
        self.serialization = serialization
        self.coverageRevision = coverageRevision
        self.zoneEnsured = zoneEnsured
    }
}

public enum MirrorCheckpointError: Error, Equatable, CustomStringConvertible {
    case scopeMismatch
    case missingReceipt(String)
    case invalidManifest
    case invalidOutbox(String)
    case notCacheReady(String)

    public var description: String {
        switch self {
        case .scopeMismatch: return "Checkpoint scope does not match the requested scope"
        case .missingReceipt(let recordName): return "Checkpoint is missing receipt \(recordName)"
        case .invalidManifest: return "Checkpoint manifest is invalid"
        case .invalidOutbox(let reason): return "Checkpoint outbox is invalid: \(reason)"
        case .notCacheReady(let reason): return "Checkpoint is not cache-ready: \(reason)"
        }
    }
}

public struct MirrorCheckpointManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let scope: MirrorScope
    public let generationID: String
    public let recordArchiveDigests: [String: String]
    public let assetDigests: [String: String]
    public let logicalDigest: String
    public let mirrorCoverageRevision: UInt64
    public let lastIntentSequence: UInt64
    public let engineStateDigest: String

    public init(
        scope: MirrorScope,
        generationID: String,
        recordArchiveDigests: [String: String],
        assetDigests: [String: String],
        logicalDigest: String,
        mirrorCoverageRevision: UInt64,
        lastIntentSequence: UInt64,
        engineStateDigest: String
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.scope = scope
        self.generationID = generationID
        self.recordArchiveDigests = recordArchiveDigests
        self.assetDigests = assetDigests
        self.logicalDigest = logicalDigest
        self.mirrorCoverageRevision = mirrorCoverageRevision
        self.lastIntentSequence = lastIntentSequence
        self.engineStateDigest = engineStateDigest
    }
}

public struct MirrorCheckpointBundle: Codable, Equatable, Sendable {
    public let manifest: MirrorCheckpointManifest
    public let records: [ShadowMirrorRecordEnvelope]
    public let tombstones: [MirrorRecordIdentity]
    public let outbox: [MirrorOutboxIntent]
    public let receipts: MirrorReceiptIndex
    public let engineState: MirrorEngineState

    public init(
        scope: MirrorScope,
        generationID: String,
        records: [ShadowMirrorRecordEnvelope],
        tombstones: [MirrorRecordIdentity] = [],
        outbox: [MirrorOutboxIntent] = [],
        receipts: MirrorReceiptIndex = MirrorReceiptIndex(receipts: []),
        engineState: MirrorEngineState,
        lastIncludedIntentSequence: UInt64
    ) throws {
        guard scope.formatVersion == MirrorScope.currentFormatVersion,
              scope.containerIdentifier == MirrorScope.currentContainerIdentifier,
              !scope.accountRecordName.isEmpty,
              !scope.zoneOwnerName.isEmpty,
              !scope.zoneName.isEmpty,
              !scope.householdID.isEmpty,
              !generationID.isEmpty,
              (scope.role == .owner && scope.databaseScope == .private)
                || (scope.role == .participant && scope.databaseScope == .shared) else {
            throw MirrorCheckpointError.scopeMismatch
        }
        let orderedRecords = records.sorted { $0.identity.sortKey < $1.identity.sortKey }
        let orderedTombstones = tombstones.sorted { $0.sortKey < $1.sortKey }
        let orderedOutbox = outbox.sorted { $0.sequence < $1.sequence }
        guard Set(orderedRecords.map(\.identity)).count == orderedRecords.count,
              Set(orderedTombstones).count == orderedTombstones.count,
              Set(orderedOutbox.map(\.sequence)).count == orderedOutbox.count,
              Set(orderedRecords.map(\.identity)).isDisjoint(with: Set(orderedTombstones)),
              lastIncludedIntentSequence >= (orderedOutbox.last?.sequence ?? 0) else {
            throw MirrorCheckpointError.invalidManifest
        }
        try orderedOutbox.forEach { try $0.validate() }
        let decodedRecords = try orderedRecords.map { try $0.decode() }
        try receipts.validated(by: decodedRecords)
        let logicalDigest = try ShadowMirrorCanonicalDigest.bundle(
            records: decodedRecords,
            tombstones: orderedTombstones,
            outbox: orderedOutbox,
            receipts: receipts)
        let archiveDigests = Dictionary(uniqueKeysWithValues: orderedRecords.map {
            ($0.identity.sortKey, ShadowMirrorDigest.sha256($0.archiveData))
        })
        let assetDigests = Dictionary(uniqueKeysWithValues: orderedRecords.flatMap { envelope in
            envelope.assets.map { ("\(envelope.identity.sortKey)|\($0.fieldName)", $0.sha256) }
        })
        self.manifest = MirrorCheckpointManifest(
            scope: scope,
            generationID: generationID,
            recordArchiveDigests: archiveDigests,
            assetDigests: assetDigests,
            logicalDigest: logicalDigest,
            mirrorCoverageRevision: engineState.coverageRevision,
            lastIntentSequence: lastIncludedIntentSequence,
            engineStateDigest: ShadowMirrorCanonicalDigest.engineState(engineState))
        self.records = orderedRecords
        self.tombstones = orderedTombstones
        self.outbox = orderedOutbox
        self.receipts = receipts
        self.engineState = engineState
    }

    public static func capture(
        scope: MirrorScope,
        generationID: String,
        records: [CKRecord],
        in assetDirectory: URL,
        tombstones: [MirrorRecordIdentity] = [],
        outbox: [MirrorOutboxIntent] = [],
        receipts: MirrorReceiptIndex = MirrorReceiptIndex(receipts: []),
        engineState: MirrorEngineState,
        lastIncludedIntentSequence: UInt64
    ) throws -> Self {
        let envelopes = try records.map { try ShadowMirrorRecordEnvelope.archive($0, in: assetDirectory) }
        return try Self(
            scope: scope,
            generationID: generationID,
            records: envelopes,
            tombstones: tombstones,
            outbox: outbox,
            receipts: receipts,
            engineState: engineState,
            lastIncludedIntentSequence: lastIncludedIntentSequence)
    }

    public func validate(for scope: MirrorScope) throws {
        guard manifest.scope == scope,
              scope.formatVersion == MirrorScope.currentFormatVersion,
              scope.containerIdentifier == MirrorScope.currentContainerIdentifier,
              !manifest.generationID.isEmpty else {
            throw MirrorCheckpointError.scopeMismatch
        }
        guard manifest.formatVersion == MirrorCheckpointManifest.currentFormatVersion else {
            throw MirrorCheckpointError.invalidManifest
        }
        let orderedOutbox = outbox.sorted { $0.sequence < $1.sequence }
        guard manifest.mirrorCoverageRevision == engineState.coverageRevision,
              manifest.lastIntentSequence >= (orderedOutbox.last?.sequence ?? 0),
              orderedOutbox == outbox,
              Set(outbox.map(\.sequence)).count == outbox.count,
              Set(records.map(\.identity)).count == records.count,
              Set(tombstones).count == tombstones.count,
              Set(records.map(\.identity)).isDisjoint(with: Set(tombstones)) else {
            throw MirrorCheckpointError.invalidManifest
        }
        try outbox.forEach { try $0.validate() }
        let archiveDigests = Dictionary(uniqueKeysWithValues: records.map {
            ($0.identity.sortKey, ShadowMirrorDigest.sha256($0.archiveData))
        })
        let assetDigests = Dictionary(uniqueKeysWithValues: records.flatMap { envelope in
            envelope.assets.map { ("\(envelope.identity.sortKey)|\($0.fieldName)", $0.sha256) }
        })
        guard archiveDigests == manifest.recordArchiveDigests,
              assetDigests == manifest.assetDigests else {
            throw MirrorCheckpointError.invalidManifest
        }
        let decodedRecords = try records.map { try $0.decode() }
        try receipts.validated(by: decodedRecords)
        let digest = try ShadowMirrorCanonicalDigest.bundle(
            records: decodedRecords,
            tombstones: tombstones,
            outbox: outbox,
            receipts: receipts)
        guard digest == manifest.logicalDigest else { throw MirrorCheckpointError.invalidManifest }
        guard ShadowMirrorCanonicalDigest.engineState(engineState) == manifest.engineStateDigest else {
            throw MirrorCheckpointError.invalidManifest
        }
    }
}

/// Pins every asset root a materialized bootstrap still references — journal-asset sequence
/// directories and the selected generation — until the constructed session has rebound or
/// released those records. Publication-time journal-asset cleanup skips pinned sequences.
/// Intentional lifecycle root clearing (account boundary, reset) overrides leases.
public struct MirrorGenerationLease: Equatable, Sendable {
    public let id: UUID
    public let generationID: String?
    public let pinnedJournalAssetSequences: Set<UInt64>

    public init(id: UUID, generationID: String?, pinnedJournalAssetSequences: Set<UInt64>) {
        self.id = id
        self.generationID = generationID
        self.pinnedJournalAssetSequences = pinnedJournalAssetSequences
    }
}

public enum ShadowMirrorDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ShadowMirrorCanonicalDigest {
    public static func record(_ record: CKRecord) throws -> String {
        let writer = try CanonicalWriter(record: record)
        return ShadowMirrorDigest.sha256(writer.data)
    }

    public static func bundle(
        records: [CKRecord],
        tombstones: [MirrorRecordIdentity],
        outbox: [MirrorOutboxIntent],
        receipts: MirrorReceiptIndex
    ) throws -> String {
        var writer = CanonicalWriter()
        writer.append("shadow-mirror-bundle-v1")
        writer.append(records.count)
        for record in records.sorted(by: { MirrorRecordIdentity($0).sortKey < MirrorRecordIdentity($1).sortKey }) {
            writer.append("record")
            writer.append(try CanonicalWriter(record: record).data)
        }
        writer.append(tombstones.count)
        for tombstone in tombstones.sorted(by: { $0.sortKey < $1.sortKey }) {
            writer.append("tombstone")
            writer.append(tombstone)
        }
        writer.append(outbox.count)
        for intent in outbox.sorted(by: { $0.sequence < $1.sequence }) {
            try intent.validate()
            writer.append("intent")
            writer.append(intent.sequence)
            writer.append(intent.mutationGeneration)
            writer.append(intent.operation.rawValue)
            writer.append(intent.changedFields.sorted())
            writer.append(intent.clearedFields.sorted())
            writer.append(intent.delivery.state.rawValue)
            writer.append(intent.delivery.sentSequence)
            writer.append(intent.delivery.sentGeneration)
            if let envelope = intent.record {
                writer.append("save-record")
                writer.append(try CanonicalWriter(record: envelope.decode()).data)
            } else {
                writer.append("no-save-record")
            }
            if let tombstone = intent.tombstone {
                writer.append("delete-tombstone")
                writer.append(tombstone)
            } else {
                writer.append("no-delete-tombstone")
            }
        }
        let receiptIdentities = receipts.receipts.sorted { $0.sortKey < $1.sortKey }
        writer.append(receiptIdentities.count)
        for receipt in receiptIdentities {
            writer.append("receipt")
            writer.append(receipt)
        }
        return ShadowMirrorDigest.sha256(writer.data)
    }

    public static func engineState(_ state: MirrorEngineState) -> String {
        var writer = CanonicalWriter()
        writer.append("shadow-mirror-engine-state-v1")
        writer.append(state.serialization)
        writer.append(state.coverageRevision)
        writer.append(state.zoneEnsured ? "zone-ensured" : "zone-not-ensured")
        return ShadowMirrorDigest.sha256(writer.data)
    }
}

private struct CanonicalWriter {
    var data = Data()

    init() {}

    init(record: CKRecord) throws {
        append(record.recordType)
        append(record.recordID.recordName)
        append(record.recordID.zoneID.ownerName)
        append(record.recordID.zoneID.zoneName)
        append(record.recordChangeTag)
        append(record.creationDate)
        append(record.modificationDate)
        append(record.creatorUserRecordID)
        append(record.lastModifiedUserRecordID)
        append(record.parent)
        append(record.share)
        append(record.changedKeys().sorted())
        for key in record.allKeys().sorted() {
            append(key)
            try append(record[key] as Any?)
        }
    }

    mutating func append(_ value: String?) {
        guard let value else { append("optional-string-none"); return }
        append("optional-string-some")
        append(value)
    }

    mutating func append(_ value: Date?) {
        guard let value else { append("<nil-date>"); return }
        append("date")
        append(value.timeIntervalSince1970.bitPattern)
    }

    mutating func append(_ value: CKRecord.Reference?) {
        guard let value else { append("<nil-reference>"); return }
        append("reference")
        append(value.recordID.recordName)
        append(value.recordID.zoneID.ownerName)
        append(value.recordID.zoneID.zoneName)
        append(Int(value.action.rawValue))
    }

    mutating func append(_ value: CKRecord.ID?) {
        guard let value else { append("<nil-id>"); return }
        append("record-id")
        append(value.recordName)
        append(value.zoneID.ownerName)
        append(value.zoneID.zoneName)
    }

    mutating func append(_ values: [String]) {
        append("array")
        append(values.count)
        for value in values { append(value) }
    }

    mutating func append(_ value: UInt64?) {
        guard let value else { append("optional-uint64-none"); return }
        append("optional-uint64-some")
        append(value)
    }

    mutating func append(_ identity: MirrorRecordIdentity) {
        append(identity.recordType)
        append(identity.recordName)
        append(identity.zoneOwnerName)
        append(identity.zoneName)
    }

    mutating func append(_ value: UInt64) {
        append("uint64")
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int) {
        append("int")
        append(UInt64(bitPattern: Int64(value)))
    }

    mutating func append(_ value: Data) {
        append("data")
        append(value.count)
        data.append(value)
    }

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        var count = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    mutating func append(_ value: Any?) throws {
        guard let value else { append("nil"); return }
        if let value = value as? String { append("string"); append(value); return }
        if let value = value as? Date { append(value); return }
        if let value = value as? Data { append(value); return }
        if let value = value as? CKRecord.Reference { append(value); return }
        if let value = value as? CLLocation {
            append("location")
            append(value.coordinate.latitude.bitPattern)
            append(value.coordinate.longitude.bitPattern)
            append(value.altitude.bitPattern)
            append(value.horizontalAccuracy.bitPattern)
            append(value.verticalAccuracy.bitPattern)
            append(value.course.bitPattern)
            append(value.courseAccuracy.bitPattern)
            append(value.speed.bitPattern)
            append(value.speedAccuracy.bitPattern)
            append(value.timestamp)
            if let source = value.sourceInformation {
                append("location-source")
                append(source.isSimulatedBySoftware ? 1 : 0)
                append(source.isProducedByAccessory ? 1 : 0)
            } else {
                append("no-location-source")
            }
            return
        }
        if let value = value as? CKAsset {
            guard let url = value.fileURL, let bytes = try? Data(contentsOf: url) else {
                throw ShadowMirrorRecordError.missingAsset("canonical-digest")
            }
            append("asset")
            append(ShadowMirrorDigest.sha256(bytes))
            return
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                append("boolean")
                append(value.boolValue ? 1 : 0)
                return
            }
            let objectiveCType = String(cString: value.objCType)
            append("number")
            append(objectiveCType)
            switch objectiveCType {
            case "f": append(UInt64(value.floatValue.bitPattern))
            case "d": append(value.doubleValue.bitPattern)
            case "C", "S", "I", "L", "Q": append(value.uint64Value)
            default: append(UInt64(bitPattern: value.int64Value))
            }
            return
        }
        if let values = value as? [Any] {
            append("list")
            append(values.count)
            for value in values { try append(value) }
            return
        }
        throw ShadowMirrorRecordError.invalidArchive
    }
}
#endif
