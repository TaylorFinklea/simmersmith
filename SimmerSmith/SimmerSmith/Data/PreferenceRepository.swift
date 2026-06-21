#if canImport(CloudKit)
import Foundation
import Observation
import SimmerSmithKit

// SP-C slice 5 — PreferenceRepository: ingredient preferences + preference signals over
// the PRIVATE plane (NSPCKC, the user's private CloudKit DB), NOT the household zone.
//
// Same mechanism as ProfileRepository (its sibling on the private plane): no CKSyncEngine,
// no merger, no manual send — NSPCKC syncs the @Model rows automatically. Reads/writes go
// through `session.privateStore` (`PrivatePlaneStore`) with fetch-before-insert upserts.
//
// Two record kinds (spec §0/§1):
//   • PrivateIngredientPreference — id-keyed on the app's preferenceId. The published
//     `preferences` projection is sorted by rank (rank=1 = primary brand pick).
//   • PrivatePreferenceSignal — det-keyed "<signalType>:<normalizedName>"; the assistant's
//     learned cuisine/ingredient signals. Write-through here; no published projection
//     (consumed by the scoring path, not a Settings list).
//
// The private plane stores only the fields it owns (preferenceId / baseIngredientID /
// choiceMode / rank / active / brand / variation). The display NAMES
// (baseIngredientName / preferredVariationName) live in the catalog, not here — the
// projection leaves them empty for AppState's rewire to enrich from the catalog façade
// (out of scope for this slice; the household repository pattern's "names come from a
// separate read" idiom). `variation` ↔ preferredVariationId, `brand` ↔ preferredBrand.
//
// Reactivity: fetch-on-demand + reload-after-write (spec §3 — low-frequency Settings reads).

@MainActor
@Observable
final class PreferenceRepository {

    /// Ingredient preferences, sorted by rank ascending (rank=1 first). Names are empty —
    /// AppState enriches them from the catalog on its rewire pass.
    private(set) var preferences: [IngredientPreference] = []

    private let session: HouseholdSession

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Read

    /// Re-read all ingredient preferences from the private plane into `preferences`,
    /// sorted by rank. A nil private store (pre-boot / iCloud unavailable) yields an empty
    /// list rather than throwing.
    func reload() {
        guard let store = session.privateStore else {
            preferences = []
            return
        }
        do {
            let rows = try store.allIngredientPreferences()
            preferences = rows
                .sorted { $0.rank < $1.rank }
                .compactMap(Self.ingredientPreference(from:))
        } catch {
            print("[PreferenceRepository] reload failed: \(error)")
        }
    }

    // MARK: - Ingredient preference writes

    /// Upsert an ingredient preference, persist, and refresh the projection. A new
    /// preference (nil preferenceId) is minted a UUID. Returns the preferenceId written.
    /// The caller must supply the human-readable `baseIngredientName` so the allergy
    /// hard-gate can match by name without a catalog round-trip.
    @discardableResult
    func upsert(_ preference: IngredientPreference) -> String? {
        guard let store = session.privateStore else { return nil }
        let preferenceID = preference.preferenceId.isEmpty ? UUID().uuidString : preference.preferenceId
        do {
            try store.upsertIngredientPreference(
                preferenceID: preferenceID,
                baseIngredientID: preference.baseIngredientId,
                baseIngredientName: preference.baseIngredientName,
                choiceMode: preference.choiceMode,
                rank: preference.rank,
                active: preference.active,
                brand: preference.preferredBrand,
                variation: preference.preferredVariationId ?? ""
            )
            try store.save()
            reload()
            return preferenceID
        } catch {
            print("[PreferenceRepository] upsert failed: \(error)")
            return nil
        }
    }

    /// Delete an ingredient preference by id, persist, and refresh.
    func delete(_ preferenceID: String) {
        guard let store = session.privateStore else { return }
        do {
            if let row = try store.ingredientPreference(preferenceID: preferenceID) {
                store.context.delete(row)
                try store.save()
            }
            reload()
        } catch {
            print("[PreferenceRepository] delete failed: \(error)")
        }
    }

    // MARK: - Preference signal writes

    /// Upsert a preference signal (det-keyed on signalType + normalizedName) and persist.
    /// No projection refresh — signals feed the scoring path, not a published list.
    func upsertSignal(signalType: String, name: String, normalizedName: String, score: Double, active: Bool) {
        guard let store = session.privateStore else { return }
        do {
            try store.upsertPreferenceSignal(
                signalType: signalType,
                name: name,
                normalizedName: normalizedName,
                score: score,
                active: active
            )
            try store.save()
        } catch {
            print("[PreferenceRepository] upsertSignal failed: \(error)")
        }
    }

    // MARK: - Mapping

    /// Project a private-plane row into the app's `IngredientPreference` value via JSON
    /// round-trip (the value is decoder-only). `baseIngredientName` is taken from the stored
    /// row (written at upsert-time from the caller's catalog name) — this is what the
    /// allergy hard-gate reads. notes is empty (not stored on the private plane).
    private static func ingredientPreference(from row: PrivateIngredientPreference) -> IngredientPreference? {
        var dict: [String: Any] = [
            "preferenceId": row.recordKey,
            "baseIngredientId": row.baseIngredientID,
            "baseIngredientName": row.baseIngredientName,
            "preferredBrand": row.brand,
            "choiceMode": row.choiceMode,
            "active": row.active,
            "notes": "",
            "rank": row.rank,
            "updatedAt": ISO8601DateFormatter().string(from: row.updatedAt),
        ]
        if !row.variation.isEmpty {
            dict["preferredVariationId"] = row.variation
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: dict),
            let decoded = try? Self.decoder.decode(IngredientPreference.self, from: data)
        else { return nil }
        return decoded
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
#endif
