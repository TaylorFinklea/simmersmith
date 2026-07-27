#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Foundation

public enum HouseholdZoneRecoveryTransportError: Error, Equatable, Sendable {
    case mismatchedZone
    case partialFailure
    case unreadableAsset
    case invalidAssetDigest
    case invalidCursor
    case missingZoneResult
    case emptyFingerprint
}

public enum HouseholdZoneRecoveryApplyTransportError: Error, Equatable, Sendable {
    case transient
    case partialFailure
    case conflict
    case permissionDenied
    case accountChanged
    case zoneChanged
    case schema
    case invalidResponse
    case permanentFailure
}

public extension HouseholdZoneRecoveryApplyTransportError {
    static func classify(_ error: Error) -> Self {
        if let classified = error as? Self { return classified }
        if let transportError = error as? HouseholdZoneRecoveryTransportError {
            switch transportError {
            case .partialFailure:
                return .partialFailure
            case .mismatchedZone:
                return .zoneChanged
            case .invalidCursor, .missingZoneResult, .unreadableAsset,
                 .invalidAssetDigest, .emptyFingerprint:
                return .permanentFailure
            }
        }
        guard let cloudError = error as? CKError else { return .permanentFailure }
        switch cloudError.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            return .transient
        case .partialFailure, .batchRequestFailed:
            return .partialFailure
        case .serverRecordChanged:
            return .conflict
        case .permissionFailure:
            return .permissionDenied
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return .accountChanged
        case .zoneNotFound, .userDeletedZone:
            return .zoneChanged
        case .badContainer, .badDatabase, .constraintViolation,
             .invalidArguments, .serverRejectedRequest:
            return .schema
        default:
            return .permanentFailure
        }
    }
}

/// Opaque continuation returned by one exact-zone page fetch.
public struct HouseholdZoneRecoveryPageCursor: @unchecked Sendable {
    public let identifier: String
    fileprivate let serverChangeToken: CKServerChangeToken?

    /// Enables recording transports to model pagination without manufacturing CloudKit tokens.
    public init(identifier: String) {
        self.identifier = identifier
        serverChangeToken = nil
    }

    fileprivate init(serverChangeToken: CKServerChangeToken, identifier: String) {
        self.identifier = identifier
        self.serverChangeToken = serverChangeToken
    }
}

public struct HouseholdZoneRecoveryRecordPage: @unchecked Sendable {
    public let zoneID: CKRecordZone.ID
    public let records: [CKRecord]
    public let nextCursor: HouseholdZoneRecoveryPageCursor?
    /// Must be zero. It remains explicit so analyzer fakes cannot accidentally model partial
    /// success as a complete page.
    public let partialFailureCount: Int

    public init(
        zoneID: CKRecordZone.ID,
        records: [CKRecord],
        nextCursor: HouseholdZoneRecoveryPageCursor?,
        partialFailureCount: Int = 0
    ) {
        self.zoneID = zoneID
        self.records = records
        self.nextCursor = nextCursor
        self.partialFailureCount = partialFailureCount
    }
}

public struct HouseholdZoneRecoveryAssetPayload: Equatable, Sendable {
    public let bytes: Data
    public let digest: String

    public init(bytes: Data, digest: String) {
        self.bytes = bytes
        self.digest = digest
    }
}

/// Analyzer-only CloudKit capability. Deliberately contains no modify, save, or delete method.
public protocol HouseholdZoneRecoveryTransport {
    func fetchRecordPage(
        in zoneID: CKRecordZone.ID,
        after cursor: HouseholdZoneRecoveryPageCursor?,
        desiredKeys: [String]?
    ) async throws -> HouseholdZoneRecoveryRecordPage

    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord?
    func assetPayload(for asset: CKAsset) async throws -> HouseholdZoneRecoveryAssetPayload
    func inputFingerprint(for zoneID: CKRecordZone.ID) async throws -> String
}

/// Apply-only capability. The analyzer remains typed to `HouseholdZoneRecoveryTransport`, which
/// intentionally cannot write. A batch has no delete input and must commit all records atomically.
public protocol HouseholdZoneRecoveryApplyTransport: HouseholdZoneRecoveryTransport {
    func saveRecordsAtomically(
        _ records: [CKRecord],
        in zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord]
}

public extension HouseholdZoneRecoveryTransport {
    func inputFingerprint(for zoneID: CKRecordZone.ID) async throws -> String {
        try await HouseholdZoneRecoveryFingerprint.make(transport: self, zoneID: zoneID)
    }
}

