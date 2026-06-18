#if canImport(CloudKit)
import CloudKit
import Foundation

// SP-A Phase 6 — READ-ONLY access to the curator-owned PUBLIC catalog (spec §8). The app dropped its
// server, so clients NEVER write to PUBLIC (arbitrary writes would corrupt the global catalog); the
// curator (SP-E) seeds it out-of-band, and until that server exists PUBLIC is a frozen one-time seed
// (decisions.md 2026-06-17). Resolve order (§8.2): prefetched cache → a CKQuery against PUBLIC by
// `normalizedName` → nil (the caller then mints a household_only fallback in its OWN zone). Defensive:
// any transient/permission/network error returns nil/[] — never crashes; the client dedupes on read
// (most-recently-updated wins). Only `normalizedName` (+ RecipeTemplate.builtIn) is queryable, so
// `submissionStatus`/`active` are filtered CLIENT-SIDE. No write path exists here, by construction.

/// A catalog row projected from a PUBLIC CKRecord. Sendable (carries no CKRecordValue) so it crosses
/// the cache-actor boundary cleanly: identity + the catalog's string, numeric, and date fields.
public struct CatalogRow: Sendable, Equatable {
    public let recordName: String
    public let recordType: String
    public let normalizedName: String
    public let name: String
    public let strings: [String: String]
    public let numbers: [String: Double]   // INT64 (incl. Bool 0/1) + DOUBLE
    public let dates: [String: Date]

    init(_ record: CKRecord) {
        recordName = record.recordID.recordName
        recordType = record.recordType
        normalizedName = record["normalizedName"] as? String ?? ""
        name = record["name"] as? String ?? ""
        var s: [String: String] = [:]
        var n: [String: Double] = [:]
        var d: [String: Date] = [:]
        for key in record.allKeys() {
            if let v = record[key] as? String { s[key] = v }
            else if let v = record[key] as? Date { d[key] = v }
            else if let v = record[key] as? Double { n[key] = v }
            else if let v = record[key] as? Int { n[key] = Double(v) }
        }
        strings = s; numbers = n; dates = d
    }
    public func string(_ key: String) -> String? { strings[key] }
    public func number(_ key: String) -> Double? { numbers[key] }
    public func date(_ key: String) -> Date? { dates[key] }
}

/// Thread-safe partial-catalog cache. One dict keyed by `<type>\u1<normalizedName>`; on a duplicate
/// `normalizedName` the more-authoritative row wins (later `updatedAt`, ties broken by lowest
/// recordName for determinism). Plus the built-in template list.
private actor CatalogCache {
    private var rows: [String: CatalogRow] = [:]
    private var templates: [CatalogRow]?

    private func key(_ type: String, _ name: String) -> String { "\(type)\u{1}\(name)" }

    func row(type: String, name: String) -> CatalogRow? { rows[key(type, name)] }

    func insert(_ incoming: [CatalogRow]) {
        for r in incoming {
            let k = key(r.recordType, r.normalizedName)
            if let existing = rows[k], !prefer(r, over: existing) { continue }
            rows[k] = r
        }
    }

    /// More-authoritative = later `updatedAt`; a tie (or missing dates) breaks on lowest recordName
    /// so the choice is deterministic across devices.
    private func prefer(_ a: CatalogRow, over b: CatalogRow) -> Bool {
        let ua = a.date("updatedAt"), ub = b.date("updatedAt")
        if let ua, let ub, ua != ub { return ua > ub }
        if (ua == nil) != (ub == nil) { return ua != nil }   // a row WITH a timestamp beats one without
        return a.recordName < b.recordName
    }

    func cachedTemplates() -> [CatalogRow]? { templates }
    func setTemplates(_ t: [CatalogRow]) { templates = t }
    func clear() { rows.removeAll(); templates = nil }
}

public struct PublicCatalogReader: Sendable {
    private let database: CKDatabase
    private let cache = CatalogCache()

