#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync
import GroceryMerge

// SP-C Task 5 — PantryRepository: pantry CRUD + apply-recurrings over the CloudKit household
// store. Mirrors RecipeRepository's structure: LWW upsert, storeRevision observer, drainSync.
//
// PantryItem (.pantryItem, namePolicy .pk) has no children — it is a flat top-level record.
// Deletes are soft (isActive=false) by default; cascade-delete is explicit and separate.
//
// applyPantryToCurrentWeek: folds recurring pantry items (cadence != "none" AND isActive)
// into the current week's grocery list via the GroceryRepository. For each such item:
//   - if a non-tombstoned grocery row with a matching normalizedName already exists for the
//     week, skip (dedupe by normalizedName);
//   - otherwise insert a new user-added row (isUserAdded = true) carrying the item's
//     recurringQuantity / recurringUnit / category.
// After folding, bumps lastAppliedAt on each applied item so the caller can observe it.
// No meal-regen is triggered — recurring pantry rows are `isUserAdded` and therefore
// untouched by regen (grocery.py:519-522 / GroceryGenerator invariant).
//
// The "pantry-recurring folding" comment in GroceryGenerator.regenerate documents that the
// port omitted the grocery.py:573-575 server path on purpose. This method fills that gap
// for on-device apply.
//
// Headless test note (mirrors RecipeRepository): HouseholdSyncEngine requires iCloud — no
// in-process headless test. Verified on-device (spec §5).

@MainActor
@Observable
final class PantryRepository {

    // MARK: - Observable state

    private(set) var pantryItems: [PantryItem] = []

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

    /// Recompute `pantryItems` from the local store. Gathers all `.pantryItem` records,
    /// maps each to a `PantryItem`, and sorts by stapleName (case-insensitive).
    func reload() {
        let store = session.store
        let records = store.records(ofType: HouseholdRecordType.pantryItem.recordTypeName)

        var result: [PantryItem] = []
        result.reserveCapacity(records.count)
        for record in records {
            if let item = decodeItem(record) {
                result.append(item)
            }
        }
        result.sort { $0.stapleName.localizedCaseInsensitiveCompare($1.stapleName) == .orderedAscending }
        pantryItems = result
    }

    // MARK: - CRUD

    /// Load pantry items from the local store (alias for `reload()` — named to mirror
    /// the legacy `AppState.loadPantryItems` call site).
    func loadPantryItems() {
        reload()
    }

    /// Add a new pantry item. Returns the new item's pantryItemId.
    @discardableResult
    func addPantryItem(
        stapleName: String,
        normalizedName: String = "",
        notes: String = "",
        isActive: Bool = true,
        typicalQuantity: Double? = nil,
        typicalUnit: String = "",
        recurringQuantity: Double? = nil,
        recurringUnit: String = "",
        recurringCadence: String = "none",
        category: String = "",
        categories: [String] = [],
        frozenAt: Date? = nil
    ) -> String {
        let pantryItemId = UUID().uuidString
        let now = Date()
        let normalizedFinal = normalizedName.isEmpty
            ? stapleName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : normalizedName
        let categoriesSerialized = serializeCategories(categories)
        var scalars: [String: ScalarValue] = [
            "stapleName": .string(stapleName),
            "normalizedName": .string(normalizedFinal),
            "notes": .string(notes),
            "isActive": .bool(isActive),
            "typicalUnit": .string(typicalUnit),
            "recurringUnit": .string(recurringUnit),
            "recurringCadence": .string(recurringCadence),
            "category": .string(category),
            "categories": .string(categoriesSerialized),
            "createdAt": .date(now),
            "updatedAt": .date(now),
        ]
        if let q = typicalQuantity   { scalars["typicalQuantity"] = .double(q) }
        if let q = recurringQuantity { scalars["recurringQuantity"] = .double(q) }
        if let d = frozenAt          { scalars["frozenAt"] = .date(d) }

        let value = HouseholdRecordValue(
            type: .pantryItem,
            recordName: pantryItemId,
            scalars: scalars,
            refs: [:]
        )
        upsertRecord(value)
        reload()
        Task { [weak self] in await self?.drainSync() }
        return pantryItemId
    }

