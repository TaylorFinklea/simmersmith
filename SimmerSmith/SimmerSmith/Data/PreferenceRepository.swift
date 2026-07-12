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
//     learned recipe/cuisine signals. Published as `signals` (bead simmersmith-b9z) so
//     WeekGenContextGatherer can derive strongLikes/likedCuisines/dislikedCuisines from
//     them — not a Settings list, just the scoring path's read side.
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

    /// Preference signals (recipe + cuisine), unsorted — feeds
    /// `WeekGenContextGatherer.build`'s strongLikes/likedCuisines/dislikedCuisines
    /// derivation (bead simmersmith-b9z).
    private(set) var signals: [PreferenceSignal] = []

    private enum StoreSource {
        case session(HouseholdSession)
        case fixed(PrivatePlaneStore?)
    }

    private let storeSource: StoreSource

    private var store: PrivatePlaneStore? {
        switch storeSource {
        case .session(let session): session.privateStore
        case .fixed(let store): store
        }
    }

    init(session: HouseholdSession) {
        self.storeSource = .session(session)
    }

    init(store: PrivatePlaneStore?) {
        self.storeSource = .fixed(store)
    }

    // MARK: - Read

    /// Re-read all ingredient preferences from the private plane into `preferences`,
    /// sorted by rank. A nil private store (pre-boot / iCloud unavailable) yields an empty
    /// list rather than throwing.
    func reload() {
        guard let store else {
            preferences = []
            signals = []
            return
        }
        do {
            let rows = try store.allIngredientPreferences()
            preferences = rows
                .sorted { $0.rank < $1.rank }
                .compactMap(Self.ingredientPreference(from:))
            signals = try store.allPreferenceSignals().map(Self.preferenceSignal(from:))
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
        guard let store else { return nil }
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
        guard let store else { return }
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

    func repointAfterIngredientMerge(
        sourceBaseIngredientID: String,
        sourceBaseIngredientName: String,
        targetBaseIngredientID: String,
        targetBaseIngredientName: String,
        variationIDMap: [String: String]
    ) throws {
        guard let store else { throw PreferenceRepositoryError.storeUnavailable }
        try store.repointIngredientPreferences(
            sourceBaseIngredientID: sourceBaseIngredientID,
            sourceBaseIngredientName: sourceBaseIngredientName,
            targetBaseIngredientID: targetBaseIngredientID,
            targetBaseIngredientName: targetBaseIngredientName,
            variationIDMap: variationIDMap
        )
        try store.save()
        reload()
    }

    // MARK: - Preference signal writes

    /// Upsert a preference signal (det-keyed on signalType + normalizedName), persist,
    /// and refresh `signals` so a subsequent read (a back-to-back recipe+cuisine write,
    /// or the next planning-context gather) sees the write immediately.
    func upsertSignal(signalType: String, name: String, normalizedName: String, score: Double, active: Bool) {
        guard let store else { return }
        do {
            try store.upsertPreferenceSignal(
                signalType: signalType,
                name: name,
                normalizedName: normalizedName,
                score: score,
                active: active
            )
            try store.save()
            reload()
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

    /// Project a private-plane signal row into the app's `PreferenceSignal` value — a
    /// direct field copy (no catalog enrichment needed, unlike ingredient preferences).
    private static func preferenceSignal(from row: PrivatePreferenceSignal) -> PreferenceSignal {
        PreferenceSignal(
            signalType: row.signalType,
            name: row.name,
            normalizedName: row.normalizedName,
            score: row.score,
            active: row.active,
            updatedAt: row.updatedAt
        )
    }
}

enum PreferenceRepositoryError: Error, Equatable {
    case storeUnavailable
}
#endif
