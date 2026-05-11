import Foundation
import SimmerSmithKit

/// M28 — pantry state + helpers.
///
/// Pantry items live on `AppState.pantryItems` once the user opens
/// the Pantry view. Mutations call the dedicated PATCH-by-id
/// endpoints so recurring metadata + last_applied_at survive across
/// edits (the legacy `PUT /api/profile` staple flow recreates rows
/// by name, which would lose those columns).
extension AppState {
    func loadPantryItems() async {
        do {
            pantryItems = try await apiClient.fetchPantryItems()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func addPantryItem(_ body: SimmerSmithAPIClient.PantryItemAddBody) async {
        do {
            let added = try await apiClient.addPantryItem(body: body)
            pantryItems.append(added)
            pantryItems.sort(by: { $0.stapleName.lowercased() < $1.stapleName.lowercased() })
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Build 88: quick-add an ingredient to the pantry from a grocery
    /// or plan-shopping row. Skips if a pantry item with the same
    /// normalized name already exists. Returns `true` when a new row
    /// was created so callers can show "Added to pantry" feedback.
    @discardableResult
    func quickAddIngredientToPantry(
        name: String,
        category: String = "",
        unit: String = "",
        normalizedNameHint: String = ""
    ) async -> Bool {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return false }
        let normalized = normalizedNameHint.isEmpty
            ? cleanedName.lowercased()
            : normalizedNameHint.lowercased()
        if pantryItems.isEmpty {
            await loadPantryItems()
        }
        if pantryItems.contains(where: {
            $0.normalizedName.lowercased() == normalized
                || $0.stapleName.lowercased() == cleanedName.lowercased()
        }) {
            return false
        }
        let body = SimmerSmithAPIClient.PantryItemAddBody(
            stapleName: cleanedName,
            normalizedName: normalized,
            category: category,
            categories: category.isEmpty ? [] : [category]
        )
        let before = pantryItems.count
        await addPantryItem(body)
        return pantryItems.count > before
    }

    func patchPantryItem(itemID: String, body: SimmerSmithAPIClient.PantryItemPatchBody) async {
        do {
            let updated = try await apiClient.patchPantryItem(itemID: itemID, body: body)
            if let idx = pantryItems.firstIndex(where: { $0.pantryItemId == itemID }) {
                pantryItems[idx] = updated
            } else {
                pantryItems.append(updated)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func deletePantryItem(itemID: String) async {
        do {
            try await apiClient.deletePantryItem(itemID: itemID)
            pantryItems.removeAll(where: { $0.pantryItemId == itemID })
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Apply pantry recurrings to the given week and refresh both the
    /// pantry list (last_applied_at moved) and the week (new grocery
    /// rows landed). Wired to a manual "Apply to this week" button so
    /// users can force a re-fold without waiting for the next regen.
    func applyPantryToCurrentWeek() async {
        guard let weekID = currentWeek?.weekId else { return }
        do {
            pantryItems = try await apiClient.applyPantryToWeek(weekID: weekID)
            let week = try await apiClient.fetchWeek(weekID: weekID)
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }
}
