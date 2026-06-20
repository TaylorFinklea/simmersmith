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
        /// Set when MULTIPLE household zones exist but NONE could be proved populated
        /// (every profile fetch failed/absent). The caller must NOT alphabetical-guess
        /// into an unproven zone — it surfaces an ambiguous-household error and stays in
        /// the resolving state (review finding A). `false` in every unambiguous case
        /// (zero zones, one zone, or one provably-populated zone among several).
        public let isAmbiguous: Bool

        public init(householdID: String?, ignoredHouseholdIDs: [String], isAmbiguous: Bool = false) {
            self.householdID = householdID
            self.ignoredHouseholdIDs = ignoredHouseholdIDs
            self.isAmbiguous = isAmbiguous
        }
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
    /// - Multiple (shouldn't happen for an owner, but be safe — spec §1.2 / §7 / review
    ///   finding A): pick DETERMINISTICALLY the zone PROVED populated by a successful
    ///   direct fetch of its `HouseholdProfile` root record (recordName = householdID, the
    ///   preserved-PK convention `ensureHouseholdProfile` writes). Ranking by a direct
    ///   `record(for:)` — NOT a `CKQuery` — is load-bearing: the household record types are
    ///   CKSyncEngine-managed and likely have no queryable index, so a `records(matching:)`
    ///   probe would throw for every zone, score them all 0, and let an EMPTY zone tie-break
    ///   ahead of the populated one (orphaning the migrated recipes). If exactly one zone
    ///   proves a profile → that one wins, the rest are ignored. If several prove a profile
    ///   → the lowest id wins (stable), the rest ignored. If NONE proves a profile (every
    ///   fetch absent/failed) → `isAmbiguous = true`, `householdID = nil`: the caller must
    ///   NOT alphabetical-guess into an unproven zone.
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

        // Multiple household zones — prove each one populated by a DIRECT fetch of its
        // HouseholdProfile root record (no CKQuery; see finding A). A zone whose profile
        // fetch succeeds is "real"; absent/failed → unproven.
        var proven: [String] = []
        for candidate in candidates where await hasHouseholdProfile(db: db, householdID: candidate.id, zoneID: candidate.zone.zoneID) {
            proven.append(candidate.id)
        }

        if proven.isEmpty {
            // Ambiguous: several zones, none provably populated. Do NOT guess — the caller
            // surfaces an error and stays resolving (finding A).
            return DiscoveryResult(
                householdID: nil,
                ignoredHouseholdIDs: candidates.map(\.id).sorted(),
                isAmbiguous: true
            )
        }

        // Deterministic winner: lowest id among the provably-populated zones; the other
        // proven + all unproven zones become ignored (log for human reconciliation).
        proven.sort()
        let winner = proven[0]
        let losers = candidates.map(\.id).filter { $0 != winner }.sorted()
        return DiscoveryResult(householdID: winner, ignoredHouseholdIDs: losers)
    }

    /// Prove a zone is a real household by DIRECTLY fetching its `HouseholdProfile` root
    /// record (recordName = householdID, zoneID = the zone) — the preserved-PK convention
    /// `ensureHouseholdProfile` writes. A direct `record(for:)` needs NO queryable index
    /// (unlike `records(matching:)`), so it works for the CKSyncEngine-managed types.
    /// A `.unknownItem` throw means the profile is absent (empty/partial zone) → false; any
    /// other error is conservatively treated as "unproven" (false) so we never rank an
    /// unprovable zone ahead of a proven one.
    private func hasHouseholdProfile(db: CKDatabase, householdID: String, zoneID: CKRecordZone.ID) async -> Bool {
        let recordID = CKRecord.ID(recordName: householdID, zoneID: zoneID)
        do {
            _ = try await db.record(for: recordID)
            return true
        } catch {
            return false
        }
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
