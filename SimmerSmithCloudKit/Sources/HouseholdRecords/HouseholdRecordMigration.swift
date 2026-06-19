import Foundation
import CloudKitProvisioning

// SP-A Phase 7 — the Postgres→CloudKit migration transform for the 12 plain-CRUD household
// record types. ONE manifest-driven function, NOT 12 hand-mapped ones: the HouseholdRecordType
// manifest already declares every field name + type + the ref graph, so the legacy column name
// derives mechanically from the camelCase field via acronym-aware snake_case (sourceURL →
// source_url, overridePayloadJSON → override_payload_json, recipeTemplateID → recipe_template_id).
// recordName follows the manifest's .pk / .det policy; RecordNames is the single source of truth
// for the det keys (concurrent creates of the same logical key collapse to one record).
//
// Defensive by construction (the migration ingests real, messy exports): a missing / NSNull /
// type-mismatched column falls back to "absent" — the field stays unset, which the codec encodes
// as null, preserving CloudKit's all-optional columns. Never crashes; returns nil ONLY when the
// identity key(s) are absent (no `id`, or a .det type missing its key parts). Pure → unit-tested
// headlessly. The single non-mechanical column is Guest.relationship (Python attr is
// `relationship_label`; the DB column is `relationship`).

/// Migrate one legacy household-record row (decoded JSON, snake_case keys) into the generic
/// value the HouseholdRecordCodec encodes. Returns nil only when the identity key is absent.
public func migrateHouseholdRecord(_ type: HouseholdRecordType, _ row: [String: Any]) -> HouseholdRecordValue? {
    guard let recordName = migRecordName(type, row) else { return nil }

    var scalars: [String: ScalarValue] = [:]
    for field in type.fields {
        if let scalar = migScalar(row, migSourceKey(type, field.name), field.type) {
            scalars[field.name] = scalar
        }
    }
    var refs: [String: String] = [:]
    for ref in type.refs {
        if let target = migRefTarget(row, ref.name) {
            refs[ref.name] = target
        }
    }
    return HouseholdRecordValue(type: type, recordName: recordName, scalars: scalars, refs: refs)
}

// MARK: - recordName (manifest .pk verbatim / .det via RecordNames)

private func migRecordName(_ type: HouseholdRecordType, _ row: [String: Any]) -> String? {
    switch type {
    case .householdSetting:
        guard let key = migNonEmpty(row, "key") else { return nil }
        return RecordNames.householdSetting(key: key)
    case .householdTermAlias:
        guard let term = migNonEmpty(row, "term") else { return nil }
        return RecordNames.termAlias(term: term)
    case .eventAttendee:
        guard let eventID = migNonEmpty(row, "event_id"),
              let guestID = migNonEmpty(row, "guest_id") else { return nil }
        return RecordNames.eventAttendee(eventID: eventID, guestID: guestID)
    case .managedListItem:
        guard let kind = migNonEmpty(row, "kind"),
              let name = migNonEmpty(row, "name") else { return nil }
        return RecordNames.managedListItem(kind: kind, name: name)
    default:
        return migNonEmpty(row, "id")   // .pk — the legacy primary key, verbatim
    }
}

// MARK: - column derivation

/// The legacy column for a manifest field. Mechanical acronym-aware snake_case, except the one
/// hand-renamed column (`Guest.relationship`).
private func migSourceKey(_ type: HouseholdRecordType, _ fieldName: String) -> String {
    if type == .guest, fieldName == "relationshipLabel" { return "relationship" }
    return snakeCase(fieldName)
}

/// The legacy FK column for a manifest ref: `<snake(name without trailing ID)>_id`.
/// In-zone refs (baseRecipe → base_recipe_id) and cross-DB ID refs (recipeTemplateID →
/// recipe_template_id) both land on the right column this way.
private func migRefTarget(_ row: [String: Any], _ refName: String) -> String? {
    let base = refName.hasSuffix("ID") ? String(refName.dropLast(2)) : refName
    return migNonEmpty(row, snakeCase(base) + "_id")
}

// MARK: - defensive scalar coercion

