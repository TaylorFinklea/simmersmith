#if canImport(CloudKit)
import CloudKit
import Foundation

/// SP-A Phase 0/2 zone + share scaffolding for the container
/// `iCloud.app.simmersmith.cloud`. Compiles headlessly; the actual operations need
/// an iCloud-signed-in, entitled target (the app, with the
/// `com.apple.developer.icloud-container-identifiers` entitlement set to this
/// container). `verifyRoundTrip` is the Phase 0 Verify.
public struct HouseholdZoneProvisioner {
    public let container: CKContainer
    public init(containerIdentifier: String = "iCloud.app.simmersmith.cloud") {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    /// Deterministic zone name (owner-two-devices race fix, spec §2.2 / review C1):
    /// both of an owner's devices derive the SAME zone name from the household id,
    /// so racing zone creation converges on one zone instead of forking the household.
    public static func zoneName(householdID: String) -> String { "household-\(householdID)" }

    /// Prefix the household-zone naming convention uses (`household-<id>`). Single
    /// source of truth shared by `zoneName(householdID:)` and `householdID(fromZoneName:)`.
    static let zoneNamePrefix = "household-"

    /// Inverse of `zoneName(householdID:)`: parse the household id back out of a zone
    /// name. Returns `nil` for any zone whose name doesn't match the `household-<id>`
    /// convention (CloudKit's default `_defaultZone`, future non-household zones, …).
    /// A UUID id with hyphens survives the round-trip because only the leading
    /// `household-` prefix is stripped — the remainder (which may itself contain
    /// hyphens) is returned verbatim. An empty remainder (`"household-"`) → nil.
    public static func householdID(fromZoneName zoneName: String) -> String? {
        guard zoneName.hasPrefix(zoneNamePrefix) else { return nil }
        let id = String(zoneName.dropFirst(zoneNamePrefix.count))
        return id.isEmpty ? nil : id
    }

    /// Idempotent: saving an existing zone is a no-op success, so this is safe to
    /// run on every launch (the discover-then-claim is implicit in the deterministic
    /// name + idempotent save).
    @discardableResult
    public func ensureHouseholdZone(householdID: String) async throws -> CKRecordZone {
        let zone = CKRecordZone(
            zoneID: CKRecordZone.ID(zoneName: Self.zoneName(householdID: householdID),
                                    ownerName: CKCurrentUserDefaultName))
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [zone], deleting: [])
        return zone
    }