/// Production private-database implementation. Read-only callers receive only the analyzer
/// protocol; apply callers must explicitly depend on the separate atomic-save capability.
public struct CloudKitHouseholdZoneRecoveryTransport:
    HouseholdZoneRecoveryTransport,
    HouseholdZoneRecoveryApplyTransport
{
    private let database: CKDatabase

    public init(containerIdentifier: String = "iCloud.app.simmersmith.cloud") {
        database = CKContainer(identifier: containerIdentifier).privateCloudDatabase
    }

    public init(database: CKDatabase) {
        self.database = database
    }

    public func fetchRecordPage(
        in zoneID: CKRecordZone.ID,
        after cursor: HouseholdZoneRecoveryPageCursor?,
        desiredKeys: [String]?
    ) async throws -> HouseholdZoneRecoveryRecordPage {
        if cursor != nil, cursor?.serverChangeToken == nil {
            throw HouseholdZoneRecoveryTransportError.invalidCursor
        }

        return try await withCheckedThrowingContinuation { continuation in
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = cursor?.serverChangeToken
            configuration.desiredKeys = desiredKeys
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: configuration])
            operation.fetchAllChanges = false

            var records: [CKRecord] = []
            var partialFailure = false
            var mismatchedZone = false
            var receivedExpectedZoneResult = false
            var nextCursor: HouseholdZoneRecoveryPageCursor?
            var zoneFailure: Error?

            operation.recordWasChangedBlock = { recordID, result in
                guard recordID.zoneID == zoneID else {
                    mismatchedZone = true
                    return
                }
                switch result {
                case .success(let record):
                    guard record.recordID.zoneID == zoneID else {
                        mismatchedZone = true
                        return
                    }
                    records.append(record)
                case .failure:
                    partialFailure = true
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                guard recordID.zoneID == zoneID else {
                    mismatchedZone = true
                    return
                }
                // Full snapshots model current records. Exact-zone tombstones are complete
                // change-history events, not partial record failures, so they contribute no row.
            }
            operation.recordZoneFetchResultBlock = { fetchedZoneID, result in
                guard fetchedZoneID == zoneID else {
                    mismatchedZone = true
                    return
                }
                receivedExpectedZoneResult = true
                switch result {
                case .success(let zoneResult):
                    if zoneResult.moreComing {
                        let token = zoneResult.serverChangeToken
                        guard let identifier = Self.cursorIdentifier(token) else {
                            partialFailure = true
                            return
                        }
                        nextCursor = HouseholdZoneRecoveryPageCursor(
                            serverChangeToken: token,
                            identifier: identifier)
                    }
                case .failure(let error):
                    zoneFailure = error
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                if mismatchedZone {
                    continuation.resume(throwing: HouseholdZoneRecoveryTransportError.mismatchedZone)
                } else if let zoneFailure {
                    continuation.resume(throwing:
                        HouseholdZoneRecoveryApplyTransportError.classify(zoneFailure))
                } else if partialFailure {
                    continuation.resume(throwing:
                        HouseholdZoneRecoveryApplyTransportError.partialFailure)
                } else if !receivedExpectedZoneResult {
                    continuation.resume(throwing: HouseholdZoneRecoveryTransportError.missingZoneResult)
                } else {
                    switch result {
                    case .success:
                        continuation.resume(returning: HouseholdZoneRecoveryRecordPage(
                            zoneID: zoneID,
                            records: records,
                            nextCursor: nextCursor))
                    case .failure(let error):
                        continuation.resume(throwing:
                            HouseholdZoneRecoveryApplyTransportError.classify(error))
                    }
                }
            }
            database.add(operation)
        }
    }

    public func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord? {
        do {
            let record = try await database.record(for: recordID)
            guard record.recordID == recordID else {
                throw HouseholdZoneRecoveryTransportError.mismatchedZone
            }
            return record
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        catch {
            throw HouseholdZoneRecoveryApplyTransportError.classify(error)
        }
    }

    public func assetPayload(for asset: CKAsset) async throws -> HouseholdZoneRecoveryAssetPayload {
        guard let fileURL = asset.fileURL,
              let bytes = try? Data(contentsOf: fileURL),
              !bytes.isEmpty else {
            throw HouseholdZoneRecoveryTransportError.unreadableAsset
        }
        return HouseholdZoneRecoveryAssetPayload(
            bytes: bytes,
            digest: Self.sha256(bytes))
    }

    public func inputFingerprint(for zoneID: CKRecordZone.ID) async throws -> String {
        try await HouseholdZoneRecoveryFingerprint.make(transport: self, zoneID: zoneID)
    }

    public func saveRecordsAtomically(
        _ records: [CKRecord],
        in zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        guard !records.isEmpty,
              records.allSatisfy({ $0.recordID.zoneID == zoneID }),
              Set(records.map(\.recordID)).count == records.count else {
            throw HouseholdZoneRecoveryApplyTransportError.invalidResponse
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<[CKRecord], Error>) in
            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: nil)
            operation.isAtomic = true
            operation.savePolicy = .ifServerRecordUnchanged

            let expectedIDs = Set(records.map(\.recordID))
            let lock = NSLock()
            var savedRecords: [CKRecord.ID: CKRecord] = [:]
            var observedRecordFailure = false
            operation.perRecordSaveBlock = { recordID, result in
                lock.withLock {
                    switch result {
                    case .success(let savedRecord):
                        guard savedRecord.recordID == recordID,
                              savedRecord.recordID.zoneID == zoneID else {
                            observedRecordFailure = true
                            return
                        }
                        savedRecords[recordID] = savedRecord
                    case .failure:
                        observedRecordFailure = true
                    }
                }
            }
            operation.modifyRecordsResultBlock = { result in
                let observation = lock.withLock {
                    (savedRecords, observedRecordFailure)
                }
                switch result {
                case .success:
                    guard !observation.1, Set(observation.0.keys) == expectedIDs else {
                        continuation.resume(
                            throwing: HouseholdZoneRecoveryApplyTransportError.partialFailure)
                        return
                    }
                    continuation.resume(returning: records.compactMap {
                        observation.0[$0.recordID]
                    })
                case .failure(let error):
                    continuation.resume(throwing:
                        HouseholdZoneRecoveryApplyTransportError.classify(error))
                }
            }
            database.add(operation)
        }
    }


    private static func cursorIdentifier(_ token: CKServerChangeToken) -> String? {
        guard let bytes = try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true) else {
            return nil
        }
        return sha256(bytes)
    }


    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

