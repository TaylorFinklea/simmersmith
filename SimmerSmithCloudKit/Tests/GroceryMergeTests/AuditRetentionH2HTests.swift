import Testing
@testable import GroceryMerge

// SP-A Phase 2d — 5-model head-to-head on `pruneAuditBatches` (2026-06-16). Each model's verbatim
// submission (renamed) is run against the same hidden cases for an OBJECTIVE correctness verdict.
// Scores recorded in ~/.claude/model-scorecard.md.

private typealias Prune = ([WeekChangeBatch], RetentionPolicy) -> AuditPruneResult

private func B(_ name: String, _ week: String, _ at: Int) -> WeekChangeBatch {
    WeekChangeBatch(recordName: name, weekID: week, createdAt: at)
}

/// Returns nil if every hidden case passes, else the label of the first failing case.
private func firstFailure(_ prune: Prune) -> String? {
    // 1. basic per-week cap
    let c1 = prune([B("a1","A",1), B("a2","A",2), B("a3","A",3), B("b1","B",5), B("b2","B",6)],
                   RetentionPolicy(maxBatchesPerWeek: 2))
    if c1 != AuditPruneResult(keep: ["a2","a3","b1","b2"], prune: ["a1"]) { return "basic max=2 (\(c1))" }
    // 2. tiebreak by recordName desc when createdAt ties
    let c2 = prune([B("c1","C",5), B("c2","C",5)], RetentionPolicy(maxBatchesPerWeek: 1))
    if c2 != AuditPruneResult(keep: ["c2"], prune: ["c1"]) { return "tiebreak (\(c2))" }
    // 3. max<=0 prunes all
    let c3 = prune([B("a1","A",1), B("a2","A",2)], RetentionPolicy(maxBatchesPerWeek: 0))
    if c3 != AuditPruneResult(keep: [], prune: ["a1","a2"]) { return "max=0 (\(c3))" }
    // 4. cap >= count keeps all
    let c4 = prune([B("a1","A",1), B("a2","A",2)], RetentionPolicy(maxBatchesPerWeek: 10))
    if c4 != AuditPruneResult(keep: ["a1","a2"], prune: []) { return "cap>count (\(c4))" }
    // 5. empty input
    let c5 = prune([], RetentionPolicy(maxBatchesPerWeek: 2))
    if c5 != AuditPruneResult(keep: [], prune: []) { return "empty (\(c5))" }
    return nil
}

