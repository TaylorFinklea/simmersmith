#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import HouseholdRecords

public enum HouseholdZoneRecoveryExclusionReason: String, Codable, Equatable, Sendable {
    case share = "ckshare"
    case coreData = "core-data"
    case coexistence = "coexistence"
    case foreignZone = "foreign-zone"
    case unknownType = "unknown-type"
    case systemType = "system-type"
    case fixture = "fixture"
}

public enum HouseholdZoneRecoveryDependencyRequirement: String, Codable, Equatable, Sendable {
    case required
    case optional
}

public struct HouseholdZoneRecoveryDependencyEdge: Codable, Equatable, Hashable, Sendable {
    public let dependent: HouseholdZoneRecoveryIdentity
    public let dependency: HouseholdZoneRecoveryIdentity
    public let requirement: HouseholdZoneRecoveryDependencyRequirement

    public init(
        dependent: HouseholdZoneRecoveryIdentity,
        dependency: HouseholdZoneRecoveryIdentity,
        requirement: HouseholdZoneRecoveryDependencyRequirement
    ) {
        self.dependent = dependent
        self.dependency = dependency
        self.requirement = requirement
    }
}

public struct HouseholdZoneRecoverySelectableGroup: Codable, Equatable, Sendable {
    public let id: String
    public let members: [HouseholdZoneRecoveryIdentity]
    /// The transitive group closure that must be selected with this group.
    public let dependencyGroupIDs: [String]

    public init(
        id: String,
        members: [HouseholdZoneRecoveryIdentity],
        dependencyGroupIDs: [String]
    ) {
        self.id = id
        self.members = members
        self.dependencyGroupIDs = dependencyGroupIDs
    }
}

public struct HouseholdZoneRecoveryClassification {
    public let eligibleRecords: [CKRecord]
    public let eligibleIdentities: [HouseholdZoneRecoveryIdentity]
    public let exclusions: [HouseholdZoneRecoveryExclusion]
    public let dependencyEdges: [HouseholdZoneRecoveryDependencyEdge]
    public let unresolvedEntries: [HouseholdZoneRecoveryUnresolvedEntry]
    public let blockedEntries: [HouseholdZoneRecoveryBlockedEntry]
    public let selectableGroups: [HouseholdZoneRecoverySelectableGroup]
    public let inputRecordCount: Int
    /// Number of input snapshots represented by `blockedEntries`; duplicate identities count
    /// every repeated snapshot while remaining one identity-tracked blocked entry.
    public let blockedRecordCount: Int

    /// Exclusions, unblocked eligible records, and blocked records are disjoint accounting buckets.
    public var accountedRecordCount: Int {
        exclusions.reduce(eligibleRecords.count + blockedRecordCount) { $0 + $1.count }
    }
}

/// Pure classification of exact-zone snapshots. It performs no CloudKit operations.
public struct HouseholdZoneRecoveryClassifier {
    /// The canonical manifest drives plain CRUD types. Dedicated codecs and the Phase-0 profile
    /// are production household records too, so their existing type declarations complete the set.
    public static let supportedProductionRecordTypes: Set<String> =
        Set(HouseholdRecordType.allCases.map(\.recordTypeName)).union([
            "HouseholdProfile",
            GroceryCodec.recordType,
            EventGroceryCodec.recordType,
            RecipeImageCodec.recordType,
            RecipeMemoryImageCodec.recordType,
        ])

    /// Exact identifiers used by deterministic developer/verification records. Random-looking or
    /// timestamp-adjacent records are deliberately absent: their provenance remains unresolved.
    public static let knownDeterministicFixtureRecordNames: Set<String> =
        HouseholdZoneProvisioner.legacyVerificationHouseholdIDs.union([
            "phase2c-share-handoff",
        ])

    private static let systemRecordTypes: Set<String> = [
        HouseholdMigrationRunner.receiptType,
        "HouseholdRecoveryReceipt",
    ]

