#if canImport(CloudKit)
import CloudKit
import Foundation

public struct HouseholdZoneRecoveryIdentity: Codable, Equatable, Hashable, Sendable {
    public let source: MirrorRecordIdentity
    public let target: MirrorRecordIdentity

    public init(source: MirrorRecordIdentity, target: MirrorRecordIdentity) {
        self.source = source
        self.target = target
    }

    public init(source: MirrorRecordIdentity, targetScope: MirrorScope) {
        self.init(
            source: source,
            target: MirrorRecordIdentity(
                recordType: source.recordType,
                recordName: source.recordName,
                zoneOwnerName: targetScope.zoneOwnerName,
                zoneName: targetScope.zoneName))
    }

    fileprivate var sortKey: (String, String, String, String) {
        (source.recordType, source.zoneOwnerName, source.zoneName, source.recordName)
    }

    fileprivate var sourceRecordKey: (String, String, String) {
        (source.zoneOwnerName, source.zoneName, source.recordName)
    }

    fileprivate var targetRecordKey: (String, String, String) {
        (target.zoneOwnerName, target.zoneName, target.recordName)
    }
}

public enum HouseholdZoneRecoveryAction: String, Codable, Equatable, Sendable {
    case copy
    case skipIdentical = "skip-identical"
    case conflict
}

public enum HouseholdZoneRecoveryDecision: String, Codable, Equatable, Sendable {
    case source
    case target
}

public enum HouseholdZoneRecoveryDependencyRequirement:
    String, Codable, Equatable, Hashable, Sendable
{
    case required
    case optional
}

public struct HouseholdZoneRecoveryDependency: Codable, Equatable, Hashable, Sendable {
    public let identity: HouseholdZoneRecoveryIdentity
    public let requirement: HouseholdZoneRecoveryDependencyRequirement

    public init(
        identity: HouseholdZoneRecoveryIdentity,
        requirement: HouseholdZoneRecoveryDependencyRequirement
    ) {
        self.identity = identity
        self.requirement = requirement
    }

    fileprivate var sortKey: (String, String, String, String, String) {
        let identityKey = identity.sortKey
        return (
            identityKey.0,
            identityKey.1,
            identityKey.2,
            identityKey.3,
            requirement.rawValue)
    }
}

public struct HouseholdZoneRecoveryEntry: Codable, Equatable, Sendable {
    public let identity: HouseholdZoneRecoveryIdentity
    public let action: HouseholdZoneRecoveryAction
    public let decision: HouseholdZoneRecoveryDecision?
    public let dependencies: [HouseholdZoneRecoveryDependency]
    public let assetDigests: [String: String]

    public init(
        identity: HouseholdZoneRecoveryIdentity,
        action: HouseholdZoneRecoveryAction,
        decision: HouseholdZoneRecoveryDecision? = nil,
        dependencies: [HouseholdZoneRecoveryDependency] = [],
        assetDigests: [String: String] = [:]
    ) {
        self.identity = identity
        self.action = action
        self.decision = decision
        self.dependencies = dependencies.sorted { $0.sortKey < $1.sortKey }
        self.assetDigests = assetDigests
    }
}

public struct HouseholdZoneRecoveryExclusion: Codable, Equatable, Sendable {
    public let reason: String
    public let count: Int

    public init(reason: String, count: Int) {
        self.reason = reason
        self.count = count
    }
}

public enum HouseholdZoneRecoveryProvenanceDecision: String, Codable, Equatable, Sendable {
    case include
    case exclude
}

public struct HouseholdZoneRecoveryUnresolvedEntry: Codable, Equatable, Sendable {
    public let entry: HouseholdZoneRecoveryEntry
    public let decision: HouseholdZoneRecoveryProvenanceDecision?

    public var identity: HouseholdZoneRecoveryIdentity { entry.identity }

    public init(
        entry: HouseholdZoneRecoveryEntry,
        decision: HouseholdZoneRecoveryProvenanceDecision? = nil
    ) {
        self.entry = entry
        self.decision = decision
    }
}

public struct HouseholdZoneRecoveryBlockedEntry: Codable, Equatable, Sendable {
    public static let missingDependencyReason = "missing-dependency"

