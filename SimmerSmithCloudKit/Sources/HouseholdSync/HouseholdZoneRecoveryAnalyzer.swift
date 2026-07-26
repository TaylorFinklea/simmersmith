#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdRecords

public enum HouseholdZoneRecoveryAnalyzerError: Error, Equatable, Sendable {
    case invalidScope
    case mismatchedZone
    case partialPageFailure
    case duplicateRecord
    case repeatedCursor
    case invalidFingerprint
    case inputChanged
    case invalidAssetDigest
    case invalidDecisionInput
    case unsupportedApplicationValue
    case incompleteClassification
}

public struct HouseholdZoneRecoveryPreviewSummary: Equatable, Sendable {
    public let candidateCount: Int
    public let copyCount: Int
    public let skipIdenticalCount: Int
    public let conflictCount: Int
    public let excludedCount: Int
    public let unresolvedCount: Int
    public let blockedCount: Int
    public let assetCount: Int

    public init(
        candidateCount: Int,
        copyCount: Int,
        skipIdenticalCount: Int,
        conflictCount: Int,
        excludedCount: Int,
        unresolvedCount: Int,
        blockedCount: Int,
        assetCount: Int
    ) {
        self.candidateCount = candidateCount
        self.copyCount = copyCount
        self.skipIdenticalCount = skipIdenticalCount
        self.conflictCount = conflictCount
        self.excludedCount = excludedCount
        self.unresolvedCount = unresolvedCount
        self.blockedCount = blockedCount
        self.assetCount = assetCount
    }

    /// Safe for logs: contains counts and fixed labels only, never record fields or identities.
    public var diagnosticDescription: String {
        "candidates=\(candidateCount) copy=\(copyCount) identical=\(skipIdenticalCount) "
            + "conflicts=\(conflictCount) excluded=\(excludedCount) "
            + "unresolved=\(unresolvedCount) blocked=\(blockedCount) assets=\(assetCount)"
    }
}

public struct HouseholdZoneRecoveryAnalysis: Equatable, Sendable {
    public let manifest: HouseholdZoneRecoveryManifest
    public let summary: HouseholdZoneRecoveryPreviewSummary

    public init(
        manifest: HouseholdZoneRecoveryManifest,
        summary: HouseholdZoneRecoveryPreviewSummary
    ) {
        self.manifest = manifest
        self.summary = summary
    }
}

/// Builds a recovery preview exclusively through the analyzer-facing read capability.
public struct HouseholdZoneRecoveryAnalyzer {
    private let transport: any HouseholdZoneRecoveryTransport

    public init(transport: any HouseholdZoneRecoveryTransport) {
        self.transport = transport
    }

    public func analyze(
        accountFingerprint: String,
        sourceScope: MirrorScope,
        targetScope: MirrorScope,
        provenanceDecisions: [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryProvenanceDecision] = [:],
        conflictDecisions: [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryDecision] = [:]
    ) async throws -> HouseholdZoneRecoveryAnalysis {
        try Self.validateScope(
            accountFingerprint: accountFingerprint,
            sourceScope: sourceScope,
            targetScope: targetScope)
        let sourceZoneID = Self.zoneID(for: sourceScope)
        let targetZoneID = Self.zoneID(for: targetScope)

        let sourceFingerprint = try await checkedFingerprint(for: sourceZoneID)
        let targetFingerprint = try await checkedFingerprint(for: targetZoneID)
        let sourceRecords = try await fetchAllRecords(in: sourceZoneID)
        let targetRecords = try await fetchAllRecords(in: targetZoneID)
        let targetRecordsByID = Dictionary(uniqueKeysWithValues: targetRecords.map {
            ($0.recordID, $0)
        })
        let classification = HouseholdZoneRecoveryClassifier(
            sourceScope: sourceScope,
            targetScope: targetScope).classify(sourceRecords)
        guard classification.accountedRecordCount == classification.inputRecordCount else {
            throw HouseholdZoneRecoveryAnalyzerError.incompleteClassification
        }

        let candidateIdentities = Set(classification.eligibleIdentities)
        guard Set(provenanceDecisions.keys).isSubset(of: candidateIdentities),
              Set(conflictDecisions.keys).isSubset(of: candidateIdentities) else {
            throw HouseholdZoneRecoveryAnalyzerError.invalidDecisionInput
        }

        let dependenciesByIdentity = Dictionary(grouping: classification.dependencyEdges, by: \.dependent)
            .mapValues { edges in
                Array(Set(edges.map {
                    HouseholdZoneRecoveryDependency(
                        identity: $0.dependency,
                        requirement: $0.requirement)
                }))
            }
        let classifierUnresolved = Set(classification.provenanceCandidates.map(\.identity))
        var entries: [HouseholdZoneRecoveryEntry] = []
        var unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry] = []
        var actionCounts: [HouseholdZoneRecoveryAction: Int] = [:]
        var assetCount = 0