    /// Fetch-or-create the `HouseholdProfile` root record (recordName = householdID,
    /// the preserved-PK policy from Phase 0 §A).
    public func ensureHouseholdProfile(householdID: String, name: String) async throws -> CKRecord {
        let db = container.privateCloudDatabase
        let zone = try await ensureHouseholdZone(householdID: householdID)
        let recordID = CKRecord.ID(recordName: householdID, zoneID: zone.zoneID)
        do {
            return try await db.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: "HouseholdProfile", recordID: recordID)
            record["name"] = name
            record["createdAt"] = Date()
            _ = try await db.modifyRecords(saving: [record], deleting: [])
            return record
        }
    }

    /// Day-one CKShare on the HouseholdProfile (spec §2.2 — share-ready from birth,
    /// no solo-then-merge). The share need not be surfaced until the user invites.
    public func ensureShare(for profile: CKRecord, title: String) async throws -> CKShare {
        let share = CKShare(rootRecord: profile)
        share[CKShare.SystemFieldKey.title] = title
        _ = try await container.privateCloudDatabase.modifyRecords(saving: [profile, share], deleting: [])
        return share
    }

    /// Outcome of `discoverHouseholdResult()`: the chosen household id plus any losing
    /// zones the caller should log/reconcile when more than one household zone exists.
    public struct DiscoveryResult: Sendable, Equatable {
        /// The resolved household id, or `nil` when no `household-*` zone exists.
        public let householdID: String?
        /// Ids of additional household zones NOT chosen (spec §1.2 — log, don't pick).
        /// Empty in the common zero/one-zone case.
        public let ignoredHouseholdIDs: [String]
    }

    /// SP-C identity slice (spec §1.1): discover the household id from CloudKit instead
    /// of taking it from Fly. Convenience over `discoverHouseholdResult()` that drops the
    /// ignored-zone list — returns just the resolved id (or `nil`).
    public func discoverHouseholdID() async throws -> String? {
        try await discoverHouseholdResult().householdID
    }

    /// Discover the household id from CloudKit, returning the chosen id plus any ignored
    /// (losing) household zones. Lists the private DB's record zones, finds the
    /// `household-<id>` zone(s), and parses the id back out (`householdID(fromZoneName:)`
    /// is the inverse of `zoneName`).
    ///
    /// - Zero `household-*` zones → `householdID == nil` (caller mints a fresh household).
    /// - Exactly one → that id, no ignored zones.
    /// - Multiple (shouldn't happen for an owner, but be safe — spec §1.2 / §7): pick
    ///   DETERMINISTICALLY the most-populated zone (one bearing a `HouseholdProfile`, else
    ///   the highest total record count), never silently a near-empty zone over a populated
    ///   one; ties broken by id for stability. The rest land in `ignoredHouseholdIDs` so the
    ///   caller can log them for human reconciliation (a future slice may merge/delete them).
    ///
    /// Throws on a CloudKit failure fetching the zone list (network, not-signed-in) so the
    /// caller's retry/backoff (spec §4) drives — a transient hiccup must NOT look like
    /// "zero zones" and trigger an orphaning auto-create (spec §7 landmine).
    public func discoverHouseholdResult() async throws -> DiscoveryResult {
        let db = container.privateCloudDatabase
        let zones = try await db.allRecordZones()

        // Map each household zone to (householdID, zone) — drop _defaultZone + anything
        // not matching the convention.
        let candidates: [(id: String, zone: CKRecordZone)] = zones.compactMap { zone in
            guard let id = Self.householdID(fromZoneName: zone.zoneID.zoneName) else { return nil }
            return (id, zone)
        }

        if candidates.isEmpty { return DiscoveryResult(householdID: nil, ignoredHouseholdIDs: []) }
        if candidates.count == 1 {
            return DiscoveryResult(householdID: candidates[0].id, ignoredHouseholdIDs: [])
        }

        // Multiple household zones — score each so we never pick an empty one over a
        // populated one. Score = (hasHouseholdProfile ? large : 0) + recordCount.
        var scored: [(id: String, score: Int)] = []
        for candidate in candidates {
            let score = await populationScore(db: db, zoneID: candidate.zone.zoneID)
            scored.append((candidate.id, score))
        }
        // Deterministic: highest score wins; ties broken by id (stable across launches).
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.id < rhs.id
        }
        let winner = scored[0]
        let losers = scored.dropFirst().map(\.id)
        return DiscoveryResult(householdID: winner.id, ignoredHouseholdIDs: Array(losers))
    }

    /// Rough population score for disambiguating multiple household zones (spec §1.2):
    /// a zone bearing a `HouseholdProfile` outranks any without one; among those that
    /// tie, more records wins. Best-effort — a per-zone query failure scores 0 (treated
    /// as empty) so a readable, populated zone is still preferred. Not exact: the
    /// `records(matching:)` call returns the first page, which is enough to tell a
    /// populated zone from an empty/near-empty one (the only distinction §1.2 needs).
    private func populationScore(db: CKDatabase, zoneID: CKRecordZone.ID) async -> Int {
        // HouseholdProfile presence is the strong signal (the real household has one).
        let profileBonus = 1_000_000
        do {
            let predicate = NSPredicate(value: true)
            let query = CKQuery(recordType: "HouseholdProfile", predicate: predicate)
            let (profileMatches, _) = try await db.records(
                matching: query, inZoneWith: zoneID, desiredKeys: [], resultsLimit: 1
            )
            let hasProfile = profileMatches.contains { _, result in
                if case .success = result { return true }
                return false
            }
            // Count of any records in the zone (first page) as the tie-breaker magnitude.
            let recordCount = await anyRecordCount(db: db, zoneID: zoneID)
            return (hasProfile ? profileBonus : 0) + recordCount
        } catch {
            // Query failed for this zone — treat as empty so a readable zone is preferred.
            return 0
        }
    }

    /// Best-effort count of records in a zone (first page) — magnitude only, used purely
    /// to rank populated vs empty zones. Probes a few known household record types; any
    /// hit makes the zone look "populated". Failures contribute 0.
    private func anyRecordCount(db: CKDatabase, zoneID: CKRecordZone.ID) async -> Int {
        let probeTypes = ["HouseholdProfile", "Recipe", "MigrationReceipt", "GroceryItem"]
        var total = 0
        for type in probeTypes {
            do {
                let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
                let (matches, _) = try await db.records(
                    matching: query, inZoneWith: zoneID, desiredKeys: [], resultsLimit: 100
                )
                total += matches.count
            } catch {
                continue
            }
        }
        return total
    }

    /// Phase 0 VERIFY: create the zone, write `HouseholdProfile`, read it back.
    /// Returns the round-tripped name (should equal `name`). Run from an entitled,
    /// iCloud-signed-in target.
    public func verifyRoundTrip(householdID: String = "phase0-test",
                                name: String = "Phase 0 Test") async throws -> String {
        _ = try await ensureHouseholdProfile(householdID: householdID, name: name)
        let zoneID = CKRecordZone.ID(zoneName: Self.zoneName(householdID: householdID),
                                     ownerName: CKCurrentUserDefaultName)
        let read = try await container.privateCloudDatabase
            .record(for: CKRecord.ID(recordName: householdID, zoneID: zoneID))
        return read["name"] as? String ?? ""
    }
}
#endif