    public let identity: HouseholdZoneRecoveryIdentity
    public let reason: String
    public let missingDependencies: [HouseholdZoneRecoveryIdentity]

    public init(
        identity: HouseholdZoneRecoveryIdentity,
        reason: String,
        missingDependencies: [HouseholdZoneRecoveryIdentity] = []
    ) {
        self.identity = identity
        self.reason = reason
        self.missingDependencies = missingDependencies.sorted { $0.sortKey < $1.sortKey }
    }
}

public struct HouseholdZoneRecoveryTotal: Codable, Equatable, Sendable {
    public let recordType: String
    public let action: HouseholdZoneRecoveryAction
    public let count: Int

    public init(recordType: String, action: HouseholdZoneRecoveryAction, count: Int) {
        self.recordType = recordType
        self.action = action
        self.count = count
    }
}

public struct HouseholdZoneRecoveryApproval: Codable, Equatable, Sendable {
    public let manifestDigest: String

    public init(manifestDigest: String) {
        self.manifestDigest = manifestDigest
    }
}

public enum HouseholdZoneRecoveryPlanError: Error, Equatable, Sendable {
    case invalidScope
    case sourceEqualsTarget
    case crossZoneIdentity
    case invalidIdentity
    case duplicateIdentity
    case unresolvedConflict
    case invalidDecision
    case unresolvedProvenance
    case blockedEntriesPresent
    case unstableOrdering
    case invalidInput
    case invalidTotals
    case approvalMismatch
}

public struct HouseholdZoneRecoveryManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let reservedSourceZoneName = "household-spc-recipe-test"

    public let formatVersion: Int
    public let accountFingerprint: String
    public let sourceScope: MirrorScope
    public let targetScope: MirrorScope
    public let sourceInputFingerprint: String
    public let targetInputFingerprint: String
    public let entries: [HouseholdZoneRecoveryEntry]
    public let exclusions: [HouseholdZoneRecoveryExclusion]
    public let unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry]
    public let blockedEntries: [HouseholdZoneRecoveryBlockedEntry]
    public let totals: [HouseholdZoneRecoveryTotal]

    public var approvedEntries: [HouseholdZoneRecoveryEntry] {
        (entries + unresolvedEntries.compactMap {
            $0.decision == .include ? $0.entry : nil
        }).sorted { $0.identity.sortKey < $1.identity.sortKey }
    }

    public init(
        accountFingerprint: String,
        sourceScope: MirrorScope,
        targetScope: MirrorScope,
        sourceInputFingerprint: String,
        targetInputFingerprint: String,
        entries: [HouseholdZoneRecoveryEntry],
        exclusions: [HouseholdZoneRecoveryExclusion],
        unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry] = [],
        blockedEntries: [HouseholdZoneRecoveryBlockedEntry] = [],
        formatVersion: Int = HouseholdZoneRecoveryManifest.currentFormatVersion
    ) throws {
        guard formatVersion == Self.currentFormatVersion,
              !accountFingerprint.isEmpty,
              !sourceInputFingerprint.isEmpty,
              !targetInputFingerprint.isEmpty else {
            throw HouseholdZoneRecoveryPlanError.invalidInput
        }
        try Self.validateScopes(source: sourceScope, target: targetScope)

        let candidateEntries = entries
            .map {
                HouseholdZoneRecoveryEntry(
                    identity: $0.identity,
                    action: $0.action,
                    decision: $0.decision,
                    dependencies: $0.dependencies,
                    assetDigests: $0.assetDigests)
            }
            .sorted { $0.identity.sortKey < $1.identity.sortKey }
        let candidateIdentities = try Self.validateEntries(
            candidateEntries,
            sourceScope: sourceScope,
            targetScope: targetScope)
        let canonicalExclusions = exclusions.sorted {
            ($0.reason, $0.count) < ($1.reason, $1.count)
        }
        try Self.validateExclusions(canonicalExclusions)
        let canonicalUnresolved = unresolvedEntries.sorted {
            $0.identity.sortKey < $1.identity.sortKey
        }
        try Self.validateUnresolved(
            canonicalUnresolved,
            sourceScope: sourceScope,
            targetScope: targetScope)
        try Self.validateDisjointBuckets(
            entries: candidateEntries,
            unresolved: canonicalUnresolved,
            blocked: blockedEntries)
        let partition = try Self.partitionBlockedEntries(
            blockedEntries,
            from: candidateEntries,
            unresolved: canonicalUnresolved,
            candidateIdentities: candidateIdentities,
            sourceScope: sourceScope,
            targetScope: targetScope)
        let canonicalTotals = Self.makeTotals(
            for: partition.entries + partition.unresolved.compactMap {
                $0.decision == .include ? $0.entry : nil
            })

        self.formatVersion = formatVersion
        self.accountFingerprint = accountFingerprint
        self.sourceScope = sourceScope
        self.targetScope = targetScope
        self.sourceInputFingerprint = sourceInputFingerprint
        self.targetInputFingerprint = targetInputFingerprint
        self.entries = partition.entries
        self.exclusions = canonicalExclusions
        self.unresolvedEntries = partition.unresolved
        self.blockedEntries = partition.blocked
        self.totals = canonicalTotals
    }

    public func canonicalJSONBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public func digest() throws -> String {
        ShadowMirrorCanonicalDigest.recoveryManifest(self)
    }

    public func verify(_ approval: HouseholdZoneRecoveryApproval) throws {
        guard approval.manifestDigest == (try digest()) else {
            throw HouseholdZoneRecoveryPlanError.approvalMismatch
        }
        guard unresolvedEntries.allSatisfy({ $0.decision != nil }) else {
            throw HouseholdZoneRecoveryPlanError.unresolvedProvenance
        }
        guard unresolvedEntries.allSatisfy({
            $0.decision != .include || $0.entry.action != .conflict || $0.entry.decision != nil
        }) else {
            throw HouseholdZoneRecoveryPlanError.unresolvedConflict
        }
        guard blockedEntries.isEmpty else {
            throw HouseholdZoneRecoveryPlanError.blockedEntriesPresent
        }
        let approvedIdentities = Set(approvedEntries.map(\.identity))
        guard approvedEntries.allSatisfy({
            $0.dependencies
                .filter { $0.requirement == .required }
                .allSatisfy { approvedIdentities.contains($0.identity) }
        }) else {
            throw HouseholdZoneRecoveryPlanError.blockedEntriesPresent
        }
    }

    public init(from decoder: Decoder) throws {
        let payload = try CanonicalPayload(from: decoder)
        let decoded = try Self(
            accountFingerprint: payload.accountFingerprint,
            sourceScope: payload.sourceScope,
            targetScope: payload.targetScope,
            sourceInputFingerprint: payload.sourceInputFingerprint,
            targetInputFingerprint: payload.targetInputFingerprint,
            entries: payload.entries,
            exclusions: payload.exclusions,
            unresolvedEntries: payload.unresolvedEntries,
            blockedEntries: payload.blockedEntries,
            formatVersion: payload.formatVersion)
        guard decoded.totals == payload.totals else {
            throw HouseholdZoneRecoveryPlanError.invalidTotals
        }
        self = decoded
    }

    private static func validateScopes(source: MirrorScope, target: MirrorScope) throws {
        do {
            try source.validate()
            try target.validate()
        } catch {
            throw HouseholdZoneRecoveryPlanError.invalidScope
        }
        guard source.role == .owner,
              source.databaseScope == .private,
              target.role == .owner,
              target.databaseScope == .private,
              source.zoneOwnerName == CKCurrentUserDefaultName,
              target.zoneOwnerName == CKCurrentUserDefaultName,
              source.zoneName == reservedSourceZoneName,
              source.accountRecordName == target.accountRecordName else {
            throw HouseholdZoneRecoveryPlanError.invalidScope
        }
        guard (source.zoneOwnerName, source.zoneName) != (target.zoneOwnerName, target.zoneName) else {
            throw HouseholdZoneRecoveryPlanError.sourceEqualsTarget
        }
    }

    private static func validateEntries(
        _ entries: [HouseholdZoneRecoveryEntry],
        sourceScope: MirrorScope,
        targetScope: MirrorScope,
        allowUnresolvedConflicts: Bool = false
    ) throws -> Set<HouseholdZoneRecoveryIdentity> {
        var sourceRecordKeys = Set<RecordKey>()
        var targetRecordKeys = Set<RecordKey>()
        var identities = Set<HouseholdZoneRecoveryIdentity>()

        for entry in entries {
            try validateIdentity(
                entry.identity,
                sourceScope: sourceScope,
                targetScope: targetScope)
            guard sourceRecordKeys.insert(RecordKey(entry.identity.source)).inserted,
                  targetRecordKeys.insert(RecordKey(entry.identity.target)).inserted,
                  identities.insert(entry.identity).inserted else {
                throw HouseholdZoneRecoveryPlanError.duplicateIdentity
            }
            if entry.action == .conflict {
                guard entry.decision != nil || allowUnresolvedConflicts else {
                    throw HouseholdZoneRecoveryPlanError.unresolvedConflict
                }
            } else if entry.decision != nil {
                throw HouseholdZoneRecoveryPlanError.invalidDecision
            }
            guard Set(entry.dependencies.map(\.identity)).count == entry.dependencies.count else {
                throw HouseholdZoneRecoveryPlanError.unstableOrdering
            }
            for dependency in entry.dependencies {
                try validateIdentity(
                    dependency.identity,
                    sourceScope: sourceScope,
                    targetScope: targetScope)
            }
            guard entry.assetDigests.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
                throw HouseholdZoneRecoveryPlanError.invalidInput
            }
        }
        return identities
    }

    private static func validateExclusions(_ exclusions: [HouseholdZoneRecoveryExclusion]) throws {
        guard exclusions.allSatisfy({ !$0.reason.isEmpty && $0.count >= 0 }) else {
            throw HouseholdZoneRecoveryPlanError.invalidInput
        }
        guard Set(exclusions.map(\.reason)).count == exclusions.count else {
            throw HouseholdZoneRecoveryPlanError.unstableOrdering
        }
    }

    private static func validateUnresolved(
        _ unresolved: [HouseholdZoneRecoveryUnresolvedEntry],
        sourceScope: MirrorScope,
        targetScope: MirrorScope
    ) throws {
        _ = try validateEntries(
            unresolved.map(\.entry),
            sourceScope: sourceScope,
            targetScope: targetScope,
            allowUnresolvedConflicts: true)
    }

    private static func validateDisjointBuckets(
        entries: [HouseholdZoneRecoveryEntry],
        unresolved: [HouseholdZoneRecoveryUnresolvedEntry],
        blocked: [HouseholdZoneRecoveryBlockedEntry]
    ) throws {
        var recordKeys = Set<RecordKey>()
        for entry in entries {
            guard recordKeys.insert(RecordKey(entry.identity.source)).inserted else {
                throw HouseholdZoneRecoveryPlanError.duplicateIdentity
            }
        }
        for entry in unresolved {
            guard recordKeys.insert(RecordKey(entry.identity.source)).inserted else {
                throw HouseholdZoneRecoveryPlanError.duplicateIdentity
            }
        }
        for entry in blocked {
            guard recordKeys.insert(RecordKey(entry.identity.source)).inserted else {
                throw HouseholdZoneRecoveryPlanError.duplicateIdentity
            }
        }
    }

    private static func partitionBlockedEntries(
        _ supplied: [HouseholdZoneRecoveryBlockedEntry],
        from entries: [HouseholdZoneRecoveryEntry],
        unresolved: [HouseholdZoneRecoveryUnresolvedEntry],
        candidateIdentities: Set<HouseholdZoneRecoveryIdentity>,
        sourceScope: MirrorScope,
        targetScope: MirrorScope
    ) throws -> RecoveryPartition {
        let allCandidateIdentities = candidateIdentities.union(unresolved.map(\.identity))
        var blockedByIdentity: [HouseholdZoneRecoveryIdentity: HouseholdZoneRecoveryBlockedEntry] = [:]
        for blocked in supplied {
            try validateIdentity(
                blocked.identity,
                sourceScope: sourceScope,
                targetScope: targetScope)
            guard !blocked.reason.isEmpty else {
                throw HouseholdZoneRecoveryPlanError.invalidInput
            }
            guard blockedByIdentity[blocked.identity] == nil,
                  Set(blocked.missingDependencies).count == blocked.missingDependencies.count else {
                throw HouseholdZoneRecoveryPlanError.unstableOrdering
            }
            for dependency in blocked.missingDependencies {
                try validateIdentity(
                    dependency,
                    sourceScope: sourceScope,
                    targetScope: targetScope)
                guard !allCandidateIdentities.contains(dependency) else {
                    throw HouseholdZoneRecoveryPlanError.invalidInput
                }
            }
            blockedByIdentity[blocked.identity] = HouseholdZoneRecoveryBlockedEntry(
                identity: blocked.identity,
                reason: blocked.reason,
                missingDependencies: blocked.missingDependencies)
        }

        var activeIdentities = allCandidateIdentities
        var removedAnEntry = true
        while removedAnEntry {
            removedAnEntry = false
            for entry in entries where activeIdentities.contains(entry.identity) {
                let missing = entry.dependencies.compactMap {
                    $0.requirement == .required && !activeIdentities.contains($0.identity)
                        ? $0.identity
                        : nil
                }
                guard !missing.isEmpty else { continue }
                blockedByIdentity[entry.identity] = HouseholdZoneRecoveryBlockedEntry(
                    identity: entry.identity,
                    reason: HouseholdZoneRecoveryBlockedEntry.missingDependencyReason,
                    missingDependencies: missing)
                activeIdentities.remove(entry.identity)
                removedAnEntry = true
            }
            for unresolvedEntry in unresolved
            where activeIdentities.contains(unresolvedEntry.identity) {
                let missing = unresolvedEntry.entry.dependencies.compactMap {
                    $0.requirement == .required && !activeIdentities.contains($0.identity)
                        ? $0.identity
                        : nil
                }
                guard !missing.isEmpty else { continue }
                blockedByIdentity[unresolvedEntry.identity] = HouseholdZoneRecoveryBlockedEntry(
                    identity: unresolvedEntry.identity,
                    reason: HouseholdZoneRecoveryBlockedEntry.missingDependencyReason,
                    missingDependencies: missing)
                activeIdentities.remove(unresolvedEntry.identity)
                removedAnEntry = true
            }
        }

        return RecoveryPartition(
            entries: entries.filter { activeIdentities.contains($0.identity) },
            unresolved: unresolved.filter { activeIdentities.contains($0.identity) },
            blocked: blockedByIdentity.values.sorted { $0.identity.sortKey < $1.identity.sortKey })
    }

    private static func validateIdentity(
        _ identity: HouseholdZoneRecoveryIdentity,
        sourceScope: MirrorScope,
        targetScope: MirrorScope
    ) throws {
        guard identity.source.zoneOwnerName == sourceScope.zoneOwnerName,
              identity.source.zoneName == sourceScope.zoneName,
              identity.target.zoneOwnerName == targetScope.zoneOwnerName,
              identity.target.zoneName == targetScope.zoneName else {
            throw HouseholdZoneRecoveryPlanError.crossZoneIdentity
        }
        guard !identity.source.recordType.isEmpty,
              !identity.source.recordName.isEmpty,
              identity.source.recordType == identity.target.recordType,
              identity.source.recordName == identity.target.recordName else {
            throw HouseholdZoneRecoveryPlanError.invalidIdentity
        }
    }

    private static func makeTotals(
        for entries: [HouseholdZoneRecoveryEntry]
    ) -> [HouseholdZoneRecoveryTotal] {
        var counts: [TotalKey: Int] = [:]
        for entry in entries {
            counts[TotalKey(recordType: entry.identity.source.recordType, action: entry.action), default: 0] += 1
        }
        return counts.map {
            HouseholdZoneRecoveryTotal(recordType: $0.key.recordType, action: $0.key.action, count: $0.value)
        }.sorted {
            ($0.recordType, $0.action.rawValue) < ($1.recordType, $1.action.rawValue)
        }
    }

    private struct RecoveryPartition {
        let entries: [HouseholdZoneRecoveryEntry]
        let unresolved: [HouseholdZoneRecoveryUnresolvedEntry]
        let blocked: [HouseholdZoneRecoveryBlockedEntry]
    }

    private struct RecordKey: Hashable {
        let ownerName: String
        let zoneName: String
        let recordName: String

        init(_ identity: MirrorRecordIdentity) {
            ownerName = identity.zoneOwnerName
            zoneName = identity.zoneName
            recordName = identity.recordName
        }
    }

    private struct TotalKey: Hashable {
        let recordType: String
        let action: HouseholdZoneRecoveryAction
    }

    private struct CanonicalPayload: Codable {
        let formatVersion: Int
        let accountFingerprint: String
        let sourceScope: MirrorScope
        let targetScope: MirrorScope
        let sourceInputFingerprint: String
        let targetInputFingerprint: String
        let entries: [HouseholdZoneRecoveryEntry]
        let exclusions: [HouseholdZoneRecoveryExclusion]
        let unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry]
        let blockedEntries: [HouseholdZoneRecoveryBlockedEntry]
        let totals: [HouseholdZoneRecoveryTotal]
    }
}

