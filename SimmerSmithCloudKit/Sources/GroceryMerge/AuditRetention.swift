import Foundation

// SP-A Phase 2d — append-only audit (WeekChangeBatch) retention. The audit syncs to every
// household member's iCloud quota the moment it lands, so it must be pruned on a per-week cap.
// Pure value-type logic → unit-tested headlessly; the engine applies the returned prune set.

public struct WeekChangeBatch: Equatable {
    public let recordName: String
    public var weekID: String
    public var createdAt: SyncClock   // higher = newer
    public init(recordName: String, weekID: String, createdAt: SyncClock) {
        self.recordName = recordName; self.weekID = weekID; self.createdAt = createdAt
    }
}

public struct RetentionPolicy: Equatable {
    public var maxBatchesPerWeek: Int
    public init(maxBatchesPerWeek: Int) { self.maxBatchesPerWeek = maxBatchesPerWeek }
}

public struct AuditPruneResult: Equatable {
    public var keep: [String]    // kept recordNames, sorted ascending
    public var prune: [String]   // pruned recordNames, sorted ascending
    public init(keep: [String], prune: [String]) { self.keep = keep; self.prune = prune }
}

/// Keep the `maxBatchesPerWeek` newest batches per week (createdAt desc, recordName desc tiebreak);
/// prune the rest. `maxBatchesPerWeek <= 0` prunes all. (Winner of the 5-model head-to-head —
/// see model-scorecard.md 2026-06-16.)
public func pruneAuditBatches(_ batches: [WeekChangeBatch], policy: RetentionPolicy) -> AuditPruneResult {
    guard policy.maxBatchesPerWeek > 0 else {
        return AuditPruneResult(keep: [], prune: batches.map(\.recordName).sorted())
    }
    var grouped: [String: [WeekChangeBatch]] = [:]
    for batch in batches { grouped[batch.weekID, default: []].append(batch) }

    var keepSet: Set<String> = []
    for (_, weekBatches) in grouped {
        let sorted = weekBatches.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.recordName > b.recordName
        }
        for batch in sorted.prefix(policy.maxBatchesPerWeek) { keepSet.insert(batch.recordName) }
    }
    var keep: [String] = [], prune: [String] = []
    for batch in batches {
        if keepSet.contains(batch.recordName) { keep.append(batch.recordName) }
        else { prune.append(batch.recordName) }
    }
    return AuditPruneResult(keep: keep.sorted(), prune: prune.sorted())
}
