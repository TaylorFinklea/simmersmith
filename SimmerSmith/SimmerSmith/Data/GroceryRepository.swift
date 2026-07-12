#if canImport(CloudKit)
import CloudKit
import Foundation
import Observation
import SimmerSmithKit
import HouseholdRecords
import HouseholdSync
import GroceryMerge

// SP-C Task 3 — GroceryRepository: grocery CRUD + check-state + regen + dedupe over the
// CloudKit household store.
//
// Mirrors RecipeRepository's structure. GroceryItem is NOT a manifest record type — it has its
// own GroceryCodec (encode-into-existing preserves the server change tag), and the household
// session's DispatchingMerger already carries GrocerySyncMerger, so concurrent peer edits resolve
// automatically on engine.save. This repository therefore just upserts via the codec and lets the
// merger do conflict resolution — it does NOT add a merger of its own.
//
// Three load-bearing flows beyond plain CRUD:
//
//   - CHECK-STATE (household-shared): toggleChecked flips the `isChecked` field (+ checkedAtClock /
//     checkedBy) and saves. The GrocerySyncMerger resolves the (isChecked, at, by) triple as ONE
//     unit by the check clock, so a household member's toggle on a 2nd engine converges correctly.
//
//   - REGEN (on meal change): regenerate(weekID:) builds the week's [GroceryMeal] from its
//     .weekMeal records (each meal's recipe ingredients resolved from the store's .recipeIngredient
//     records, scaled by the meal's factor), folds the EXISTING grocery rows in via
//     GroceryGenerator.regenerate (T1) — which preserves ALL sticky user state (overrides, checks,
//     tombstones, eventQuantity, storeLabel) — and writes the upserts/tombstones through the engine.
//     Each upsert goes through GroceryCodec into the existing record (change-tag-preserving), so the
//     field-merge resolver covers any concurrent peer edit. Tombstones from regen are auto rows with
//     no remaining attribution → hard engine.delete.
//
//   - DEDUPE: dedupe(weekID:) delegates to EventMergeAdapter.dedupeWeekGrocery, which runs the pure
//     ConflictRepair.dedupeGrocery (tombstones losers, never hard-deletes) and saves the result back
//     through the engine.
//
// lastSyncError mirrors RecipeRepository — surfaced for a sync-error banner / retry.

@MainActor
@Observable
final class GroceryRepository {

    // MARK: - Observable state

    /// Set when `sendUntilDrained()` fails on any write path (mirrors RecipeRepository).
    private(set) var lastSyncError: Error?

    // MARK: - Plumbing

    private let session: HouseholdSession

    /// Monotonic logical clock for new/refreshed grocery rows + check stamps. GroceryItem stores
    /// clocks as Int (server change-tag stand-in). Seeded from the wall clock so it advances across
    /// launches, then bumped per write so ordering within a session is strict.
    private var clock: SyncClock

    // MARK: - Init

    init(session: HouseholdSession) {
        self.session = session
        self.clock = Int(Date().timeIntervalSince1970)
    }

    private func nextClock() -> SyncClock {
        clock = max(clock + 1, Int(Date().timeIntervalSince1970))
        return clock
    }

    // MARK: - Read

    /// All non-removed grocery rows for a week (domain shape), as the GroceryGenerator/merge value
    /// type. Used internally by regen; the snapshot's grocery list is assembled by WeekRepository.
    private func mergeRows(weekID: String) -> [GroceryMerge.GroceryItem] {
        session.store.records(ofType: GroceryCodec.recordType)
            .filter { ($0["weekID"] as? String) == weekID }
            .map(GroceryCodec.decode)
    }

    // MARK: - CRUD