public extension ShadowMirrorCanonicalDigest {
    static func recoveryManifest(_ manifest: HouseholdZoneRecoveryManifest) -> String {
        var writer = CanonicalWriter()
        writer.append("household-zone-recovery-manifest-v1")
        writer.append(manifest.formatVersion)
        writer.append(manifest.accountFingerprint)
        append(manifest.sourceScope, to: &writer)
        append(manifest.targetScope, to: &writer)
        writer.append(manifest.sourceInputFingerprint)
        writer.append(manifest.targetInputFingerprint)

        writer.append(manifest.entries.count)
        for entry in manifest.entries {
            writer.append("entry")
            append(entry, to: &writer)
        }

        writer.append(manifest.exclusions.count)
        for exclusion in manifest.exclusions {
            writer.append(exclusion.reason)
            writer.append(exclusion.count)
        }

        writer.append(manifest.unresolvedEntries.count)
        for unresolved in manifest.unresolvedEntries {
            writer.append("unresolved-entry")
            append(unresolved.entry, to: &writer)
            if let decision = unresolved.decision {
                writer.append("provenance-decision")
                writer.append(decision.rawValue)
            } else {
                writer.append("no-provenance-decision")
            }
        }

        writer.append(manifest.blockedEntries.count)
        for blocked in manifest.blockedEntries {
            append(blocked.identity, to: &writer)
            writer.append(blocked.reason)
            writer.append(blocked.missingDependencies.count)
            for dependency in blocked.missingDependencies {
                append(dependency, to: &writer)
            }
        }

        writer.append(manifest.totals.count)
        for total in manifest.totals {
            writer.append(total.recordType)
            writer.append(total.action.rawValue)
            writer.append(total.count)
        }
        return ShadowMirrorDigest.sha256(writer.data)
    }

