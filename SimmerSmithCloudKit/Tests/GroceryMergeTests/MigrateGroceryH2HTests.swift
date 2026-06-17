import Foundation
import Testing
@testable import GroceryMerge

// SP-A Phase 7 — 5-model head-to-head: migrateGroceryItem (JSON row → value type), M-sized
// (24 fields, snake_case, NSNull/NSNumber/Bool-as-Int handling, missing-PK → nil). Same prompt
// to all 5; objective verify with realistic JSONSerialization-shaped inputs. Scores in
// ~/.claude/model-scorecard.md.

private func firstFailure(_ migrate: ([String: Any]) -> GroceryItem?) -> String? {
    // Case A — full realistic row (numbers as NSNumber, like JSONSerialization output)
    let full: [String: Any] = [
        "id": "G1", "week_id": "W", "base_ingredient_id": "b1", "resolution_status": "locked",
        "total_quantity": NSNumber(value: 2.5), "is_user_added": NSNumber(value: true),
        "is_user_removed": NSNumber(value: false), "is_checked": NSNumber(value: 1),
        "checked_at_clock": NSNumber(value: 42), "checked_by_user_id": "u",
        "created_at_clock": NSNumber(value: 7), "updated_at_clock": NSNumber(value: 11),
        "event_quantity": NSNumber(value: 3), "quantity_override": NSNumber(value: 9), "unit_override": "g",
    ]
    let expectedA = GroceryItem(
        recordName: "G1", weekID: "W", baseIngredientID: "b1", resolutionStatus: "locked",
        totalQuantity: 2.5, isUserAdded: true, isUserRemoved: false, quantityOverride: 9, unitOverride: "g",
        check: CheckState(isChecked: true, at: 42, by: "u"), eventQuantity: 3, createdAt: 7, modifiedAt: 11)
    if migrate(full) != expectedA { return "full: \(String(describing: migrate(full)))" }

    // Case B — minimal row → all defaults
    if migrate(["id": "G2"]) != GroceryItem(recordName: "G2") { return "minimal" }

    // Case C — missing / empty / non-string primary key → nil
    if migrate([:]) != nil { return "empty dict !nil" }
    if migrate(["id": ""]) != nil { return "empty id !nil" }
    if migrate(["id": NSNumber(value: 5)]) != nil { return "non-string id !nil" }

    // Case D — NSNull values fall back to default/nil (not a crash)
    let nulls: [String: Any] = ["id": "G3", "base_ingredient_id": NSNull(),
                                "total_quantity": NSNull(), "week_id": NSNull()]
    let d = migrate(nulls)
    if d?.baseIngredientID != nil || d?.totalQuantity != nil || d?.weekID != "" {
        return "NSNull: \(String(describing: d))"
    }

    // Case E — unexpected JSON type uses the field default (no crash)
    if migrate(["id": "G4", "week_id": NSNumber(value: 123)])?.weekID != "" { return "type-mismatch weekID" }
    return nil
}