private func migScalar(_ row: [String: Any], _ key: String, _ type: CKFieldType) -> ScalarValue? {
    guard let v = row[key], !(v is NSNull) else { return nil }
    switch type {
    case .string:
        if let s = v as? String { return .string(s) }
    case .int:
        if let i = v as? Int { return .int(i) }
        if let n = v as? NSNumber { return .int(n.intValue) }
        if let d = v as? Double { return .int(Int(d)) }
    case .double:
        if let d = v as? Double { return .double(d) }
        if let i = v as? Int { return .double(Double(i)) }
        if let n = v as? NSNumber { return .double(n.doubleValue) }
    case .date:
        if let s = v as? String, let date = migParseDate(s) { return .date(date) }
    case .bool:
        if let b = v as? Bool { return .bool(b) }
        if let i = v as? Int { return .bool(i != 0) }
        if let n = v as? NSNumber { return .bool(n.boolValue) }
        if let d = v as? Double { return .bool(d != 0) }
    }
    return nil
}

private func migNonEmpty(_ row: [String: Any], _ key: String) -> String? {
    guard let v = row[key], !(v is NSNull), let s = v as? String, !s.isEmpty else { return nil }
    return s
}

// MARK: - acronym-aware snake_case

/// camelCase → snake_case, treating runs of capitals as one word so acronym suffixes survive:
/// mealType → meal_type, sourceURL → source_url, overridePayloadJSON → override_payload_json,
/// recipeTemplateID → recipe_template_id, proteinG → protein_g.
func snakeCase(_ s: String) -> String {
    let chars = Array(s)
    var out = ""
    out.reserveCapacity(chars.count + 8)
    for (i, c) in chars.enumerated() {
        guard c.isUppercase else { out.append(c); continue }
        let prev = i > 0 ? chars[i - 1] : nil
        let next = i + 1 < chars.count ? chars[i + 1] : nil
        // Underscore at a lower/digit → upper boundary, or at the tail of an acronym run that
        // starts a new word (UPPER followed by lower, e.g. the "J" in "...PayloadJSON" stays
        // joined but the "F" in a hypothetical "JSONField" would split).
        if let p = prev, p.isLowercase || p.isNumber {
            out.append("_")
        } else if let p = prev, p.isUppercase, let n = next, n.isLowercase {
            out.append("_")
        }
        out.append(Character(c.lowercased()))
    }
    return out
}

// MARK: - date parsing (defensive: the export's exact timestamp shape isn't pinned)

// Postgres timestamps reach the export as ISO 8601 strings, but the exact form depends on the
// serializer: `T` vs space separator, 0 / 3 / 6 fractional digits, `Z` / `+00:00` / no offset; a
// Date column is `yyyy-MM-dd`. Because the migration ingests real, messy exports (and the export
// path is not yet pinned), parse permissively — try ISO8601DateFormatter for the canonical forms,
// then a cascade of explicit patterns covering Python's `isoformat()` (6-digit microseconds, which
// ISO8601DateFormatter rejects) and Postgres' `str()` (space separator). A naive (no-offset)
// timestamp is read as UTC (Postgres stores timestamptz in UTC). Adversarial-review-driven
// (qwen3.7-max: microseconds; kimi-k2.7-code: space separator; sonnet: no-offset) — 2026-06-17.
private let migISOFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let migISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private let migDateFormatters: [DateFormatter] = [
    "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",   // isoformat with microseconds + offset
    "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",        //   "         "         no offset (read as UTC)
    "yyyy-MM-dd'T'HH:mm:ssXXXXX",          // T, no fraction, offset
    "yyyy-MM-dd'T'HH:mm:ss",               // T, naive
    "yyyy-MM-dd HH:mm:ss.SSSSSSXXXXX",     // Postgres str(): space separator, micros + offset
    "yyyy-MM-dd HH:mm:ss.SSSSSS",
    "yyyy-MM-dd HH:mm:ssXXXXX",            // space, offset
    "yyyy-MM-dd HH:mm:ss",                 // space, naive
    "yyyy-MM-dd",                          // Date column
].map { pattern in
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = pattern
    return f
}

private func migParseDate(_ s: String) -> Date? {
    if let d = migISOFractional.date(from: s) { return d }
    if let d = migISO.date(from: s) { return d }
    for f in migDateFormatters where !s.isEmpty {
        if let d = f.date(from: s) { return d }
    }
    return nil
}
