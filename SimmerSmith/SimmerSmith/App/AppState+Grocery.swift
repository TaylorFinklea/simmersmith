import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - Mutations

    /// Insert a manually-added item on the current week. Smart-merge
    /// regen never touches these rows on the server.
    func addGroceryItem(name: String, quantity: Double? = nil, unit: String = "", notes: String = "") async {
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let item = try await apiClient.addGroceryItem(
                weekID: weekID,
                body: .init(name: trimmed, quantity: quantity, unit: unit, notes: notes)
            )
            insertGroceryItemInCurrentWeek(item)
            if item.isChecked { checkedGroceryItemIDs.insert(item.groceryItemId) }
            await syncGroceryToReminders()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Apply an edit. Pass `.set(value)` to write a value, `.clear` to
    /// revert an override, or leave the field nil for no change.
    /// `removed=true` soft-deletes via the server tombstone.
    func editGroceryItem(
        id: String,
        quantity: SimmerSmithAPIClient.PatchValue<Double>? = nil,
        unit: SimmerSmithAPIClient.PatchValue<String>? = nil,
        notes: SimmerSmithAPIClient.PatchValue<String>? = nil,
        removed: Bool? = nil
    ) async {
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return }
        var body = SimmerSmithAPIClient.GroceryItemPatchBody()
        body.quantity = quantity
        body.unit = unit
        body.notes = notes
        body.removed = removed
        do {
            let item = try await apiClient.patchGroceryItem(weekID: weekID, itemID: id, body: body)
            if item.isUserRemoved {
                removeGroceryItemFromCurrentWeek(id: id)
                checkedGroceryItemIDs.remove(id)
            } else {
                replaceGroceryItemInCurrentWeek(item)
            }
            await syncGroceryToReminders()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Soft-remove a grocery item.
    func removeGroceryItem(id: String) async {
        await editGroceryItem(id: id, removed: true)
    }

    /// Restore a previously-removed item (clears the tombstone).
    func restoreGroceryItem(id: String) async {
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return }
        var body = SimmerSmithAPIClient.GroceryItemPatchBody()
        body.removed = false
        do {
            let item = try await apiClient.patchGroceryItem(weekID: weekID, itemID: id, body: body)
            insertGroceryItemInCurrentWeek(item)
            await syncGroceryToReminders()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func toggleEventAutoMerge(eventID: String, enabled: Bool) async {
        guard hasSavedConnection else { return }
        do {
            let updated = try await apiClient.patchEvent(
                eventID: eventID,
                body: .init(autoMergeGrocery: enabled)
            )
            eventDetails[eventID] = updated
            await refreshWeek()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Local mirror helpers (used by Weeks toggleGroceryChecked too)

    /// Replace an existing item in `currentWeek.groceryItems` with the
    /// authoritative server copy. Keeps the local mirror in sync after
    /// PATCH/check round-trips without re-pulling the entire week.
    func replaceGroceryItemInCurrentWeek(_ item: GroceryItem) {
        guard var week = currentWeek else { return }
        var items = week.groceryItems
        if let index = items.firstIndex(where: { $0.groceryItemId == item.groceryItemId }) {
            items[index] = item
            week = week.replacingGroceryItems(items)
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
    }

    func insertGroceryItemInCurrentWeek(_ item: GroceryItem) {
        guard var week = currentWeek else { return }
        var items = week.groceryItems
        if let index = items.firstIndex(where: { $0.groceryItemId == item.groceryItemId }) {
            items[index] = item
        } else {
            items.append(item)
        }
        week = week.replacingGroceryItems(items)
        currentWeek = week
        try? cacheStore.saveCurrentWeek(week)
    }

    func removeGroceryItemFromCurrentWeek(id: String) {
        guard var week = currentWeek else { return }
        let items = week.groceryItems.filter { $0.groceryItemId != id }
        week = week.replacingGroceryItems(items)
        currentWeek = week
        try? cacheStore.saveCurrentWeek(week)
    }
}