        let recordsAndIdentities = zip(
            classification.eligibleRecords,
            classification.eligibleIdentities).sorted {
                $0.1.source.sortKey < $1.1.source.sortKey
            }
        for (sourceRecord, identity) in recordsAndIdentities {
            guard sourceRecord.recordID.zoneID == sourceZoneID else {
                throw HouseholdZoneRecoveryAnalyzerError.mismatchedZone
            }
            let sourceAssetDigests = try await assetDigests(in: sourceRecord)
            assetCount += sourceAssetDigests.count

            let targetRecordID = CKRecord.ID(
                recordName: identity.target.recordName,
                zoneID: targetZoneID)
            let targetRecord = targetRecordsByID[targetRecordID]

            let action: HouseholdZoneRecoveryAction
            if let targetRecord {
                if targetRecord.recordType != sourceRecord.recordType {
                    action = .conflict
                } else {
                    let targetAssetDigests = try await assetDigests(in: targetRecord)
                    let keys = HouseholdSyncEngine.fieldKeys(
                        source: sourceRecord,
                        destination: targetRecord).sorted()
                    let expectedDigest = try canonicalApplicationDigest(
                        record: sourceRecord,
                        keys: keys,
                        assetDigests: sourceAssetDigests,
                        recordZoneID: sourceZoneID,
                        projectedZoneID: targetZoneID)
                    let targetDigest = try canonicalApplicationDigest(
                        record: targetRecord,
                        keys: keys,
                        assetDigests: targetAssetDigests,
                        recordZoneID: targetZoneID,
                        projectedZoneID: targetZoneID)
                    action = expectedDigest == targetDigest ? .skipIdentical : .conflict
                }
            } else {
                action = .copy
            }
            actionCounts[action, default: 0] += 1

            let collisionDecision = conflictDecisions[identity]
            guard action == .conflict || collisionDecision == nil else {
                throw HouseholdZoneRecoveryAnalyzerError.invalidDecisionInput
            }
            let entry = HouseholdZoneRecoveryEntry(
                identity: identity,
                action: action,
                decision: collisionDecision,
                dependencies: dependenciesByIdentity[identity] ?? [],
                assetDigests: sourceAssetDigests)
            if classifierUnresolved.contains(identity) {
                unresolvedEntries.append(HouseholdZoneRecoveryUnresolvedEntry(
                    entry: entry,
                    decision: provenanceDecisions[identity]))
            } else {
                guard provenanceDecisions[identity] == nil else {
                    throw HouseholdZoneRecoveryAnalyzerError.invalidDecisionInput
                }
                entries.append(entry)
            }
        }

        let finalSourceFingerprint = try await checkedFingerprint(for: sourceZoneID)
        let finalTargetFingerprint = try await checkedFingerprint(for: targetZoneID)
        guard sourceFingerprint == finalSourceFingerprint,
              targetFingerprint == finalTargetFingerprint else {
            throw HouseholdZoneRecoveryAnalyzerError.inputChanged
        }