    /// Insert a user-added item (`isUserAdded` — regen never touches these). Returns the new row's
    /// record name.
    @discardableResult
    func addItem(
        weekID: String,
        name: String,
        quantity: Double? = nil,
        unit: String = "",
        notes: String = "",
        category: String = "",
        storeLabel: String = ""
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = nextClock()
        let item = GroceryMerge.GroceryItem(
            recordName: UUID().uuidString,
            weekID: weekID,
            resolutionStatus: "unresolved",
            unit: GroceryNormalize.unit(unit),
            normalizedName: GroceryNormalize.name(trimmed),
            ingredientName: trimmed,
            category: category,
            totalQuantity: quantity,
            notes: notes,
            storeLabel: storeLabel,
            isUserAdded: true,
            createdAt: now,
            modifiedAt: now
        )
        saveItem(item)
        finishWrite()
        return item.recordName
    }

    /// Edit a row's user-override fields. `.set` writes the override, `.clear` reverts it (the
    /// auto-aggregated base value stays so the UI can show "you overrode X → Y"). nil = no change.
    func editItem(
        weekID: String,
        itemID: String,
        quantity: FieldPatch<Double>? = nil,
        unit: FieldPatch<String>? = nil,
        notes: FieldPatch<String>? = nil
    ) {
        guard var item = item(weekID: weekID, itemID: itemID) else { return }
        switch quantity {
        case .set(let v): item.quantityOverride = v
        case .clear: item.quantityOverride = nil
        case nil: break
        }
        switch unit {
        case .set(let v): item.unitOverride = v
        case .clear: item.unitOverride = nil
        case nil: break
        }
        switch notes {
        case .set(let v): item.notesOverride = v
        case .clear: item.notesOverride = nil
        case nil: break
        }
        item.modifiedAt = nextClock()
        saveItem(item)
        finishWrite()
    }