@Test func migrate_canonical() { #expect(firstFailure(migrateGroceryItem) == nil) }
@Test func migrate_sonnet()   { #expect(firstFailure(migG_sonnet)   == nil) }
@Test func migrate_haiku()    { #expect(firstFailure(migG_haiku)    == nil) }
@Test func migrate_minimax()  { #expect(firstFailure(migG_minimax)  == nil) }
@Test func migrate_qwen()     { #expect(firstFailure(migG_qwen)     == nil) }
@Test func migrate_kimi()     { #expect(firstFailure(migG_kimi)     == nil) }

// ===== verbatim model submissions (renamed; helpers nested) =====

private func migG_sonnet(_ row: [String: Any]) -> GroceryItem? {
    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
    func str(_ key: String, default def: String = "") -> String { row[key] as? String ?? def }
    func optStr(_ key: String) -> String? {
        guard let v = row[key] else { return nil }; if v is NSNull { return nil }; return v as? String
    }
    func optDouble(_ key: String) -> Double? {
        guard let v = row[key] else { return nil }; if v is NSNull { return nil }
        if let d = v as? Double { return d }; if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }; return nil
    }
    func boolVal(_ key: String, default def: Bool = false) -> Bool {
        guard let v = row[key] else { return def }; if v is NSNull { return def }
        if let b = v as? Bool { return b }; if let i = v as? Int { return i != 0 }
        if let n = v as? NSNumber { return n.intValue != 0 }; return def
    }
    func clockVal(_ key: String, default def: Int = 0) -> Int {
        guard let v = row[key] else { return def }; if v is NSNull { return def }
        if let i = v as? Int { return i }; if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }; return def
    }
    return GroceryItem(recordName: id, weekID: str("week_id"), baseIngredientID: optStr("base_ingredient_id"),
        ingredientVariationID: optStr("ingredient_variation_id"), resolutionStatus: str("resolution_status", default: "unresolved"),
        unit: str("unit"), quantityText: str("quantity_text"), normalizedName: str("normalized_name"),
        ingredientName: str("ingredient_name"), category: str("category"), totalQuantity: optDouble("total_quantity"),
        notes: str("notes"), sourceMeals: str("source_meals"), reviewFlag: str("review_flag"), storeLabel: str("store_label"),
        isUserAdded: boolVal("is_user_added"), isUserRemoved: boolVal("is_user_removed"),
        quantityOverride: optDouble("quantity_override"), unitOverride: optStr("unit_override"), notesOverride: optStr("notes_override"),
        check: CheckState(isChecked: boolVal("is_checked"), at: clockVal("checked_at_clock"), by: optStr("checked_by_user_id")),
        eventQuantity: optDouble("event_quantity"), createdAt: clockVal("created_at_clock"), modifiedAt: clockVal("updated_at_clock"))
}

private func migG_haiku(_ row: [String: Any]) -> GroceryItem? {
    func getString(_ key: String, default def: String = "") -> String { row[key] as? String ?? def }
    func getDouble(_ key: String) -> Double? {
        if let n = row[key] as? NSNumber { return n.doubleValue }
        if let d = row[key] as? Double { return d }; if let i = row[key] as? Int { return Double(i) }; return nil
    }
    func getBool(_ key: String) -> Bool {
        if let b = row[key] as? Bool { return b }; if let n = row[key] as? NSNumber { return n.boolValue }
        if let i = row[key] as? Int { return i != 0 }; return false
    }
    func getInt(_ key: String) -> Int {
        if let n = row[key] as? NSNumber { return n.intValue }; if let i = row[key] as? Int { return i }; return 0
    }
    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
    return GroceryItem(recordName: id, weekID: getString("week_id"), baseIngredientID: row["base_ingredient_id"] as? String,
        ingredientVariationID: row["ingredient_variation_id"] as? String, resolutionStatus: getString("resolution_status", default: "unresolved"),
        unit: getString("unit"), quantityText: getString("quantity_text"), normalizedName: getString("normalized_name"),
        ingredientName: getString("ingredient_name"), category: getString("category"), totalQuantity: getDouble("total_quantity"),
        notes: getString("notes"), sourceMeals: getString("source_meals"), reviewFlag: getString("review_flag"), storeLabel: getString("store_label"),
        isUserAdded: getBool("is_user_added"), isUserRemoved: getBool("is_user_removed"),
        quantityOverride: getDouble("quantity_override"), unitOverride: row["unit_override"] as? String, notesOverride: row["notes_override"] as? String,
        check: CheckState(isChecked: getBool("is_checked"), at: getInt("checked_at_clock"), by: row["checked_by_user_id"] as? String),
        eventQuantity: getDouble("event_quantity"), createdAt: getInt("created_at_clock"), modifiedAt: getInt("updated_at_clock"))
}

private func migG_minimax(_ row: [String: Any]) -> GroceryItem? {
    func stringValue(_ key: String, _ fallback: String) -> String {
        guard let v = row[key], !(v is NSNull) else { return fallback }; return v as? String ?? fallback
    }
    func optionalString(_ key: String) -> String? {
        guard let v = row[key], !(v is NSNull) else { return nil }; return v as? String
    }
    func boolValue(_ key: String) -> Bool {
        guard let v = row[key], !(v is NSNull) else { return false }
        if let b = v as? Bool { return b }; if let i = v as? Int { return i != 0 }
        if let d = v as? Double { return d != 0 }; if let n = v as? NSNumber { return n.boolValue }; return false
    }
    func optionalDouble(_ key: String) -> Double? {
        guard let v = row[key], !(v is NSNull) else { return nil }
        if let d = v as? Double { return d }; if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }; return nil
    }
    func intValue(_ key: String, _ fallback: Int) -> Int {
        guard let v = row[key], !(v is NSNull) else { return fallback }
        if let i = v as? Int { return i }; if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }; return fallback
    }
    guard let idRaw = row["id"], !(idRaw is NSNull), let id = idRaw as? String, !id.isEmpty else { return nil }
    return GroceryItem(recordName: id, weekID: stringValue("week_id", ""), baseIngredientID: optionalString("base_ingredient_id"),
        ingredientVariationID: optionalString("ingredient_variation_id"), resolutionStatus: stringValue("resolution_status", "unresolved"),
        unit: stringValue("unit", ""), quantityText: stringValue("quantity_text", ""), normalizedName: stringValue("normalized_name", ""),
        ingredientName: stringValue("ingredient_name", ""), category: stringValue("category", ""), totalQuantity: optionalDouble("total_quantity"),
        notes: stringValue("notes", ""), sourceMeals: stringValue("source_meals", ""), reviewFlag: stringValue("review_flag", ""), storeLabel: stringValue("store_label", ""),
        isUserAdded: boolValue("is_user_added"), isUserRemoved: boolValue("is_user_removed"),
        quantityOverride: optionalDouble("quantity_override"), unitOverride: optionalString("unit_override"), notesOverride: optionalString("notes_override"),
        check: CheckState(isChecked: boolValue("is_checked"), at: intValue("checked_at_clock", 0), by: optionalString("checked_by_user_id")),
        eventQuantity: optionalDouble("event_quantity"), createdAt: intValue("created_at_clock", 0), modifiedAt: intValue("updated_at_clock", 0))
}

private func migG_qwen(_ row: [String: Any]) -> GroceryItem? {
    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
    func string(_ key: String, default def: String = "") -> String { (row[key] as? String) ?? def }
    func optionalString(_ key: String) -> String? { row[key] as? String }
    func optionalDouble(_ key: String) -> Double? {
        if let val = row[key] { if let d = val as? Double { return d }; if let i = val as? Int { return Double(i) }; if let n = val as? NSNumber { return n.doubleValue } }
        return nil
    }
    func int(_ key: String, default def: Int = 0) -> Int {
        if let val = row[key] { if let i = val as? Int { return i }; if let d = val as? Double { return Int(d) }; if let n = val as? NSNumber { return n.intValue } }
        return def
    }
    func bool(_ key: String, default def: Bool = false) -> Bool {
        if let val = row[key] { if let b = val as? Bool { return b }; if let i = val as? Int { return i != 0 }; if let n = val as? NSNumber { return n.boolValue } }
        return def
    }
    return GroceryItem(recordName: id, weekID: string("week_id"), baseIngredientID: optionalString("base_ingredient_id"),
        ingredientVariationID: optionalString("ingredient_variation_id"), resolutionStatus: string("resolution_status", default: "unresolved"),
        unit: string("unit"), quantityText: string("quantity_text"), normalizedName: string("normalized_name"),
        ingredientName: string("ingredient_name"), category: string("category"), totalQuantity: optionalDouble("total_quantity"),
        notes: string("notes"), sourceMeals: string("source_meals"), reviewFlag: string("review_flag"), storeLabel: string("store_label"),
        isUserAdded: bool("is_user_added"), isUserRemoved: bool("is_user_removed"),
        quantityOverride: optionalDouble("quantity_override"), unitOverride: optionalString("unit_override"), notesOverride: optionalString("notes_override"),
        check: CheckState(isChecked: bool("is_checked"), at: int("checked_at_clock"), by: optionalString("checked_by_user_id")),
        eventQuantity: optionalDouble("event_quantity"), createdAt: int("created_at_clock"), modifiedAt: int("updated_at_clock"))
}

private func migG_kimi(_ row: [String: Any]) -> GroceryItem? {
    func string(for key: String, default defaultValue: String = "") -> String { (row[key] as? String) ?? defaultValue }
    func optionalString(for key: String) -> String? {
        guard let value = row[key] else { return nil }; if value is NSNull { return nil }; return value as? String
    }
    func double(for key: String) -> Double? {
        guard let value = row[key] else { return nil }; if value is NSNull { return nil }
        if let num = value as? Double { return num }; if let num = value as? Int { return Double(num) }
        if let num = value as? NSNumber { return num.doubleValue }; return nil
    }
    func bool(for key: String, default defaultValue: Bool = false) -> Bool {
        guard let value = row[key] else { return defaultValue }
        if let b = value as? Bool { return b }; if let num = value as? Int { return num != 0 }
        if let num = value as? NSNumber { return num.boolValue }; return defaultValue
    }
    func intClock(for key: String, default defaultValue: Int = 0) -> Int {
        guard let value = row[key] else { return defaultValue }
        if let num = value as? Int { return num }; if let num = value as? NSNumber { return num.intValue }; return defaultValue
    }
    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
    return GroceryItem(recordName: id, weekID: string(for: "week_id"), baseIngredientID: optionalString(for: "base_ingredient_id"),
        ingredientVariationID: optionalString(for: "ingredient_variation_id"), resolutionStatus: string(for: "resolution_status", default: "unresolved"),
        unit: string(for: "unit"), quantityText: string(for: "quantity_text"), normalizedName: string(for: "normalized_name"),
        ingredientName: string(for: "ingredient_name"), category: string(for: "category"), totalQuantity: double(for: "total_quantity"),
        notes: string(for: "notes"), sourceMeals: string(for: "source_meals"), reviewFlag: string(for: "review_flag"), storeLabel: string(for: "store_label"),
        isUserAdded: bool(for: "is_user_added"), isUserRemoved: bool(for: "is_user_removed"),
        quantityOverride: double(for: "quantity_override"), unitOverride: optionalString(for: "unit_override"), notesOverride: optionalString(for: "notes_override"),
        check: CheckState(isChecked: bool(for: "is_checked"), at: intClock(for: "checked_at_clock"), by: optionalString(for: "checked_by_user_id")),
        eventQuantity: double(for: "event_quantity"), createdAt: intClock(for: "created_at_clock"), modifiedAt: intClock(for: "updated_at_clock"))
}
