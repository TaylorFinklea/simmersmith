#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords

// SP-C Task 4b — MetadataRepository: read/write ManagedListItem records via the
// CloudKit household store, presenting them as RecipeMetadata to the app layer.
//
// ManagedListItem is a household record type (user-extensible: cuisines/tags/units).
// recordName policy is .det keyed by (kind, name) — concurrent creates of the same
// logical item collapse to one record. No sort_order or built_in on the backend model.
//
// reloadMetadata() reads all ManagedListItem records from the store and groups them
// by kind into the RecipeMetadata shape the recipe editor consumes.
//
// createManagedListItem(kind:name:) writes a new record via the engine and reloads.
//
// AppState.refreshRecipeMetadata / createManagedListItem are wired to delegate here
// via a TASK 5 marker — AppState doesn't own a HouseholdSession yet.
//
// Construction note: SimmerSmithKit.ManagedListItem has no public memberwise init
// (Swift synthesizes only `internal` for public structs without explicit init), so
// items are built via JSON dict→Decoder round-trip, exactly like RecipeRepository
// does for RecipeSummary.

@MainActor
@Observable
final class MetadataRepository {

    // MARK: - Observable state

    private(set) var metadata: RecipeMetadata?

    /// Set when sendUntilDrained fails. The UI can observe this for a retry banner.
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Observe storeRevision

    /// Wire the revision observer via `ObservationReloader` (simmersmith-7mb) — re-registers
    /// before each reload so a bump during an in-flight reload is never missed.
    @ObservationIgnored
    private lazy var revisionReloader = ObservationReloader(
        track: { [weak self] in _ = self?.session.storeRevision },
        reload: { [weak self] in self?.reloadMetadata() }
    )

    func startObserving() {
        revisionReloader.start()
    }

    // MARK: - Read

    /// Read all ManagedListItem records from the local store, group by kind, and publish
    /// as RecipeMetadata. Missing kinds default to empty arrays.
    func reloadMetadata() {
        let store = session.store
        let records = store.records(ofType: HouseholdRecordType.managedListItem.recordTypeName)

        // Build item dicts for JSON decoding (SimmerSmithKit.ManagedListItem has no public
        // memberwise init — use the Codable key names from SimmerSmithModels.swift).
        var cuisineDicts: [[String: Any]] = []
        var tagDicts:     [[String: Any]] = []
        var unitDicts:    [[String: Any]] = []

        let iso = ISO8601DateFormatter()

        for record in records {
            let value = HouseholdRecordCodec.decode(record, as: .managedListItem)
            guard
                case .string(let kind) = value.scalars["kind"],
                case .string(let name) = value.scalars["name"]
            else { continue }

            let normalizedName: String
            if case .string(let n) = value.scalars["normalizedName"] {
                normalizedName = n
            } else {
                normalizedName = name.lowercased()
                    .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            }

            let updatedAtStr: String
            if case .date(let d) = value.scalars["updatedAt"] {
                updatedAtStr = iso.string(from: d)
            } else {
                updatedAtStr = iso.string(from: Date.distantPast)
            }

            // CodingKeys from SimmerSmithModels: itemId, kind, name, normalizedName, updatedAt
            let dict: [String: Any] = [
                "itemId": value.recordName,
                "kind": kind,
                "name": name,
                "normalizedName": normalizedName,
                "updatedAt": updatedAtStr,
            ]

            switch kind {
            case "cuisine": cuisineDicts.append(dict)
            case "tag":     tagDicts.append(dict)
            case "unit":    unitDicts.append(dict)
            default:        break   // forward-compat: unknown kinds ignored
            }
        }

        // Sort each group by name (matches the API path sort order).
        let byName: (Any, Any) -> Bool = {
            ($0 as? [String: Any])?["name"] as? String ?? "" <
            ($1 as? [String: Any])?["name"] as? String ?? ""
        }
        cuisineDicts.sort(by: byName)
        tagDicts.sort(by: byName)
        unitDicts.sort(by: byName)

        // Decode into RecipeMetadata via JSON round-trip.
        let outerDict: [String: Any] = [
            "cuisines": cuisineDicts,
            "tags": tagDicts,
            "units": unitDicts,
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: outerDict),
            let result = try? decoder.decode(RecipeMetadata.self, from: data)
        else { return }

        metadata = result
    }

    // MARK: - Write

    /// Create a new ManagedListItem record (kind must be "cuisine", "tag", or "unit").
    /// Returns the item as seen by the local store after the write.
    @discardableResult
    func createManagedListItem(kind: String, name: String) throws -> ManagedListItem {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else {
            throw MetadataRepositoryError.emptyName
        }
        let normalizedName = cleaned.lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let recordName = RecordNames.managedListItem(kind: kind, name: cleaned)

        // Upsert: if the record already exists, encode into it (preserves change tag).
        let id = CKRecord.ID(recordName: recordName, zoneID: session.zoneID)
        let now = Date()

        if let existing = session.store.record(for: id) {
            existing["kind"] = kind as CKRecordValue
            existing["name"] = cleaned as CKRecordValue
            existing["normalizedName"] = normalizedName as CKRecordValue
            existing["updatedAt"] = now as CKRecordValue
            session.engine.save(existing)
        } else {
            let value = HouseholdRecordValue(
                type: .managedListItem,
                recordName: recordName,
                scalars: [
                    "kind": .string(kind),
                    "name": .string(cleaned),
                    "normalizedName": .string(normalizedName),
                    "createdAt": .date(now),
                    "updatedAt": .date(now),
                ],
                refs: [:]
            )
            session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }

        reloadMetadata()
        Task { [weak self] in await self?.drainSync() }

        // Decode the returned item via JSON (no public memberwise init on the Kit type).
        let iso = ISO8601DateFormatter()
        let itemDict: [String: Any] = [
            "itemId": recordName,
            "kind": kind,
            "name": cleaned,
            "normalizedName": normalizedName,
            "updatedAt": iso.string(from: now),
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: itemDict),
            let item = try? decoder.decode(ManagedListItem.self, from: data)
        else {
            throw MetadataRepositoryError.decodingFailed
        }
        return item
    }

    // MARK: - Sync drain

    private func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[MetadataRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }
}

enum MetadataRepositoryError: Error {
    case emptyName
    case decodingFailed
}
#endif