    @discardableResult
    func linkIngredient(
        weekID: String,
        itemID: String,
        baseIngredientID: String,
        canonicalName: String
    ) -> GroceryMerge.GroceryItem? {
        guard !baseIngredientID.isEmpty,
              var item = item(weekID: weekID, itemID: itemID) else { return nil }
        guard item.weekID == weekID else { return nil }
        let cleanedName = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return nil }
        clock = max(clock, item.modifiedAt)
        item.baseIngredientID = baseIngredientID
        item.ingredientVariationID = nil
        item.resolutionStatus = "locked"
        item.reviewFlag = ""
        item.normalizedName = GroceryNormalize.name(cleanedName)
        if !item.isUserAdded { item.ingredientName = cleanedName }
        item.modifiedAt = nextClock()
        saveItem(item)
        finishWrite()
        return item
    }

    /// Soft-remove (tombstone) a row — `isUserRemoved=true`, monotonic. Regen never resurrects it.
    func removeItem(weekID: String, itemID: String) {
        guard var item = item(weekID: weekID, itemID: itemID) else { return }
        item.isUserRemoved = true
        item.modifiedAt = nextClock()
        saveItem(item)
        finishWrite()
    }

    /// Restore a tombstoned row (clears `isUserRemoved`).
    func restoreItem(weekID: String, itemID: String) {
        guard var item = item(weekID: weekID, itemID: itemID) else { return }
        item.isUserRemoved = false
        item.modifiedAt = nextClock()
        saveItem(item)
        finishWrite()
    }

    /// Set or clear the per-item store label (empty string clears it). LWW pass-through.
    func setStoreLabel(weekID: String, itemID: String, storeLabel: String) {
        guard var item = item(weekID: weekID, itemID: itemID) else { return }
        item.storeLabel = storeLabel
        item.modifiedAt = nextClock()
        saveItem(item)
        finishWrite()
    }

    // MARK: - Check state (household-shared via the field-merge)

    /// Toggle a row's checked state. Stamps the check clock + actor so the GrocerySyncMerger can
    /// resolve the (isChecked, at, by) triple as one unit against a concurrent peer toggle. The
    /// check resolves household-wide because the merger is in the session's DispatchingMerger seam.
    func toggleChecked(weekID: String, itemID: String, checkedBy: String? = nil) {
        guard var item = item(weekID: weekID, itemID: itemID) else { return }
        let now = nextClock()
        item.check = CheckState(isChecked: !item.check.isChecked, at: now, by: checkedBy)
        item.modifiedAt = now
        saveItem(item)
        finishWrite()
    }

    // MARK: - Regen (on meal change) — the load-bearing port wiring (T1)

    /// Regenerate the week's auto grocery rows from its meals, preserving all sticky user state.
    /// Builds [GroceryMeal] from the store's .weekMeal records (recipe ingredients resolved +
    /// scaled), folds the existing rows in via GroceryGenerator.regenerate, then writes the result:
    /// upserts via GroceryCodec (change-tag-preserving → field-merge handles concurrent peers),
    /// tombstones (auto rows with no remaining attribution) via hard engine.delete.
    func regenerate(weekID: String) {
        let meals = groceryMeals(weekID: weekID)
        let existing = mergeRows(weekID: weekID)
        let result = GroceryGenerator.regenerate(
            meals: meals,
            existing: existing,
            weekID: weekID,
            clock: nextClock()
        )
        for item in result.upserts { saveItem(item) }
        for tombstone in result.tombstones {
            session.engine.delete(CKRecord.ID(recordName: tombstone.recordName, zoneID: session.zoneID))
        }
        finishWrite()
    }

    // MARK: - Dedupe (post-batch / on demand)

    /// Collapse duplicate grocery rows on a week. Delegates to EventMergeAdapter.dedupeWeekGrocery,
    /// which runs the pure ConflictRepair.dedupeGrocery (losers are TOMBSTONED, never hard-deleted)
    /// and saves the corrected set back through the engine.
    @discardableResult
    func dedupe(weekID: String) -> ConflictRepair.GroceryDedupeResult {
        let adapter = EventMergeAdapter(engine: session.engine, zoneID: session.zoneID)
        let eventLinks = session.store.records(ofType: EventGroceryCodec.recordType)
            .map(EventGroceryCodec.decode)
            .filter { $0.mergedIntoWeekID == weekID }
        let result = adapter.dedupeWeekGrocery(weekID: weekID, eventLinks: eventLinks)
        finishWrite()
        return result
    }

    /// A three-state patch for an overridable field: set, clear (revert), or no change.
    enum FieldPatch<Value> {
        case set(Value)
        case clear
    }

    // MARK: - Build [GroceryMeal] from the store (regen input)

    /// Assemble the week's meals into the GroceryGenerator input. For each .weekMeal record:
    ///   - recipe-backed: ingredients come from the recipe's .recipeIngredient records; baseServings
    ///     is the recipe's `servings` scalar (drives the scale factor alongside the meal's
    ///     scaleMultiplier / servings).
    ///   - inline (no recipe): no ingredient records → contributes nothing (matches the server,
    ///     which has no inline-meal ingredient source on-device).
    /// Each meal's recipe-backed sides resolve the same way from the side's recipe.
    private func groceryMeals(weekID: String) -> [GroceryMeal] {
        let store = session.store

        // Index recipe-ingredient records by their recipe ref once.
        var ingredientsByRecipe: [String: [GroceryIngredientLine]] = [:]
        for rec in store.records(ofType: HouseholdRecordType.recipeIngredient.recordTypeName) {
            let value = HouseholdRecordCodec.decode(rec, as: .recipeIngredient)
            guard let recipeID = value.refs["recipe"] else { continue }
            ingredientsByRecipe[recipeID, default: []].append(line(from: value))
        }

        // Index recipe servings (baseServings) by recipe record name.
        var servingsByRecipe: [String: Double] = [:]
        for rec in store.records(ofType: HouseholdRecordType.recipe.recordTypeName) {
            if let s = rec["servings"] as? Double {
                servingsByRecipe[rec.recordID.recordName] = s
            }
        }

        // Sides grouped by their parent weekMeal ref.
        var sideRecsByMeal: [String: [CKRecord]] = [:]
        for rec in store.records(ofType: HouseholdRecordType.weekMealSide.recordTypeName) {
            let mealID = refName(rec["weekMeal"])
            guard !mealID.isEmpty else { continue }
            sideRecsByMeal[mealID, default: []].append(rec)
        }

        let mealRecs = store.records(ofType: HouseholdRecordType.weekMeal.recordTypeName)
            .filter { refName($0["week"]) == weekID }

        return mealRecs.map { mealRec in
            let mealID = mealRec.recordID.recordName
            let recipeID = refName(mealRec["recipe"])
            let baseServings = recipeID.isEmpty ? nil : servingsByRecipe[recipeID]
            let ingredients = recipeID.isEmpty ? [] : (ingredientsByRecipe[recipeID] ?? [])

            let sides: [GroceryMealSide] = (sideRecsByMeal[mealID] ?? []).compactMap { sideRec in
                let sideRecipeID = refName(sideRec["recipe"])
                guard !sideRecipeID.isEmpty else { return nil }   // non-recipe side: no grocery
                return GroceryMealSide(
                    name: sideRec["name"] as? String ?? "",
                    baseServings: servingsByRecipe[sideRecipeID],
                    ingredients: ingredientsByRecipe[sideRecipeID] ?? []
                )
            }

            return GroceryMeal(
                dayName: mealRec["dayName"] as? String ?? "",
                slot: mealRec["slot"] as? String ?? "",
                recipeName: mealRec["recipeName"] as? String ?? "",
                scaleMultiplier: mealRec["scaleMultiplier"] as? Double,
                servings: mealRec["servings"] as? Double,
                baseServings: baseServings,
                ingredients: ingredients,
                sides: sides
            )
        }
    }

    /// Map a decoded `.recipeIngredient` record value into a GroceryGenerator input line.
    private func line(from value: HouseholdRecordValue) -> GroceryIngredientLine {
        GroceryIngredientLine(
            ingredientName: scalarString(value, "ingredientName") ?? "",
            normalizedName: scalarString(value, "normalizedName") ?? "",
            unit: scalarString(value, "unit") ?? "",
            quantity: scalarDouble(value, "quantity"),
            quantityText: "",
            category: scalarString(value, "category") ?? "",
            notes: scalarString(value, "notes") ?? "",
            prep: scalarString(value, "prep") ?? "",
            baseIngredientID: value.refs["baseIngredientID"],
            ingredientVariationID: value.refs["ingredientVariationID"],
            resolutionStatus: scalarString(value, "resolutionStatus") ?? "unresolved"
        )
    }

    // MARK: - Item lookup / save

    private func item(weekID: String, itemID: String) -> GroceryMerge.GroceryItem? {
        guard let record = session.store.record(
            for: CKRecord.ID(recordName: itemID, zoneID: session.zoneID)) else { return nil }
        return GroceryCodec.decode(record)
    }

    /// Upsert a GroceryItem, preserving the server change tag when the record already exists (so a
    /// concurrent peer edit resolves via the GrocerySyncMerger instead of a blind overwrite) —
    /// mirrors EventMergeAdapter.saveGrocery.
    private func saveItem(_ item: GroceryMerge.GroceryItem) {
        let id = CKRecord.ID(recordName: item.recordName, zoneID: session.zoneID)
        if let existing = session.store.record(for: id) {
            GroceryCodec.encode(item, into: existing)
            session.engine.save(existing)
        } else {
            session.engine.save(GroceryCodec.makeRecord(item, zoneID: session.zoneID))
        }
    }

    /// Common tail of every mutation: kick the background CloudKit flush. The local store write
    /// already succeeded; WeekRepository's storeRevision observer drives the UI reload.
    private func finishWrite() {
        Task { [weak self] in await self?.drainSync() }
    }

    private func drainSync() async {
        do {
            try await session.engine.sendUntilDrained()
            lastSyncError = nil
        } catch {
            print("[GroceryRepository] sendUntilDrained failed: \(error)")
            lastSyncError = error
        }
    }

    // MARK: - Scalar accessors

    private func refName(_ value: Any?) -> String {
        (value as? CKRecord.Reference)?.recordID.recordName ?? ""
    }

    private func scalarString(_ value: HouseholdRecordValue, _ key: String) -> String? {
        if case let .string(v) = value.scalars[key] { return v }
        return nil
    }

    private func scalarDouble(_ value: HouseholdRecordValue, _ key: String) -> Double? {
        if case let .double(v) = value.scalars[key] { return v }
        return nil
    }
}
#endif