    private static func append(_ scope: MirrorScope, to writer: inout CanonicalWriter) {
        writer.append(scope.formatVersion)
        writer.append(scope.containerIdentifier)
        writer.append(scope.databaseScope.rawValue)
        writer.append(scope.accountRecordName)
        writer.append(scope.zoneOwnerName)
        writer.append(scope.zoneName)
        writer.append(scope.householdID)
        writer.append(scope.role.rawValue)
    }

    private static func append(
        _ entry: HouseholdZoneRecoveryEntry,
        to writer: inout CanonicalWriter
    ) {
        append(entry.identity, to: &writer)
        writer.append(entry.action.rawValue)
        if let decision = entry.decision {
            writer.append("decision")
            writer.append(decision.rawValue)
        } else {
            writer.append("no-decision")
        }
        writer.append(entry.dependencies.count)
        for dependency in entry.dependencies {
            append(dependency.identity, to: &writer)
            writer.append(dependency.requirement.rawValue)
        }
        let assets = entry.assetDigests.sorted { $0.key < $1.key }
        writer.append(assets.count)
        for asset in assets {
            writer.append(asset.key)
            writer.append(asset.value)
        }
    }

    private static func append(
        _ identity: HouseholdZoneRecoveryIdentity,
        to writer: inout CanonicalWriter
    ) {
        writer.append(identity.source)
        writer.append(identity.target)
    }
}
#endif