    public static let invalidRequiredDependencyReason = "invalid-required-dependency"
    public static let duplicateRecordReason = "duplicate-record"

    public let sourceScope: MirrorScope
    public let targetScope: MirrorScope

    public init(sourceScope: MirrorScope, targetScope: MirrorScope) {
        self.sourceScope = sourceScope
        self.targetScope = targetScope
    }

    public func classify(_ records: [CKRecord]) -> HouseholdZoneRecoveryClassification {
        var exclusionCounts: [HouseholdZoneRecoveryExclusionReason: Int] = [:]
        var candidates: [CKRecord] = []
        var candidateInputCounts: [IdentityKey: Int] = [:]
        var duplicateBlocked: Set<IdentityKey> = []

        for snapshots in Dictionary(grouping: records, by: cloudKitIdentityKey).values {
            if snapshots.count > 1 {
                // CloudKit identity excludes record type. Preserve one identity representative per
                // observed type for diagnostics, but block every repeated input snapshot.
                for typedSnapshots in Dictionary(grouping: snapshots, by: \.recordType).values {
                    let representative = typedSnapshots[0]
                    let key = IdentityKey(identity(for: representative))
                    candidates.append(representative)
                    candidateInputCounts[key] = typedSnapshots.count
                    duplicateBlocked.insert(key)
                }
            } else if let record = snapshots.first {
                if let reason = exclusionReason(for: record) {
                    exclusionCounts[reason, default: 0] += 1
                } else {
                    candidates.append(record)
                    candidateInputCounts[IdentityKey(identity(for: record))] = 1
                }
            }
        }

        candidates.sort { sourceIdentity(for: $0).sortKey < sourceIdentity(for: $1).sortKey }
        let candidateIdentities = candidates.map(identity(for:))
        let candidateKeys = Set(candidateIdentities.map(IdentityKey.init))
        let recordsByKey = Dictionary(uniqueKeysWithValues:
            candidates.map { (IdentityKey(identity(for: $0)), $0) })

        var edges: [HouseholdZoneRecoveryDependencyEdge] = []
        var missingRequired: [IdentityKey: Set<HouseholdZoneRecoveryIdentity>] = [:]
        var invalidRequired: Set<IdentityKey> = []

        for record in candidates {
            let dependent = identity(for: record)
            if duplicateBlocked.contains(IdentityKey(dependent)) {
                continue
            }
            let extraction = dependencyDescriptors(for: record)
            if extraction.hasInvalidRequiredDependency {
                invalidRequired.insert(IdentityKey(dependent))
            }
            for dependency in extraction.descriptors {
                let key = IdentityKey(dependency.identity)
                if candidateKeys.contains(key) {
                    edges.append(HouseholdZoneRecoveryDependencyEdge(
                        dependent: dependent,
                        dependency: dependency.identity,
                        requirement: dependency.requirement))
                } else if dependency.requirement == .required {
                    missingRequired[IdentityKey(dependent), default: []].insert(dependency.identity)
                }
            }
        }

        edges = Array(Set(edges)).sorted(by: Self.edgeComesBefore)
        propagateBlockedDependencies(
            edges: edges,
            missingRequired: &missingRequired,
            invalidRequired: &invalidRequired,
            duplicateBlocked: duplicateBlocked)

        let blockedKeys = Set(missingRequired.keys).union(invalidRequired).union(duplicateBlocked)
        let eligibleRecords = candidates.filter { !blockedKeys.contains(IdentityKey(identity(for: $0))) }
        let eligibleIdentities = eligibleRecords.map(identity(for:))
        let blockedEntries = blockedKeys.map { key in
            let missing = Array(missingRequired[key] ?? [])
            return HouseholdZoneRecoveryBlockedEntry(
                identity: identity(for: recordsByKey[key]!),
                reason: duplicateBlocked.contains(key)
                    ? Self.duplicateRecordReason
                    : invalidRequired.contains(key)
                        ? Self.invalidRequiredDependencyReason
                        : HouseholdZoneRecoveryBlockedEntry.missingDependencyReason,
                missingDependencies: missing)
        }.sorted { $0.identity.source.sortKey < $1.identity.source.sortKey }
        let blockedRecordCount = blockedKeys.reduce(0) {
            $0 + (candidateInputCounts[$1] ?? 0)
        }
        let unresolvedEntries = eligibleIdentities.map {
            HouseholdZoneRecoveryUnresolvedEntry(identity: $0)
        }
        let groups = selectableGroups(
            identities: eligibleIdentities,
            edges: edges.filter {
                !blockedKeys.contains(IdentityKey($0.dependent))
                    && !blockedKeys.contains(IdentityKey($0.dependency))
            })

        let exclusions = exclusionCounts.map {
            HouseholdZoneRecoveryExclusion(reason: $0.key.rawValue, count: $0.value)
        }.sorted { $0.reason < $1.reason }

        return HouseholdZoneRecoveryClassification(
            eligibleRecords: eligibleRecords,
            eligibleIdentities: eligibleIdentities,
            exclusions: exclusions,
            dependencyEdges: edges,
            unresolvedEntries: unresolvedEntries,
            blockedEntries: blockedEntries,
            selectableGroups: groups,
            inputRecordCount: records.count,
            blockedRecordCount: blockedRecordCount)
    }

