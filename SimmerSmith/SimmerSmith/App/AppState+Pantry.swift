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
