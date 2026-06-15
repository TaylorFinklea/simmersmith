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