    private func exclusionReason(for record: CKRecord) -> HouseholdZoneRecoveryExclusionReason? {
        if record.recordType == "cloudkit.share" || record.recordID.recordName == CKRecordNameZoneWideShare {
            return .share
        }
        if record.recordID.zoneID.zoneName == "com.apple.coredata.cloudkit.zone"
            || record.recordType.hasPrefix("CD_") {
            return .coreData
        }
        if record.recordID.zoneID.zoneName == "coexistence-spike" {
            return .coexistence
        }
        if record.recordID.zoneID.ownerName != sourceScope.zoneOwnerName
            || record.recordID.zoneID.zoneName != sourceScope.zoneName {
            return .foreignZone
        }
        if Self.systemRecordTypes.contains(record.recordType) || record.recordType.hasPrefix("cloudkit.") {
            return .systemType
        }
        guard Self.supportedProductionRecordTypes.contains(record.recordType) else {
            return .unknownType
        }
        if Self.knownDeterministicFixtureRecordNames.contains(record.recordID.recordName) {
            return .fixture
        }
        return nil
    }

    private func cloudKitIdentityKey(_ record: CKRecord) -> CloudKitRecordKey {
        CloudKitRecordKey(
            zoneOwnerName: record.recordID.zoneID.ownerName,
            zoneName: record.recordID.zoneID.zoneName,
            recordName: record.recordID.recordName)
    }

    private func sourceIdentity(for record: CKRecord) -> MirrorRecordIdentity {
        MirrorRecordIdentity(record)
    }

    private func identity(for record: CKRecord) -> HouseholdZoneRecoveryIdentity {
        HouseholdZoneRecoveryIdentity(source: sourceIdentity(for: record), targetScope: targetScope)
    }

    private func identity(recordType: String, recordName: String) -> HouseholdZoneRecoveryIdentity {
        HouseholdZoneRecoveryIdentity(
            source: MirrorRecordIdentity(
                recordType: recordType,
                recordName: recordName,
                zoneOwnerName: sourceScope.zoneOwnerName,
                zoneName: sourceScope.zoneName),
            targetScope: targetScope)
    }

    private struct DependencyDescriptor {
        let identity: HouseholdZoneRecoveryIdentity
        let requirement: HouseholdZoneRecoveryDependencyRequirement
    }

    private struct DependencyExtraction {
        let descriptors: [DependencyDescriptor]
        let hasInvalidRequiredDependency: Bool
    }

