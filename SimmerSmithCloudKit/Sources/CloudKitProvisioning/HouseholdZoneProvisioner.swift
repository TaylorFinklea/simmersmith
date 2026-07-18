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

        // Multiple household zones (SP-C on-device finding, build 118: repeated early-build
        // minting). Rank by DATA RICHNESS — the zone holding the user's records wins over the
        // empty profile-only mints. The earlier "has a HouseholdProfile" proof couldn't tell
        // them apart: EVERY mint writes a HouseholdProfile, so empties proved just as "real"
        // as the recipe-bearing zone, and the lowest-id tiebreak orphaned the real data into
        // an ignored zone. Counting records (via fetch-zone-changes, no index needed) does
        // distinguish them: the recipe zone has dozens, the mints have ≤1.
        var scored: [(id: String, count: Int)] = []
        for candidate in candidates {
            // Fail-OPEN on purpose (the opposite of the deletion path): an unreadable zone
            // scores 0 so it can never outrank a readable data zone, and if NONE can be read
            // the field falls to `isAmbiguous` instead of guessing. Deleting on a 0 we couldn't
            // prove would be data loss — hence `recordCount`'s `Int?`.
            let count = await recordCount(db: db, zoneID: candidate.zone.zoneID) ?? 0
            scored.append((candidate.id, count))
        }
        return Self.chooseRichestHousehold(scored)
    }

    /// Pick the data-richest household among several candidates, each scored by how many
    /// records its zone holds. Pure + deterministic (the CloudKit count fetch is `recordCount`,
    /// verified on-device); this is the ranking that, done by profile-presence alone, orphaned
    /// the user's recipes on build 118.
    ///   - Highest count wins (the zone with the user's data); ties at the max → lowest id.
    ///   - If NO candidate holds data beyond a bare profile (every count ≤ 1) → ambiguous
    ///     (id nil): don't pick an empty zone and orphan data that may still be propagating —
    ///     the caller stays resolving and retries.
    static func chooseRichestHousehold(_ scored: [(id: String, count: Int)]) -> DiscoveryResult {
        let allIDs = scored.map(\.id).sorted()
        guard let maxCount = scored.map(\.count).max(), maxCount > 1 else {
            return DiscoveryResult(householdID: nil, ignoredHouseholdIDs: allIDs,
                                   isAmbiguous: !scored.isEmpty)
        }
        let winner = scored.filter { $0.count == maxCount }.map(\.id).sorted()[0]
        return DiscoveryResult(householdID: winner,
                               ignoredHouseholdIDs: allIDs.filter { $0 != winner })
    }

    /// Count the records in a zone via `CKFetchRecordZoneChangesOperation` — needs NO queryable
    /// index (unlike `records(matching:)`), so it works for the CKSyncEngine-managed household
    /// types. Fetches record IDs only (`desiredKeys = []`) to stay cheap.
    ///
    /// `nil` means COULD NOT READ the zone (the fetch failed, or a record in it wouldn't
    /// decode) — NOT "zero records". The distinction is load-bearing, and the two callers take
    /// deliberately OPPOSITE policies on it:
    ///
    ///   - RANKING (`discoverHouseholdResult`) is fail-OPEN: `?? 0`. An unreadable zone scores
    ///     0 so it can never outrank a readable data zone, and an all-unreadable field falls to
    ///     `isAmbiguous` rather than guessing.
    ///   - DELETION (`deleteEmptyHouseholdZones`) is fail-CLOSED: `nil` → keep. Collapsing
    ///     "couldn't read" into 0 would make it indistinguishable from "provably empty", so one
    ///     transient CloudKit failure would delete a zone holding the user's recipes.
    ///
    /// That is why this returns `Int?` and not `Int`: the optional is the only thing carrying
    /// "I don't know" across the boundary, and deletion is the caller that must not guess.
    func recordCount(db: CKDatabase, zoneID: CKRecordZone.ID) async -> Int? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.desiredKeys = []
            let op = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: config])
            op.fetchAllChanges = true
            var count = 0
            var unreadable = false
            op.recordWasChangedBlock = { _, result in
                switch result {
                case .success: count += 1
                // A record we can see but can't decode still PROVES the zone is not empty.
                case .failure: unreadable = true
                }
            }
            // A single-zone op can still report a per-zone failure here while the overall
            // result succeeds — check both, or a partial failure reads as "empty".
            op.recordZoneFetchResultBlock = { _, result in
                if case .failure = result { unreadable = true }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                if case .failure = result { unreadable = true }
                continuation.resume(returning: unreadable ? nil : count)
            }
            db.add(op)
        }
    }

    /// What a cleanup pass did with the leftover (non-active) `household-*` zones. Returned by
    /// `deleteEmptyHouseholdZones`, which THROWS if the delete itself fails — so an outcome in
    /// hand means `deletedHouseholdIDs` really are gone.
    public struct CleanupOutcome: Sendable, Equatable {
        /// Proved empty (≤1 record — a bare `HouseholdProfile`, or nothing) and deleted.
        public let deletedHouseholdIDs: [String]
        /// Read fine, but hold REAL records (>1) — a genuine fork, not build residue. Kept, and
        /// surfaced in Settings: the app opened the richest zone, but a second one has data.
        public let dataBearingHouseholdIDs: [String]
        /// Could not be censused this pass. Kept (fail-closed) and deliberately NOT surfaced —
        /// a transient CloudKit failure must never masquerade as a fork. Retried next launch.
        public let unreadableHouseholdIDs: [String]

        public init(deletedHouseholdIDs: [String],
                    dataBearingHouseholdIDs: [String],
                    unreadableHouseholdIDs: [String]) {
            self.deletedHouseholdIDs = deletedHouseholdIDs
            self.dataBearingHouseholdIDs = dataBearingHouseholdIDs
            self.unreadableHouseholdIDs = unreadableHouseholdIDs
        }

        public var isEmpty: Bool {
            deletedHouseholdIDs.isEmpty && dataBearingHouseholdIDs.isEmpty && unreadableHouseholdIDs.isEmpty
        }
    }

    /// The cleanup DECISION, pure and headlessly testable (the CloudKit delete it feeds is
    /// verified on-device — same split as `chooseRichestHousehold`). Three-way, because a
    /// two-way "empty or not" has nowhere to put "I couldn't read it":
    ///
    ///   census ≤ 1  → DELETE       (provably empty)
    ///   census > 1  → keep, report (a real fork — the user should know)
    ///   census nil  → keep, silent (unproven — retry next launch)
    ///
    /// `keeping` (the resolved household) is filtered out unconditionally, whatever it censused.
    ///
    /// Feed this a fresh census — NEVER `DiscoveryResult.ignoredHouseholdIDs`. "Ignored" means
    /// "not chosen", not "empty": when two zones tie on record count the loser is ignored while
    /// holding every one of its records (see `tieBreaksLowestID`), so deleting that list
    /// wholesale would destroy live data.
    static func classifyLeftovers(_ censused: [(id: String, count: Int?)],
                                  keeping: String) -> CleanupOutcome {
        var deleted: [String] = []
        var dataBearing: [String] = []
        var unreadable: [String] = []
        for leftover in censused where leftover.id != keeping {
            guard let count = leftover.count else {
                unreadable.append(leftover.id)
                continue
            }
            if count <= 1 {
                deleted.append(leftover.id)
            } else {
                dataBearing.append(leftover.id)
            }
        }
        return CleanupOutcome(deletedHouseholdIDs: deleted.sorted(),
                              dataBearingHouseholdIDs: dataBearing.sorted(),
                              unreadableHouseholdIDs: unreadable.sorted())
    }

    /// Maintenance (simmersmith-auc): delete the empty/orphan `household-*` zones left by
    /// earlier repeated minting, KEEPING the given household. Runs automatically each launch
    /// (see `AppState.cleanUpLeftoverHouseholds`), so it is destructive code running unattended
    /// — every guard here is load-bearing:
    ///
    ///   - It takes its OWN fresh census rather than a caller-supplied count, so it cannot be
    ///     handed stale numbers, and cannot be pointed at `ignoredHouseholdIDs` (which means
    ///     "not chosen", NOT "empty").
    ///   - An un-censusable zone is KEPT, not deleted (`recordCount` returns `nil`, not 0).
    ///   - Zones are deleted by the exact `CKRecordZone.ID` we censused, not a reconstructed one.
    ///
    /// Throws if the delete fails, leaving every zone intact — the pass is idempotent, so the
    /// caller's recovery is simply to try again next launch.
    @discardableResult
    public func deleteEmptyHouseholdZones(
        keeping: String,
        shouldDelete: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> CleanupOutcome {
        let db = container.privateCloudDatabase
        let zones = try await db.allRecordZones()

        var censused: [(id: String, count: Int?)] = []
        var zoneIDsByHousehold: [String: CKRecordZone.ID] = [:]
        for zone in zones {
            // Skipping `keeping` here spares a pointless fetch; `classifyLeftovers` filters it
            // again as the tested safety net. Belt and braces on the destructive path.
            guard let id = Self.householdID(fromZoneName: zone.zoneID.zoneName), id != keeping else { continue }
            zoneIDsByHousehold[id] = zone.zoneID
            censused.append((id, await recordCount(db: db, zoneID: zone.zoneID)))
        }

        let outcome = Self.classifyLeftovers(censused, keeping: keeping)
        let toDelete = outcome.deletedHouseholdIDs.compactMap { zoneIDsByHousehold[$0] }
        if !toDelete.isEmpty {
            guard await shouldDelete() else { throw CancellationError() }
            _ = try await db.modifyRecordZones(saving: [], deleting: toDelete)
        }
        return outcome
    }

    /// Factory reset (SP-C clean-slate, spec §2): the household ids whose zones a
    /// delete-ALL pass targets — EVERY `household-*` zone, with no `keeping` and no
    /// record-count filter (the difference from `deleteEmptyHouseholdZones`). Pure +
    /// headlessly testable: feed it a zone-name list, get back the targeted ids sorted.
    /// `_defaultZone`, `catalog-public`, and any non-`household-*` zone parse to nil and
    /// are dropped.
    static func householdZoneIDsToDelete(from zoneNames: [String]) -> [String] {
        zoneNames.compactMap { householdID(fromZoneName: $0) }.sorted()
    }

    /// Factory reset (SP-C clean-slate, spec §2): delete EVERY `household-*` zone in the
    /// private DB — no `keeping`, no ≤1-record filter (mirror of `deleteEmptyHouseholdZones`
    /// minus the guards). Returns the deleted ids (sorted). Destructive: the caller wipes
    /// before re-minting one fresh household and re-importing from Fly.
    @discardableResult
    public func deleteAllHouseholdZones() async throws -> [String] {
        let db = container.privateCloudDatabase
        let zones = try await db.allRecordZones()
        var toDelete: [CKRecordZone.ID] = []
        var deletedIDs: [String] = []
        for zone in zones {
            guard Self.householdID(fromZoneName: zone.zoneID.zoneName) != nil else { continue }
            toDelete.append(zone.zoneID)
            deletedIDs.append(zone.zoneID.zoneName)
        }
        if !toDelete.isEmpty {
            _ = try await db.modifyRecordZones(saving: [], deleting: toDelete)
        }
        return deletedIDs.compactMap { Self.householdID(fromZoneName: $0) }.sorted()
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
