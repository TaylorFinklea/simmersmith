#if canImport(CloudKit)
import Foundation
import Observation
import SimmerSmithKit

// SP-C slice 5 — ProfileRepository: per-user profile settings + dietary goal over the
// PRIVATE plane (NSPCKC, the user's private CloudKit DB), NOT the household zone.
//
// This is a DIFFERENT mechanism from the household repositories (RecipeRepository etc.):
// there is no CKSyncEngine, no merger, no manual send — NSPCKC syncs the SwiftData @Model
// rows automatically. The repository reads/writes through `session.privateStore`
// (`PrivatePlaneStore`) which does fetch-before-insert upserts keyed on a stable
// recordKey, then calls `save()` on its `@MainActor` ModelContext.
//
// Scope (per spec §0): NON-AI settings only — image_provider / unit_system / user_region /
// auto_grocery_from_meals — plus the singleton dietary goal. The AI settings (provider
// config + API key → Keychain, assistant data) are OUT (AI track owns them).
//
// Reactivity: fetch-on-demand + reload-after-write (spec §3 — these are low-frequency
// Settings reads, so no @Observable bridge to session.storeRevision; NSPCKC has no
// equivalent change signal here). The projection (`settings`, `dietaryGoal`) is published
// so AppState can mirror it onto `profile` (a ProfileSnapshot-ish read the Settings views
// already bind to).

@MainActor
@Observable
final class ProfileRepository {

    /// The NON-AI profile settings the views read, keyed by the same setting keys the
    /// Fly profile used (image_provider / unit_system / user_region / auto_grocery_from_meals).
    private(set) var settings: [String: String] = [:]

    /// The singleton dietary goal, or nil when the user hasn't set one.
    private(set) var dietaryGoal: DietaryGoal?

    /// The setting keys this repository owns (NON-AI). Used to scope reads/writes so the
    /// private plane's other rows (AI settings, when the AI track adds them) are untouched.
    static let nonAIKeys = ["image_provider", "unit_system", "user_region", "auto_grocery_from_meals"]

    private let session: HouseholdSession

    init(session: HouseholdSession) {
        self.session = session
    }

    // MARK: - Read

    /// Re-read the owned settings + dietary goal from the private plane into the published
    /// projection. Call on appear and after every write. A nil private store (pre-boot /
    /// iCloud unavailable) leaves the projection empty rather than throwing.
    func reload() {
        guard let store = session.privateStore else {
            settings = [:]
            dietaryGoal = nil
            return
        }
        do {
            var loaded: [String: String] = [:]
            for key in Self.nonAIKeys {
                if let row = try store.profileSetting(key: key) {
                    loaded[key] = row.value
                }
            }
            settings = loaded
            dietaryGoal = try Self.dietaryGoal(from: store.dietaryGoal())
        } catch {
            print("[ProfileRepository] reload failed: \(error)")
        }
    }

    // MARK: - Settings writes

    /// Upsert a single NON-AI setting, persist, and refresh the projection. Keys outside
    /// `nonAIKeys` are rejected (no-op) — AI settings are not this repository's concern.
    func setSetting(_ key: String, _ value: String) {
        guard Self.nonAIKeys.contains(key) else { return }
        guard let store = session.privateStore else { return }
        do {
            try store.upsertProfileSetting(key: key, value: value)
            try store.save()
            reload()
        } catch {
            print("[ProfileRepository] setSetting(\(key)) failed: \(error)")
        }
    }

    // MARK: - Dietary goal writes

    /// Upsert the singleton dietary goal, persist, and refresh the projection.
    func saveDietaryGoal(_ goal: DietaryGoal) {
        guard let store = session.privateStore else { return }
        do {
            try store.upsertDietaryGoal(
                goalType: goal.goalType.rawValue,
                dailyCalories: goal.dailyCalories,
                proteinG: goal.proteinG,
                carbsG: goal.carbsG,
                fatG: goal.fatG,
                fiberG: goal.fiberG ?? 0,
                notes: goal.notes
            )
            try store.save()
            reload()
        } catch {
            print("[ProfileRepository] saveDietaryGoal failed: \(error)")
        }
    }

    /// Clear the singleton dietary goal (delete the row), persist, and refresh.
    func clearDietaryGoal() {
        guard let store = session.privateStore else { return }
        do {
            if let row = try store.dietaryGoal() {
                store.context.delete(row)
                try store.save()
            }
            reload()
        } catch {
            print("[ProfileRepository] clearDietaryGoal failed: \(error)")
        }
    }

    // MARK: - Mapping

    /// Project a private-plane `PrivateDietaryGoal` row into the app's `DietaryGoal` value.
    /// fiberG round-trips 0 → nil only when the goal was never set; here a stored 0 is a
    /// legitimate value, so it maps straight through.
    private static func dietaryGoal(from row: PrivateDietaryGoal?) -> DietaryGoal? {
        guard let row else { return nil }
        let type = DietaryGoalType(rawValue: row.goalType) ?? .maintain
        return DietaryGoal(
            goalType: type,
            dailyCalories: row.dailyCalories,
            proteinG: row.proteinG,
            carbsG: row.carbsG,
            fatG: row.fatG,
            fiberG: row.fiberG,
            notes: row.notes,
            updatedAt: row.updatedAt
        )
    }
}
#endif
