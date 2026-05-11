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

    // MARK: - Build 87: plan-shopping + store_label

    /// Build 87: fetch the "needed but not yet on the list" projection
    /// for a specific week. Used by PlanShoppingSheet.
    func loadPlanShopping(weekID: String) async throws -> PlanShoppingResponse {
        try await apiClient.planShopping(weekID: weekID)
    }

    /// Build 87: quick-add a `PlanShoppingItem` to the current week's
    /// grocery list. The new row is appended to the local mirror
    /// optimistically and the Reminders sync re-runs.
    @discardableResult
    func quickAddPlanItem(_ planItem: PlanShoppingItem, storeLabel: String = "") async -> GroceryItem? {
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return nil }
        let body = SimmerSmithAPIClient.GroceryItemQuickAddBody(
            name: planItem.ingredientName,
            normalizedName: planItem.normalizedName,
            quantity: planItem.totalQuantity,
            quantityText: planItem.quantityText,
            unit: planItem.unit,
            category: planItem.category,
            notes: planItem.notes,
            storeLabel: storeLabel
        )
        do {
            let item = try await apiClient.quickAddGroceryItem(weekID: weekID, body: body)
            insertGroceryItemInCurrentWeek(item)
            if item.isChecked { checkedGroceryItemIDs.insert(item.groceryItemId) }
            await syncGroceryToReminders()
            return item
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Build 87: set or clear the store label on a single grocery item.
    /// Empty string clears the annotation server-side.
    func setStoreLabel(itemID: String, storeLabel: String) async {
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return }
        var body = SimmerSmithAPIClient.GroceryItemPatchBody()
        body.storeLabel = .set(storeLabel)
        do {
            let item = try await apiClient.patchGroceryItem(weekID: weekID, itemID: itemID, body: body)
            replaceGroceryItemInCurrentWeek(item)
            await syncGroceryToReminders()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Build 87: the household's known store options. Combines the
    /// existing store-name profile settings (Kroger/Aldi/Walmart) with
    /// any `store_label` values already used on the current week's
    /// grocery items. Sorted, deduplicated, case-insensitive.
    var knownStoreOptions: [String] {
        var set = Set<String>()
        let candidates = [
            profile?.settings["kroger_store_name"],
            profile?.settings["aldi_store_name"],
            profile?.settings["walmart_store_name"],
        ]
        for c in candidates {
            let trimmed = (c ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { set.insert(trimmed) }
        }
        for item in currentWeek?.groceryItems ?? [] {
            let trimmed = item.storeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { set.insert(trimmed) }
        }
        return set.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Build 87: one-shot migration helper. Triggered the first time
    /// the device launches build 87, clears auto-generated grocery
    /// rows on the current week so the user starts from a clean list.
    func clearAutoGroceryForCurrentWeek() async {
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return }
        do {
            let snapshot = try await apiClient.clearAutoGrocery(weekID: weekID)
            currentWeek = snapshot
            try? cacheStore.saveCurrentWeek(snapshot)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// Build 87: idempotent migration. Runs once per device — sets a
    /// UserDefaults flag whether the server call succeeded or not so
    /// a transient network failure doesn't end up clearing the user's
    /// list weeks later. Called from `refreshWeek`.
    func runBuild87GroceryMigrationIfNeeded() async {
        let key = "simmersmith.build87.clearedAutoGrocery"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        await clearAutoGroceryForCurrentWeek()
    }
}