        let manifest = try HouseholdZoneRecoveryManifest(
            accountFingerprint: accountFingerprint,
            sourceScope: sourceScope,
            targetScope: targetScope,
            sourceInputFingerprint: sourceFingerprint,
            targetInputFingerprint: targetFingerprint,
            entries: entries,
            exclusions: classification.exclusions,
            unresolvedEntries: unresolvedEntries,
            blockedEntries: classification.blockedEntries)
        let summary = HouseholdZoneRecoveryPreviewSummary(
            candidateCount: classification.eligibleRecords.count + classification.blockedRecordCount,
            copyCount: actionCounts[.copy, default: 0],
            skipIdenticalCount: actionCounts[.skipIdentical, default: 0],
            conflictCount: actionCounts[.conflict, default: 0],
            excludedCount: classification.exclusions.reduce(0) { $0 + $1.count },
            unresolvedCount: unresolvedEntries.filter { $0.decision == nil }.count,
            blockedCount: classification.blockedRecordCount,
            assetCount: assetCount)
        return HouseholdZoneRecoveryAnalysis(manifest: manifest, summary: summary)
    }

    private func fetchAllRecords(in zoneID: CKRecordZone.ID) async throws -> [CKRecord] {
        var records: [CKRecord] = []
        var cursor: HouseholdZoneRecoveryPageCursor?
        var observedCursorIDs = Set<String>()
        var observedRecordIDs = Set<CKRecord.ID>()

        repeat {
            let page = try await transport.fetchRecordPage(
                in: zoneID,
                after: cursor,
                desiredKeys: nil)
            guard page.zoneID == zoneID,
                  page.records.allSatisfy({ $0.recordID.zoneID == zoneID }) else {
                throw HouseholdZoneRecoveryAnalyzerError.mismatchedZone
            }
            guard page.partialFailureCount == 0 else {
                throw HouseholdZoneRecoveryAnalyzerError.partialPageFailure
            }
            for record in page.records {
                guard observedRecordIDs.insert(record.recordID).inserted else {
                    throw HouseholdZoneRecoveryAnalyzerError.duplicateRecord
                }
                records.append(record)
            }
            cursor = page.nextCursor
            if let cursor, !observedCursorIDs.insert(cursor.identifier).inserted {
                throw HouseholdZoneRecoveryAnalyzerError.repeatedCursor
            }
        } while cursor != nil
        return records
    }

    private func checkedFingerprint(for zoneID: CKRecordZone.ID) async throws -> String {
        let fingerprint = try await transport.inputFingerprint(for: zoneID)
        guard !fingerprint.isEmpty else {
            throw HouseholdZoneRecoveryAnalyzerError.invalidFingerprint
        }
        return fingerprint
    }

    private func assetDigests(in record: CKRecord) async throws -> [String: String] {
        var result: [String: String] = [:]
        for key in record.allKeys().sorted() {
            guard let asset = record[key] as? CKAsset else { continue }
            let payload = try await transport.assetPayload(for: asset)
            guard !payload.bytes.isEmpty,
                  payload.digest == ShadowMirrorDigest.sha256(payload.bytes) else {
                throw HouseholdZoneRecoveryAnalyzerError.invalidAssetDigest
            }
            result[key] = payload.digest
        }
        return result
    }

    private func canonicalApplicationDigest(
        record: CKRecord,
        keys: [String],
        assetDigests: [String: String],
        recordZoneID: CKRecordZone.ID,
        projectedZoneID: CKRecordZone.ID
    ) throws -> String {
        var writer = CanonicalWriter()
        writer.append("household-zone-recovery-application-record-v1")
        writer.append(record.recordType)
        writer.append(record.recordID.recordName)
        writer.append(keys.count)
        for key in keys {
            writer.append(key)
            if record[key] is CKAsset {
                guard let digest = assetDigests[key] else {
                    throw HouseholdZoneRecoveryAnalyzerError.invalidAssetDigest
                }
                writer.append("asset")
                writer.append(digest)
            } else {
                let normalized = try normalizedApplicationValue(
                    record[key],
                    recordZoneID: recordZoneID,
                    projectedZoneID: projectedZoneID)
                do {
                    try writer.append(normalized)
                } catch {
                    throw HouseholdZoneRecoveryAnalyzerError.unsupportedApplicationValue
                }
            }
        }
        return ShadowMirrorDigest.sha256(writer.data)
    }

    private func normalizedApplicationValue(
        _ value: Any?,
        recordZoneID: CKRecordZone.ID,
        projectedZoneID: CKRecordZone.ID
    ) throws -> Any? {
        guard let value else { return nil }
        if let reference = value as? CKRecord.Reference {
            guard reference.recordID.zoneID == recordZoneID else {
                throw HouseholdZoneRecoveryAnalyzerError.mismatchedZone
            }
            return CKRecord.Reference(
                recordID: CKRecord.ID(
                    recordName: reference.recordID.recordName,
                    zoneID: projectedZoneID),
                action: reference.action)
        }
        if let values = value as? [Any] {
            return try values.map {
                if $0 is CKAsset {
                    throw HouseholdZoneRecoveryAnalyzerError.unsupportedApplicationValue
                }
                return try normalizedApplicationValue(
                    $0,
                    recordZoneID: recordZoneID,
                    projectedZoneID: projectedZoneID) as Any
            }
        }
        return value
    }

    private static func validateScope(
        accountFingerprint: String,
        sourceScope: MirrorScope,
        targetScope: MirrorScope
    ) throws {
        do {
            try sourceScope.validate()
            try targetScope.validate()
        } catch {
            throw HouseholdZoneRecoveryAnalyzerError.invalidScope
        }
        guard !accountFingerprint.isEmpty,
              sourceScope.accountRecordName == targetScope.accountRecordName,
              sourceScope.role == .owner,
              targetScope.role == .owner,
              sourceScope.databaseScope == .private,
              targetScope.databaseScope == .private,
              sourceScope.zoneOwnerName == CKCurrentUserDefaultName,
              targetScope.zoneOwnerName == CKCurrentUserDefaultName,
              sourceScope.zoneName == HouseholdZoneRecoveryManifest.reservedSourceZoneName,
              (sourceScope.zoneOwnerName, sourceScope.zoneName)
                != (targetScope.zoneOwnerName, targetScope.zoneName) else {
            throw HouseholdZoneRecoveryAnalyzerError.invalidScope
        }
    }

    private static func zoneID(for scope: MirrorScope) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: scope.zoneName, ownerName: scope.zoneOwnerName)
    }
}
#endif
