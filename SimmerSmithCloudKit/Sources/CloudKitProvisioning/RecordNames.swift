import Foundation

/// The recordName policy from SP-A Phase 0 (cloudkit-sp-a-phase0-schema.md §A),
/// encoded as builders. recordName is irreversible, so the DET (deterministic)
/// formats live here as the single source of truth — concurrent creates of the
/// same logical key collapse to one record. Pure → unit-tested.
public enum RecordNames {

    // MARK: - Deterministic (DET) keys — concurrent creates collapse

    /// Per-household KV setting → `hset:<key>`.
    public static func householdSetting(key: String) -> String { "hset:\(normalize(key))" }

    /// Per-user KV setting → `pset:<key>`.
    public static func profileSetting(key: String) -> String { "pset:\(normalize(key))" }

    /// Household term alias → `alias:<normalized_term>` (UNIQUE(household_id, term)).
    public static func termAlias(term: String) -> String { "alias:\(normalize(term))" }

    /// Singleton dietary goal (one per user).
    public static let dietaryGoal = "dietary_goal"

    /// Household-owned managed list item → `mli:<kind>:<normalized_name>`.
    /// Concurrent creates of the same (kind, name) collapse to one record.
    public static func managedListItem(kind: String, name: String) -> String {
        "mli:\(normalize(kind)):\(normalize(name))"
    }

    /// Event↔guest junction → `<eventID>_<guestID>` (re-add = upsert).
    public static func eventAttendee(eventID: String, guestID: String) -> String {
        "\(eventID)_\(guestID)"
    }

    /// Event↔staple supplement junction → `<eventID>_<stapleID>`.
    public static func eventPantrySupplement(eventID: String, stapleID: String) -> String {
        "\(eventID)_\(stapleID)"
    }

    /// 1:1 recipe header image → `rimg:<recipeID>`.
    public static func recipeImage(recipeID: String) -> String { "rimg:\(recipeID)" }

    /// Import-complete sentinel (spec §3.3) keyed by the household or user id.
    public static func migrationReceipt(id: String) -> String { "migrated:\(id)" }

    // MARK: - normalization (must match the server's normalize_name for keys)

    /// Lowercase + collapse whitespace. Mirrors the intent of the server key
    /// normalization; the grocery match key normalization lives in GroceryMerge.
    static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}
