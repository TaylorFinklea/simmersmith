import Foundation

/// One device's local store plus the ported smart-merge. Every write stamps a
/// fresh value from the shared `ClockSource` so the `SyncFabric` can order
/// concurrent writes the way CloudKit's server would.
public final class Replica {
    public let name: String
    private var items: [String: GroceryItem] = [:]
    private let clock: ClockSource

    public init(name: String, clock: ClockSource) {
        self.name = name
        self.clock = clock
    }

    public func snapshot() -> [String: GroceryItem] { items }
    public func load(_ store: [String: GroceryItem]) { items = store }

    // MARK: - User mutations (each bumps modifiedAt)

    /// Tombstone an item — the iOS Grocery view hides `is_user_removed` rows but
    /// regen keeps them so a removed-yet-still-in-a-meal item stays removed.
    public func removeItem(_ id: String) {
        guard var i = items[id] else { return }
        i.isUserRemoved = true
        i.modifiedAt = clock.next()
        items[id] = i
    }

    public func setQuantityOverride(_ id: String, _ value: Double) {
        guard var i = items[id] else { return }
        i.quantityOverride = value
        i.modifiedAt = clock.next()
        items[id] = i
    }

    public func setChecked(_ id: String, _ value: Bool) {
        guard var i = items[id] else { return }
        i.isChecked = value
        i.modifiedAt = clock.next()
        items[id] = i
    }

    /// Stand-in for `merge_event_into_week`: stamps the event contribution.
    public func setEventQuantity(_ id: String, _ value: Double, sourceMeals: String? = nil) {
        guard var i = items[id] else { return }
        i.eventQuantity = value
        if let sourceMeals { i.sourceMeals = sourceMeals }
        i.modifiedAt = clock.next()
        items[id] = i
    }

    // MARK: - The ported smart-merge

    /// Faithful port of `regenerate_grocery_for_week` (app/services/grocery.py:500):
    /// classify each existing row as untouchable / matched-refresh / tombstone-keep
    /// / stale-delete, preserving user-added rows, removed-item tombstones, override
    /// fields, check state, and event contributions. Runs against THIS replica's
    /// local store only — the concurrency hazard is that another replica's
    /// not-yet-synced edit is invisible here.
    public func regenerate(freshRows: [FreshRow]) {
        let existing = Array(items.values)

        var untouchableKeys = Set<MergeKey>()
        for item in existing where item.isUserAdded || item.isEventOnly {
            untouchableKeys.insert(item.mergeKey)
        }

        var eligibleByKey: [MergeKey: String] = [:]
        for item in existing where !(item.isUserAdded || item.isEventOnly) {
            eligibleByKey[item.mergeKey] = item.id
        }

        var matchedKeys = Set<MergeKey>()
        for row in freshRows {
            let key = row.mergeKey
            if untouchableKeys.contains(key) { continue }
            if let id = eligibleByKey[key], var item = items[id] {
                matchedKeys.insert(key)
                if item.isUserRemoved { continue }     // tombstone — leave as-is
                applyFresh(&item, row)
                item.modifiedAt = clock.next()         // regen "touches" the record
                items[id] = item
            } else {
                var fresh = newItem(from: row)
                fresh.modifiedAt = clock.next()
                items[fresh.id] = fresh
            }
        }

        for (key, id) in eligibleByKey where !matchedKeys.contains(key) {
            guard var item = items[id] else { continue }
            if item.isUserRemoved { continue }         // tombstone stays
            if let eq = item.eventQuantity, eq > 0 {   // keep event portion, drop week portion
                item.totalQuantity = nil
                item.reviewFlag = ""
                item.modifiedAt = clock.next()
                items[id] = item
                continue
            }
            if item.hasUserInvestment {
                if item.reviewFlag.isEmpty { item.reviewFlag = "no longer in any meal" }
                item.modifiedAt = clock.next()
                items[id] = item
                continue
            }
            items.removeValue(forKey: id)              // stale auto row → delete
        }
    }

    /// Mirrors `_apply_fresh_to_existing` (grocery.py:375): an override field
    /// shields the corresponding auto value from being overwritten.
    private func applyFresh(_ item: inout GroceryItem, _ row: FreshRow) {
        if item.quantityOverride == nil { item.totalQuantity = row.totalQuantity }
        if item.unitOverride == nil { item.unit = row.unit }
        item.quantityText = row.quantityText
        item.sourceMeals = row.sourceMeals
        item.reviewFlag = row.reviewFlag
        item.baseIngredientID = row.baseIngredientID
        item.ingredientVariationID = row.ingredientVariationID
        if !row.normalizedName.isEmpty { item.normalizedName = row.normalizedName }
        if !row.resolutionStatus.isEmpty { item.resolutionStatus = row.resolutionStatus }
    }

    private func newItem(from row: FreshRow) -> GroceryItem {
        GroceryItem(
            id: UUID().uuidString,
            baseIngredientID: row.baseIngredientID,
            ingredientVariationID: row.ingredientVariationID,
            resolutionStatus: row.resolutionStatus,
            unit: row.unit,
            quantityText: row.quantityText,
            normalizedName: row.normalizedName,
            totalQuantity: row.totalQuantity,
            reviewFlag: row.reviewFlag,
            sourceMeals: row.sourceMeals
        )
    }
}