    public init(database: CKDatabase) { self.database = database }

    private static let baseType = "BaseIngredient"
    private static let variationType = "IngredientVariation"
    private static let templateType = "RecipeTemplate"

    /// Drop the session cache so a later read re-fetches from PUBLIC (e.g. after the curator
    /// publishes an update; under the frozen-seed model this is rarely needed).
    public func clearCache() async { await cache.clear() }

    /// Batch-prefetch approved, active BaseIngredients for a set of normalized names into the cache
    /// (chunked `IN` queries to stay within PUBLIC-db query limits).
    public func prefetchCommonHead(names: [String]) async {
        let unique = Array(Set(names.filter { !$0.isEmpty }))
        let chunk = 50
        for start in stride(from: 0, to: unique.count, by: chunk) {
            let slice = Array(unique[start..<min(start + chunk, unique.count)])
            let rows = await query(Self.baseType, NSPredicate(format: "normalizedName IN %@", slice))
                .filter(Self.isApprovedActive)
            await cache.insert(rows)
        }
    }

    /// Resolve a canonical approved+active BaseIngredient by normalized name. cache → PUBLIC CKQuery → nil.
    public func resolveBaseIngredient(normalizedName: String) async -> CatalogRow? {
        await resolve(type: Self.baseType, normalizedName: normalizedName, filter: Self.isApprovedActive)
    }

    /// Resolve a global active IngredientVariation by normalized name (variations have no submission
    /// gate, but archived/merged-away rows must not be served as the canonical match).
    public func resolveIngredientVariation(normalizedName: String) async -> CatalogRow? {
        await resolve(type: Self.variationType, normalizedName: normalizedName, filter: Self.isActive)
    }

    private func resolve(type: String, normalizedName: String,
                         filter: @Sendable (CatalogRow) -> Bool) async -> CatalogRow? {
        guard !normalizedName.isEmpty else { return nil }
        if let cached = await cache.row(type: type, name: normalizedName) { return cached }
        let rows = await query(type, NSPredicate(format: "normalizedName == %@", normalizedName)).filter(filter)
        await cache.insert(rows)
        return await cache.row(type: type, name: normalizedName)
    }

    /// The built-in RecipeTemplates (cached after the first NON-EMPTY fetch — an empty/failed result
    /// is never cached, so a transient error doesn't poison the session).
    public func recipeTemplates() async -> [CatalogRow] {
        if let cached = await cache.cachedTemplates() { return cached }
        let rows = await query(Self.templateType, NSPredicate(format: "builtIn == 1"))
        if !rows.isEmpty { await cache.setTemplates(rows) }
        return rows
    }

    // Client-side gates (PUBLIC indexes only `normalizedName`/`builtIn`, so these can't be predicates).
    private static let isActive: @Sendable (CatalogRow) -> Bool = { ($0.number("active") ?? 1) != 0 }
    private static let isApprovedActive: @Sendable (CatalogRow) -> Bool = {
        ($0.number("active") ?? 1) != 0 && ($0.string("submissionStatus") ?? "approved") == "approved"
    }

    /// One defensive PUBLIC query → projected rows, FOLLOWING the cursor (CloudKit pages at ~200, so
    /// discarding it would silently truncate large result sets). Any thrown error (network,
    /// not-queryable, rate-limit, permission) degrades to whatever pages already arrived (or []).
    private func query(_ recordType: String, _ predicate: NSPredicate) async -> [CatalogRow] {
        var out: [CatalogRow] = []
        do {
            var page = try await database.records(matching: CKQuery(recordType: recordType, predicate: predicate))
            while true {
                for (_, result) in page.matchResults {
                    if case .success(let record) = result { out.append(CatalogRow(record)) }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await database.records(continuingMatchFrom: cursor)
            }
        } catch {
            return out   // partial pages are still useful; a first-page failure → []
        }
        return out
    }
}
#endif
