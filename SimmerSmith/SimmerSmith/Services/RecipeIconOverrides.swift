import Foundation
import Observation
import SimmerSmithKit

/// Build 83 — per-recipe icon override store.
///
/// Stores `[recipeId: MealIcon.rawValue]` in UserDefaults so the user
/// can pick a hand-drawn glyph for any recipe and have it stick across
/// launches. Per-device for now — server-side sync is a follow-up.
///
/// Auto-detection lives in `MealIcon.autoDetect(for:)`. This store
/// only holds explicit user picks; if no override exists for a recipe,
/// `iconFor(_:)` falls back to auto-detect.
@MainActor
@Observable
final class RecipeIconOverrides {
    static let shared = RecipeIconOverrides()

    private let defaults: UserDefaults
    private let storageKey = "simmersmith.recipeIconOverrides.v1"

    /// Observable map. Writes flush through `defaults` so the picker
    /// can subscribe via the @Observable graph and the value persists.
    private(set) var overrides: [String: String]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        {
            self.overrides = decoded
        } else {
            self.overrides = [:]
        }
    }

    /// Resolve the icon for a recipe. Build 85 priority order:
    /// 1. Server-supplied `recipe.iconKey` (canonical, syncs across
    ///    devices via household).
    /// 2. Local UserDefaults override (pre-sync pick, kept until the
    ///    one-time migration pushes it up).
    /// 3. Auto-detect from name/mealType/cuisine/tags.
    func icon(for recipe: RecipeSummary) -> MealIcon {
        if let parsed = MealIcon(rawValue: recipe.iconKey), parsed != .auto {
            return parsed
        }
        if
            let raw = overrides[recipe.recipeId],
            let parsed = MealIcon(rawValue: raw),
            parsed != .auto
        {
            return parsed
        }
        return MealIcon.autoDetect(for: recipe)
    }

    /// Returns the user's explicit choice, or `.auto` if none.
    func explicitChoice(for recipeId: String) -> MealIcon {
        guard let raw = overrides[recipeId], let parsed = MealIcon(rawValue: raw) else {
            return .auto
        }
        return parsed
    }

    /// Set or clear the override for a recipe. Picking `.auto`
    /// removes the override so future auto-detect changes still apply.
    func set(_ icon: MealIcon, for recipeId: String) {
        if icon == .auto {
            overrides.removeValue(forKey: recipeId)
        } else {
            overrides[recipeId] = icon.rawValue
        }
        flush()
    }

    private func flush() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
