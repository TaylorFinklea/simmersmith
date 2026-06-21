#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync
import CloudKitProvisioning

// SP-C Task 5 — AliasRepository: household term-alias CRUD over the CloudKit household store.
// Mirrors RecipeRepository's structure: LWW upsert, storeRevision observer, drainSync.
//
// .householdTermAlias uses `namePolicy .det` — the recordName is deterministic:
//   RecordNames.termAlias(term: term)   →   "alias:<normalized_term>"
//
// Concurrent creates of the same term collapse to one record (det-key idempotency).
// The `term` field is therefore immutable after creation — renaming a term requires
// delete + re-add. The `expansion` and `notes` fields are mutable.

@MainActor
@Observable
final class AliasRepository {

    // MARK: - Observable state

    private(set) var aliases: [HouseholdTermAlias] = []

    /// Set when `sendUntilDrained()` fails on any write path (mirrors RecipeRepository).
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Observe storeRevision

    func startObserving() {
        observeRevision()
    }

    private func observeRevision() {
        withObservationTracking {
            _ = session.storeRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
                self?.observeRevision()
            }
        }
    }

    // MARK: - Read

    /// Recompute `aliases` from the local store. Gathers all `.householdTermAlias` records,
    /// maps each to a `HouseholdTermAlias`, and sorts by term (case-insensitive).
    func reload() {
        let store = session.store
        let records = store.records(ofType: HouseholdRecordType.householdTermAlias.recordTypeName)

        var result: [HouseholdTermAlias] = []
        result.reserveCapacity(records.count)
        for record in records {
            if let alias = decodeAlias(record) {
                result.append(alias)
            }
        }
        result.sort { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        aliases = result
    }

    // MARK: - CRUD

    /// Add or update a term alias. The recordName is det-keyed on `term`, so concurrent
    /// creates of the same term collapse to one record (upsert semantics). Returns the
    /// aliasId (which equals the det-keyed recordName).
    @discardableResult
    func upsertAlias(term: String, expansion: String, notes: String = "") -> String {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTerm.isEmpty, !expansion.isEmpty else { return "" }

        let recordName = RecordNames.termAlias(term: normalizedTerm)
        let now = Date()
        let value = HouseholdRecordValue(
            type: .householdTermAlias,
            recordName: recordName,
            scalars: [
                "term":      .string(normalizedTerm),
                "expansion": .string(expansion),
                "notes":     .string(notes),
                "createdAt": .date(now),
                "updatedAt": .date(now),
            ],
            refs: [:]
        )
        upsertRecord(value)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return recordName
    }

    /// Update only the `expansion` (and optionally `notes`) of an existing alias.
    /// No-op if the alias is not in the store (call `upsertAlias` to create one).
    func updateAlias(aliasId: String, expansion: String, notes: String? = nil) {
        let id = CKRecord.ID(recordName: aliasId, zoneID: session.zoneID)
        guard let existing = session.store.record(for: id) else { return }
        existing["expansion"] = expansion as CKRecordValue
        if let n = notes { existing["notes"] = n as CKRecordValue }
        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    /// Delete a term alias by its aliasId (the det-keyed recordName). Hard-deletes the
    /// CloudKit record — there is no soft-delete for aliases.
    func deleteAlias(aliasId: String) {
        let id = CKRecord.ID(recordName: aliasId, zoneID: session.zoneID)
        session.engine.delete(id)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    // MARK: - Write helpers

    private func upsertRecord(_ value: HouseholdRecordValue) {
        let id = CKRecord.ID(recordName: value.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            let fieldTypes = Dictionary(uniqueKeysWithValues: value.type.fields.map { ($0.name, $0.type) })
            for (name, scalar) in value.scalars {
                guard fieldTypes[name] != nil else { continue }
                existing[name] = ckValue(for: scalar)
            }
            session.engine.save(existing)
        } else {
            session.engine.save(HouseholdRecordCodec.encode(value, zoneID: session.zoneID))
        }
    }

    private func ckValue(for scalar: ScalarValue) -> CKRecordValue {
        switch scalar {
        case .string(let v): return v as CKRecordValue
        case .int(let v):    return v as CKRecordValue
        case .double(let v): return v as CKRecordValue
        case .date(let v):   return v as CKRecordValue
        case .bool(let v):   return (v ? 1 : 0) as CKRecordValue
        }
    }

    private func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[AliasRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }

    // MARK: - Record → domain mapping

    private func decodeAlias(_ record: CKRecord) -> HouseholdTermAlias? {
        let aliasId = record.recordID.recordName
        guard !aliasId.isEmpty else { return nil }
        let term = record["term"] as? String ?? ""
        let expansion = record["expansion"] as? String ?? ""
        guard !term.isEmpty else { return nil }

        return HouseholdTermAlias(
            aliasId: aliasId,
            term: term,
            expansion: expansion,
            notes: record["notes"] as? String ?? "",
            updatedAt: record["updatedAt"] as? Date ?? Date()
        )
    }
}
#endif