    private func dependencyDescriptors(for record: CKRecord) -> DependencyExtraction {
        var descriptors: [DependencyDescriptor] = []
        var hasInvalidRequiredDependency = false

        if let manifestType = HouseholdRecordType(recordTypeName: record.recordType) {
            for ref in manifestType.refs {
                let requirement: HouseholdZoneRecoveryDependencyRequirement =
                    ref.kind == .cascadeParent ? .required : .optional
                let recordName: String?
                switch ref.kind {
                case .cascadeParent:
                    recordName = referencedRecordName(record[ref.name])
                    let isOptionalParentStep = manifestType == .recipeStep && ref.name == "parentStep"
                    hasInvalidRequiredDependency =
                        hasInvalidRequiredDependency || (recordName == nil && !isOptionalParentStep)
                case .setNullInZone:
                    recordName = referencedRecordName(record[ref.name])
                case .crossDBString:
                    recordName = nonemptyString(record[ref.name])
                }
                if let recordName {
                    descriptors.append(DependencyDescriptor(
                        identity: identity(recordType: ref.target, recordName: recordName),
                        requirement: requirement))
                }
            }
        }

        switch record.recordType {
        case "HouseholdSetting":
            descriptors.append(DependencyDescriptor(
                identity: identity(recordType: "HouseholdProfile", recordName: sourceScope.householdID),
                requirement: .required))
        case RecipeImageCodec.recordType:
            hasInvalidRequiredDependency = !appendReference(
                field: "recipe", targetType: "Recipe", requirement: .required,
                record: record, to: &descriptors)
        case RecipeMemoryImageCodec.recordType:
            hasInvalidRequiredDependency = !appendReference(
                field: "recipeMemory", targetType: "RecipeMemory", requirement: .required,
                record: record, to: &descriptors)
        case GroceryCodec.recordType:
            hasInvalidRequiredDependency = !appendString(
                field: "weekID", targetType: "Week", requirement: .required,
                record: record, to: &descriptors)
            appendManagedIngredientLinks(record: record, to: &descriptors)
        case EventGroceryCodec.recordType:
            if let eventID = nonemptyString(record["eventID"]) ?? eventID(from: record.recordID.recordName) {
                descriptors.append(DependencyDescriptor(
                    identity: identity(recordType: "Event", recordName: eventID),
                    requirement: .required))
            } else {
                hasInvalidRequiredDependency = true
            }
            appendString(
                field: "mergedIntoWeekID", targetType: "Week", requirement: .optional,
                record: record, to: &descriptors)
            appendString(
                field: "mergedIntoGroceryItemID", targetType: GroceryCodec.recordType, requirement: .optional,
                record: record, to: &descriptors)
            appendManagedIngredientLinks(record: record, to: &descriptors)
        default:
            break
        }

        let canonical = Array(Set(descriptors.map(DescriptorKey.init))).map(\.descriptor).sorted {
            ($0.identity.source.sortKey, $0.requirement.rawValue)
                < ($1.identity.source.sortKey, $1.requirement.rawValue)
        }
        return DependencyExtraction(
            descriptors: canonical,
            hasInvalidRequiredDependency: hasInvalidRequiredDependency)
    }

    private func appendManagedIngredientLinks(
        record: CKRecord,
        to descriptors: inout [DependencyDescriptor]
    ) {
        appendString(
            field: "baseIngredientID", targetType: "BaseIngredient", requirement: .optional,
            record: record, to: &descriptors)
        appendString(
            field: "ingredientVariationID", targetType: "IngredientVariation", requirement: .optional,
            record: record, to: &descriptors)
    }

    @discardableResult
    private func appendReference(
        field: String,
        targetType: String,
        requirement: HouseholdZoneRecoveryDependencyRequirement,
        record: CKRecord,
        to descriptors: inout [DependencyDescriptor]
    ) -> Bool {
        guard let recordName = referencedRecordName(record[field]) else { return false }
        descriptors.append(DependencyDescriptor(
            identity: identity(recordType: targetType, recordName: recordName),
            requirement: requirement))
        return true
    }