@Test func h2h_sonnet()  { #expect(firstFailure(prune_sonnet)  == nil) }
@Test func h2h_haiku()   { #expect(firstFailure(prune_haiku)   == nil) }
@Test func h2h_minimax() { #expect(firstFailure(prune_minimax) == nil) }
@Test func h2h_qwen()    { #expect(firstFailure(prune_qwen)    == nil) }
@Test func h2h_kimi()    { #expect(firstFailure(prune_kimi)    == nil) }
@Test func h2h_canonical() { #expect(firstFailure(pruneAuditBatches) == nil) }   // shipped version

// ===== verbatim model submissions (renamed) =====

private func prune_sonnet(_ batches: [WeekChangeBatch], policy: RetentionPolicy) -> AuditPruneResult {
    var keepNames: [String] = []
    var pruneNames: [String] = []
    let grouped = Dictionary(grouping: batches, by: { $0.weekID })
    for (_, weekBatches) in grouped {
        let sorted = weekBatches.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.recordName > $1.recordName
        }
        if policy.maxBatchesPerWeek <= 0 {
            pruneNames.append(contentsOf: sorted.map { $0.recordName })
        } else {
            let keepCount = min(policy.maxBatchesPerWeek, sorted.count)
            keepNames.append(contentsOf: sorted.prefix(keepCount).map { $0.recordName })
            pruneNames.append(contentsOf: sorted.dropFirst(keepCount).map { $0.recordName })
        }
    }
    return AuditPruneResult(keep: keepNames.sorted(), prune: pruneNames.sorted())
}

private func prune_haiku(_ batches: [WeekChangeBatch], policy: RetentionPolicy) -> AuditPruneResult {
    if policy.maxBatchesPerWeek <= 0 {
        return AuditPruneResult(keep: [], prune: batches.map { $0.recordName }.sorted())
    }
    var batchesByWeek: [String: [WeekChangeBatch]] = [:]
    for batch in batches {
        if batchesByWeek[batch.weekID] == nil { batchesByWeek[batch.weekID] = [] }
        batchesByWeek[batch.weekID]?.append(batch)
    }
    var keepRecordNames: [String] = []
    var pruneRecordNames: [String] = []
    for (_, weekBatches) in batchesByWeek {
        let sorted = weekBatches.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.recordName > b.recordName
        }
        for (index, batch) in sorted.enumerated() {
            if index < policy.maxBatchesPerWeek { keepRecordNames.append(batch.recordName) }
            else { pruneRecordNames.append(batch.recordName) }
        }
    }
    keepRecordNames.sort(); pruneRecordNames.sort()
    return AuditPruneResult(keep: keepRecordNames, prune: pruneRecordNames)
}

private func prune_minimax(_ batches: [WeekChangeBatch], policy: RetentionPolicy) -> AuditPruneResult {
    if policy.maxBatchesPerWeek <= 0 {
        return AuditPruneResult(keep: [], prune: batches.map { $0.recordName }.sorted())
    }
    var groups: [String: [WeekChangeBatch]] = [:]
    for batch in batches { groups[batch.weekID, default: []].append(batch) }
    var keep: [String] = []
    var prune: [String] = []
    for (_, group) in groups {
        let ordered = group.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.recordName > rhs.recordName
        }
        for (index, batch) in ordered.enumerated() {
            if index < policy.maxBatchesPerWeek { keep.append(batch.recordName) }
            else { prune.append(batch.recordName) }
        }
    }
    return AuditPruneResult(keep: keep.sorted(), prune: prune.sorted())
}

private func prune_qwen(_ batches: [WeekChangeBatch], policy: RetentionPolicy) -> AuditPruneResult {
    guard policy.maxBatchesPerWeek > 0 else {
        return AuditPruneResult(keep: [], prune: batches.map(\.recordName).sorted())
    }
    var grouped: [String: [WeekChangeBatch]] = [:]
    for batch in batches { grouped[batch.weekID, default: []].append(batch) }
    var keepSet: Set<String> = []
    for (_, weekBatches) in grouped {
        let sorted = weekBatches.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.recordName > b.recordName
        }
        let keepCount = min(policy.maxBatchesPerWeek, sorted.count)
        for i in 0..<keepCount { keepSet.insert(sorted[i].recordName) }
    }
    var keep: [String] = []
    var prune: [String] = []
    for batch in batches {
        if keepSet.contains(batch.recordName) { keep.append(batch.recordName) }
        else { prune.append(batch.recordName) }
    }
    return AuditPruneResult(keep: keep.sorted(), prune: prune.sorted())
}

private func prune_kimi(_ batches: [WeekChangeBatch], policy: RetentionPolicy) -> AuditPruneResult {
    let maxKept = policy.maxBatchesPerWeek
    var keepRecordNames = Set<String>()
    if maxKept > 0 {
        var byWeek = [String: [WeekChangeBatch]]()
        for batch in batches { byWeek[batch.weekID, default: []].append(batch) }
        for (_, group) in byWeek {
            let sorted = group.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.recordName > rhs.recordName
            }
            for batch in sorted.prefix(maxKept) { keepRecordNames.insert(batch.recordName) }
        }
    }
    let keep = batches.map(\.recordName).filter { keepRecordNames.contains($0) }.sorted()
    let prune = batches.map(\.recordName).filter { !keepRecordNames.contains($0) }.sorted()
    return AuditPruneResult(keep: keep, prune: prune)
}