    /// Quick-add an ingredient to the pantry. Dedupes by `normalizedName` — skips if
    /// an active pantry item with the same normalized name already exists. Returns `true`
    /// when a new row was created so callers can show "Added to pantry" feedback.
    @discardableResult
    func quickAddIngredientToPantry(
        name: String,
        category: String = "",
        unit: String = "",
        normalizedNameHint: String = ""
    ) -> Bool {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return false }
        let normalized = normalizedNameHint.isEmpty
            ? cleanedName.lowercased()
            : normalizedNameHint.lowercased()

        // Reload from store first so we dedupe against the latest in-memory state.
        reload()

        let alreadyExists = pantryItems.contains(where: {
            $0.normalizedName.lowercased() == normalized
                || $0.stapleName.lowercased() == cleanedName.lowercased()
        })
        guard !alreadyExists else { return false }

        addPantryItem(
            stapleName: cleanedName,
            normalizedName: normalized,
            category: category,
            categories: category.isEmpty ? [] : [category]
        )
        return true
    }

    /// Patch a pantry item's fields. Only non-nil patch values are applied.
    func patchPantryItem(
        itemID: String,
        stapleName: String? = nil,
        normalizedName: String? = nil,
        notes: String? = nil,
        isActive: Bool? = nil,
        typicalQuantity: FieldPatch<Double>? = nil,
        typicalUnit: String? = nil,
        recurringQuantity: FieldPatch<Double>? = nil,
        recurringUnit: String? = nil,
        recurringCadence: String? = nil,
        category: String? = nil,
        categories: [String]? = nil,
        lastAppliedAt: Date? = nil,
        frozenAt: FieldPatch<Date>? = nil
    ) {
        let id = CKRecord.ID(recordName: itemID, zoneID: session.zoneID)
        guard let existing = session.store.record(for: id) else { return }
        if let v = stapleName       { existing["stapleName"] = v as CKRecordValue }
        if let v = normalizedName   { existing["normalizedName"] = v as CKRecordValue }
        if let v = notes            { existing["notes"] = v as CKRecordValue }
        if let v = isActive         { existing["isActive"] = (v ? 1 : 0) as CKRecordValue }
        if let v = typicalUnit      { existing["typicalUnit"] = v as CKRecordValue }
        if let v = recurringUnit    { existing["recurringUnit"] = v as CKRecordValue }
        if let v = recurringCadence { existing["recurringCadence"] = v as CKRecordValue }
        if let v = category         { existing["category"] = v as CKRecordValue }
        if let v = categories       { existing["categories"] = serializeCategories(v) as CKRecordValue }
        if let v = lastAppliedAt    { existing["lastAppliedAt"] = v as CKRecordValue }

        switch typicalQuantity {
        case .set(let v): existing["typicalQuantity"] = v as CKRecordValue
        case .clear:      existing["typicalQuantity"] = nil
        case nil: break
        }
        switch recurringQuantity {
        case .set(let v): existing["recurringQuantity"] = v as CKRecordValue
        case .clear:      existing["recurringQuantity"] = nil
        case nil: break
        }
        switch frozenAt {
        case .set(let v): existing["frozenAt"] = v as CKRecordValue
        case .clear:      existing["frozenAt"] = nil
        case nil: break
        }

        existing["updatedAt"] = Date() as CKRecordValue
        session.engine.save(existing)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    /// Soft-delete: sets `isActive = false` (the item stays in the store — it is
    /// still visible to the migration and to "Freezer" or archived views). Use
    /// `hardDeletePantryItem` when you need to permanently remove the record.
    func deletePantryItem(itemID: String) {
        patchPantryItem(itemID: itemID, isActive: false)
    }

    /// Hard-delete: permanently removes the CloudKit record for the given item.
    func hardDeletePantryItem(itemID: String) {
        let id = CKRecord.ID(recordName: itemID, zoneID: session.zoneID)
        session.engine.delete(id)
        reload()
        Task { [weak self] in await self?.drainSync() }
    }

    // MARK: - Apply recurrings to grocery

    /// Fold the household's recurring pantry items (cadence != "none", isActive = true) into
    /// the given week's grocery list via the GroceryRepository. Skips items whose
    /// normalizedName already appears in the week's live grocery rows (non-tombstoned).
    /// Returns the record names of items that were actually folded in so callers can update
    /// `lastAppliedAt` on each.
    ///
    /// Call site: AppState.applyPantryToCurrentWeek() passes the current weekID and the
    /// GroceryRepository.
    @discardableResult
    func applyPantryToCurrentWeek(
        weekID: String,
        groceryRepository: GroceryRepository
    ) -> [String] {
        // Gather existing live (non-tombstoned, non-user-removed) grocery rows for this week.
        let existingNormalizedNames = Set(
            session.store
                .records(ofType: GroceryCodec.recordType)
                .filter {
                    ($0["weekID"] as? String) == weekID
                        && ($0["isUserRemoved"] as? Int ?? 0) == 0
                }
                .compactMap { $0["normalizedName"] as? String }
                .map { $0.lowercased() }
        )

        let recurringItems = pantryItems.filter {
            $0.isActive && $0.recurringCadence != "none"
        }

        var appliedIDs: [String] = []

        for item in recurringItems {
            let normalized = item.normalizedName.lowercased()
            // Dedupe: skip if any existing grocery row already carries this name.
            guard !existingNormalizedNames.contains(normalized) else { continue }

            groceryRepository.addItem(
                weekID: weekID,
                name: item.stapleName,
                quantity: item.recurringQuantity,
                unit: item.recurringUnit,
                notes: item.notes,
                category: item.category
            )
            appliedIDs.append(item.pantryItemId)
        }

        // Stamp lastAppliedAt on each item that was folded in.
        let now = Date()
        for id in appliedIDs {
            patchPantryItem(itemID: id, lastAppliedAt: now)
        }

        return appliedIDs
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
            print("[PantryRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }

    // MARK: - Record → domain mapping

    private func decodeItem(_ record: CKRecord) -> PantryItem? {
        let id = record.recordID.recordName
        guard !id.isEmpty else { return nil }
        let stapleName = record["stapleName"] as? String ?? ""
        guard !stapleName.isEmpty else { return nil }

        let categoriesRaw = record["categories"] as? String ?? ""
        let categories = deserializeCategories(categoriesRaw)

        return PantryItem(
            pantryItemId: id,
            stapleName: stapleName,
            normalizedName: record["normalizedName"] as? String ?? "",
            notes: record["notes"] as? String ?? "",
            isActive: (record["isActive"] as? Int ?? 1) != 0,
            typicalQuantity: record["typicalQuantity"] as? Double,
            typicalUnit: record["typicalUnit"] as? String ?? "",
            recurringQuantity: record["recurringQuantity"] as? Double,
            recurringUnit: record["recurringUnit"] as? String ?? "",
            recurringCadence: record["recurringCadence"] as? String ?? "none",
            category: record["category"] as? String ?? "",
            categories: categories,
            lastAppliedAt: record["lastAppliedAt"] as? Date,
            frozenAt: record["frozenAt"] as? Date,
            updatedAt: record["updatedAt"] as? Date ?? Date()
        )
    }

    // MARK: - Categories serialization (mirrors Recipe.tags JSON-array style)

    /// Serialize [String] → JSON array string ("[]" for empty).
    private func serializeCategories(_ categories: [String]) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: categories), encoding: .utf8)) ?? "[]"
    }

    /// Deserialize JSON array string → [String]. Falls back to splitting on commas
    /// (back-compat with legacy single-string `category` rows that were never migrated).
    private func deserializeCategories(_ raw: String) -> [String] {
        guard !raw.isEmpty, raw != "[]" else { return [] }
        if let data = raw.data(using: .utf8),
           let list = try? JSONSerialization.jsonObject(with: data) as? [String] {
            return list
        }
        // Comma-split fallback for old-format rows.
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: - Patch enum

    /// A two-state patch for an optional field: set a new value, or clear it (nil).
    enum FieldPatch<Value> {
        case set(Value)
        case clear
    }
}
#endif