    @discardableResult
    private func appendString(
        field: String,
        targetType: String,
        requirement: HouseholdZoneRecoveryDependencyRequirement,
        record: CKRecord,
        to descriptors: inout [DependencyDescriptor]
    ) -> Bool {
        guard let recordName = nonemptyString(record[field]) else { return false }
        descriptors.append(DependencyDescriptor(
            identity: identity(recordType: targetType, recordName: recordName),
            requirement: requirement))
        return true
    }

    private func referencedRecordName(_ value: CKRecordValue?) -> String? {
        guard let reference = value as? CKRecord.Reference,
              reference.recordID.zoneID.ownerName == sourceScope.zoneOwnerName,
              reference.recordID.zoneID.zoneName == sourceScope.zoneName else {
            return nil
        }
        return reference.recordID.recordName
    }

    private func nonemptyString(_ value: CKRecordValue?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private func eventID(from recordName: String) -> String? {
        guard let marker = recordName.range(of: "_eg_"), marker.lowerBound != recordName.startIndex else {
            return nil
        }
        return String(recordName[..<marker.lowerBound])
    }

    private func propagateBlockedDependencies(
        edges: [HouseholdZoneRecoveryDependencyEdge],
        missingRequired: inout [IdentityKey: Set<HouseholdZoneRecoveryIdentity>],
        invalidRequired: inout Set<IdentityKey>,
        duplicateBlocked: Set<IdentityKey>
    ) {
        let requiredEdges = edges.filter { $0.requirement == .required }
        var changed = true
        while changed {
            changed = false
            for edge in requiredEdges {
                let dependentKey = IdentityKey(edge.dependent)
                let dependencyKey = IdentityKey(edge.dependency)
                if invalidRequired.contains(dependencyKey) || duplicateBlocked.contains(dependencyKey) {
                    changed = invalidRequired.insert(dependentKey).inserted || changed
                }
                if let roots = missingRequired[dependencyKey], !roots.isEmpty {
                    let oldCount = missingRequired[dependentKey]?.count ?? 0
                    missingRequired[dependentKey, default: []].formUnion(roots)
                    changed = missingRequired[dependentKey]!.count != oldCount || changed
                }
            }
        }
    }

    private func selectableGroups(
        identities: [HouseholdZoneRecoveryIdentity],
        edges: [HouseholdZoneRecoveryDependencyEdge]
    ) -> [HouseholdZoneRecoverySelectableGroup] {
        let sortedIdentities = identities.sorted { $0.source.sortKey < $1.source.sortKey }
        let identityByKey = Dictionary(uniqueKeysWithValues: sortedIdentities.map { (IdentityKey($0), $0) })
        var adjacency: [IdentityKey: [IdentityKey]] = [:]
        for identity in sortedIdentities { adjacency[IdentityKey(identity)] = [] }
        for edge in edges {
            adjacency[IdentityKey(edge.dependent), default: []].append(IdentityKey(edge.dependency))
        }
        for key in adjacency.keys {
            adjacency[key] = Array(Set(adjacency[key] ?? [])).sorted()
        }

        let components = stronglyConnectedComponents(nodes: Array(identityByKey.keys).sorted(), adjacency: adjacency)
        var componentIndex: [IdentityKey: Int] = [:]
        for (index, component) in components.enumerated() {
            for key in component { componentIndex[key] = index }
        }
        let ids = components.map { component in
            component.compactMap { identityByKey[$0]?.source.sortKey }.sorted().first ?? ""
        }
        var componentDependencies: [Int: Set<Int>] = [:]
        for edge in edges {
            guard let from = componentIndex[IdentityKey(edge.dependent)],
                  let to = componentIndex[IdentityKey(edge.dependency)], from != to else { continue }
            componentDependencies[from, default: []].insert(to)
            if edge.requirement == .required {
                // Aggregate roots select their required descendants as well. The forward edge
                // remains the apply-order dependency; this reverse traversal is selection-only.
                componentDependencies[to, default: []].insert(from)
            }
        }

        func closure(from root: Int) -> Set<Int> {
            var visited: Set<Int> = []
            var stack = Array(componentDependencies[root] ?? []).sorted()
            while let current = stack.popLast() {
                guard visited.insert(current).inserted else { continue }
                stack.append(contentsOf: (componentDependencies[current] ?? []).sorted())
            }
            visited.remove(root)
            return visited
        }

        return components.enumerated().map { index, component in
            HouseholdZoneRecoverySelectableGroup(
                id: ids[index],
                members: component.compactMap { identityByKey[$0] }
                    .sorted { $0.source.sortKey < $1.source.sortKey },
                dependencyGroupIDs: closure(from: index).map { ids[$0] }.sorted())
        }.sorted { $0.id < $1.id }
    }

    private func stronglyConnectedComponents(
        nodes: [IdentityKey],
        adjacency: [IdentityKey: [IdentityKey]]
    ) -> [[IdentityKey]] {
        var nextIndex = 0
        var indices: [IdentityKey: Int] = [:]
        var lowLinks: [IdentityKey: Int] = [:]
        var stack: [IdentityKey] = []
        var onStack: Set<IdentityKey> = []
        var components: [[IdentityKey]] = []

        func visit(_ node: IdentityKey) {
            indices[node] = nextIndex
            lowLinks[node] = nextIndex
            nextIndex += 1
            stack.append(node)
            onStack.insert(node)

            for dependency in adjacency[node] ?? [] {
                if indices[dependency] == nil {
                    visit(dependency)
                    lowLinks[node] = min(lowLinks[node]!, lowLinks[dependency]!)
                } else if onStack.contains(dependency) {
                    lowLinks[node] = min(lowLinks[node]!, indices[dependency]!)
                }
            }

            guard lowLinks[node] == indices[node] else { return }
            var component: [IdentityKey] = []
            while let member = stack.popLast() {
                onStack.remove(member)
                component.append(member)
                if member == node { break }
            }
            components.append(component.sorted())
        }

        for node in nodes where indices[node] == nil { visit(node) }
        return components.sorted { ($0.first ?? IdentityKey.empty) < ($1.first ?? IdentityKey.empty) }
    }

    private static func edgeComesBefore(
        _ lhs: HouseholdZoneRecoveryDependencyEdge,
        _ rhs: HouseholdZoneRecoveryDependencyEdge
    ) -> Bool {
        (lhs.dependent.source.sortKey, lhs.dependency.source.sortKey, lhs.requirement.rawValue)
            < (rhs.dependent.source.sortKey, rhs.dependency.source.sortKey, rhs.requirement.rawValue)
    }

    private struct DescriptorKey: Hashable {
        let descriptor: DependencyDescriptor

        init(_ descriptor: DependencyDescriptor) { self.descriptor = descriptor }

        func hash(into hasher: inout Hasher) {
            hasher.combine(IdentityKey(descriptor.identity))
            hasher.combine(descriptor.requirement.rawValue)
        }

        static func == (lhs: DescriptorKey, rhs: DescriptorKey) -> Bool {
            IdentityKey(lhs.descriptor.identity) == IdentityKey(rhs.descriptor.identity)
                && lhs.descriptor.requirement == rhs.descriptor.requirement
        }
    }

    private struct CloudKitRecordKey: Hashable {
        let zoneOwnerName: String
        let zoneName: String
        let recordName: String
    }

    private struct IdentityKey: Hashable, Comparable {
        let recordType: String
        let recordName: String

        init(_ identity: HouseholdZoneRecoveryIdentity) {
            recordType = identity.source.recordType
            recordName = identity.source.recordName
        }

        static let empty = IdentityKey(recordType: "", recordName: "")

        private init(recordType: String, recordName: String) {
            self.recordType = recordType
            self.recordName = recordName
        }

        static func < (lhs: IdentityKey, rhs: IdentityKey) -> Bool {
            (lhs.recordType, lhs.recordName) < (rhs.recordType, rhs.recordName)
        }
    }
}
#endif
