import Foundation

// SP-A Phase 7 — Postgres→CloudKit migration transforms: a legacy DB row (decoded JSON,
// snake_case keys) → a CloudKit value type. The one-time per-household import runs each row
// through the matching transform, then writes the result via the zone codecs/engines.
// Idempotency is the MigrationReceipt sentinel (PrivatePlaneStore.claimMigrationScope, Phase 1).
//
// Defensive by construction (the migration ingests real, messy exports): any missing key OR
// unexpected JSON type falls back to the field default — never crash, never drop the row except
// when its primary key is absent. Synthesis of the 5-model head-to-head (see model-scorecard.md).

private func migString(_ row: [String: Any], _ key: String, _ fallback: String = "") -> String {
    guard let v = row[key], !(v is NSNull) else { return fallback }
    return v as? String ?? fallback
}
private func migOptString(_ row: [String: Any], _ key: String) -> String? {
    guard let v = row[key], !(v is NSNull) else { return nil }
    return v as? String
}
private func migOptDouble(_ row: [String: Any], _ key: String) -> Double? {
    guard let v = row[key], !(v is NSNull) else { return nil }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}
private func migBool(_ row: [String: Any], _ key: String, _ fallback: Bool = false) -> Bool {
    guard let v = row[key], !(v is NSNull) else { return fallback }
    if let b = v as? Bool { return b }
    if let i = v as? Int { return i != 0 }
    if let d = v as? Double { return d != 0 }
    if let n = v as? NSNumber { return n.boolValue }
    return fallback
}
private func migClock(_ row: [String: Any], _ key: String, _ fallback: SyncClock = 0) -> SyncClock {
    guard let v = row[key], !(v is NSNull) else { return fallback }
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    if let d = v as? Double { return Int(d) }
    return fallback
}

/// Migrate one legacy grocery row. Returns nil only when the primary key ("id") is absent/empty.
public func migrateGroceryItem(_ row: [String: Any]) -> GroceryItem? {
    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
    return GroceryItem(
        recordName: id,
        weekID: migString(row, "week_id"),
        baseIngredientID: migOptString(row, "base_ingredient_id"),
        ingredientVariationID: migOptString(row, "ingredient_variation_id"),
        resolutionStatus: migString(row, "resolution_status", "unresolved"),
        unit: migString(row, "unit"),
        quantityText: migString(row, "quantity_text"),
        normalizedName: migString(row, "normalized_name"),
        ingredientName: migString(row, "ingredient_name"),
        category: migString(row, "category"),
        totalQuantity: migOptDouble(row, "total_quantity"),
        notes: migString(row, "notes"),
        sourceMeals: migString(row, "source_meals"),
        reviewFlag: migString(row, "review_flag"),
        storeLabel: migString(row, "store_label"),
        isUserAdded: migBool(row, "is_user_added"),
        isUserRemoved: migBool(row, "is_user_removed"),
        quantityOverride: migOptDouble(row, "quantity_override"),
        unitOverride: migOptString(row, "unit_override"),
        notesOverride: migOptString(row, "notes_override"),
        check: CheckState(isChecked: migBool(row, "is_checked"),
                          at: migClock(row, "checked_at_clock"),
                          by: migOptString(row, "checked_by_user_id")),
        eventQuantity: migOptDouble(row, "event_quantity"),
        createdAt: migClock(row, "created_at_clock"),
        modifiedAt: migClock(row, "updated_at_clock"))
}