private enum HouseholdZoneRecoveryFingerprint {
    static func make(
        transport: any HouseholdZoneRecoveryTransport,
        zoneID: CKRecordZone.ID
    ) async throws -> String {
        var cursor: HouseholdZoneRecoveryPageCursor?
        var observedCursorIDs = Set<String>()
        var snapshots: [FingerprintRecord] = []

        repeat {
            let page = try await transport.fetchRecordPage(
                in: zoneID,
                after: cursor,
                desiredKeys: [])
            guard page.zoneID == zoneID,
                  page.records.allSatisfy({ $0.recordID.zoneID == zoneID }) else {
                throw HouseholdZoneRecoveryTransportError.mismatchedZone
            }
            guard page.partialFailureCount == 0 else {
                throw HouseholdZoneRecoveryTransportError.partialFailure
            }
            snapshots.append(contentsOf: page.records.map(FingerprintRecord.init))
            cursor = page.nextCursor
            if let cursor, !observedCursorIDs.insert(cursor.identifier).inserted {
                throw HouseholdZoneRecoveryTransportError.partialFailure
            }
        } while cursor != nil

        guard Set(snapshots.map(\.recordName)).count == snapshots.count,
              snapshots.allSatisfy({ !($0.changeTag ?? "").isEmpty }) else {
            throw HouseholdZoneRecoveryTransportError.partialFailure
        }

        snapshots.sort { $0.sortKey < $1.sortKey }
        var bytes = Data("household-zone-recovery-input-v1".utf8)
        append(zoneID.ownerName, to: &bytes)
        append(zoneID.zoneName, to: &bytes)
        append(String(snapshots.count), to: &bytes)
        for snapshot in snapshots {
            append(snapshot.recordType, to: &bytes)
            append(snapshot.recordName, to: &bytes)
            append(snapshot.changeTag!, to: &bytes)
        }
        let fingerprint = sha256(bytes)
        guard !fingerprint.isEmpty else {
            throw HouseholdZoneRecoveryTransportError.emptyFingerprint
        }
        return fingerprint
    }

    private static func append(_ value: String, to data: inout Data) {
        var count = UInt64(value.utf8.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(contentsOf: value.utf8)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct FingerprintRecord {
        let recordType: String
        let recordName: String
        let changeTag: String?

        init(_ record: CKRecord) {
            recordType = record.recordType
            recordName = record.recordID.recordName
            changeTag = record.recordChangeTag
        }

        var sortKey: (String, String) { (recordType, recordName) }
    }
}
#endif
