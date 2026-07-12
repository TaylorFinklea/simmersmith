import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - DATA: add grocery item

    /// Insert a manually-added item on the current week. CloudKit: delegates to
    /// GroceryRepository.addItem (isUserAdded — regen never touches these).
    func addGroceryItem(name: String, quantity: Double? = nil, unit: String = "", notes: String = "") async {
        #if canImport(CloudKit)
        if let weekID = currentWeek?.weekId, let groceryRepo = groceryRepository {
            groceryRepo.addItem(weekID: weekID, name: name, quantity: quantity, unit: unit, notes: notes)
            weekRepository?.reload()
            mirrorWeekFromRepository()
            await syncGroceryToReminders()
            return
        }
        #endif
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

    // MARK: - DATA: edit grocery item

    /// Apply an edit. CloudKit: delegates to GroceryRepository.editItem.
    /// Pass `.set(value)` to write a value, `.clear` to revert an override.
    func editGroceryItem(
        id: String,
        quantity: SimmerSmithAPIClient.PatchValue<Double>? = nil,
        unit: SimmerSmithAPIClient.PatchValue<String>? = nil,
        notes: SimmerSmithAPIClient.PatchValue<String>? = nil,
        removed: Bool? = nil
    ) async {
        #if canImport(CloudKit)
        if let weekID = currentWeek?.weekId, let groceryRepo = groceryRepository {
            if let removed {
                if removed {
                    groceryRepo.removeItem(weekID: weekID, itemID: id)
                } else {
                    groceryRepo.restoreItem(weekID: weekID, itemID: id)
                }
            } else {
                // Map the SimmerSmithAPIClient.PatchValue to GroceryRepository.FieldPatch.
                let qPatch: GroceryRepository.FieldPatch<Double>? = quantity.map {
                    if case .set(let v) = $0 { return .set(v) }
                    return .clear
                }
                let uPatch: GroceryRepository.FieldPatch<String>? = unit.map {
                    if case .set(let v) = $0 { return .set(v) }
                    return .clear
                }
                let nPatch: GroceryRepository.FieldPatch<String>? = notes.map {
                    if case .set(let v) = $0 { return .set(v) }
                    return .clear
                }
                groceryRepo.editItem(weekID: weekID, itemID: id, quantity: qPatch, unit: uPatch, notes: nPatch)
            }
            weekRepository?.reload()
            mirrorWeekFromRepository()
            await syncGroceryToReminders()
            return
        }
        #endif
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

    func linkGroceryItemToIngredient(
        itemID: String,
        baseIngredientID: String,
        canonicalName: String
    ) async throws -> GroceryItem {
        #if canImport(CloudKit)
        guard let weekID = currentWeek?.weekId,
              let groceryRepository,
              groceryRepository.linkIngredient(
                weekID: weekID,
                itemID: itemID,
                baseIngredientID: baseIngredientID,
                canonicalName: canonicalName
              ) != nil else {
            throw NSError(
                domain: "SimmerSmith.GroceryRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Grocery item not found."]
            )
        }
        weekRepository?.reload()
        mirrorWeekFromRepository()
        await syncGroceryToReminders()
        guard let updated = currentWeek?.groceryItems.first(where: { $0.id == itemID }) else {
            throw NSError(
                domain: "SimmerSmith.GroceryRepository",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Linked grocery item could not be reloaded."]
            )
        }
        return updated
        #else
        throw NSError(
            domain: "SimmerSmith.GroceryRepository",
            code: 501,
            userInfo: [NSLocalizedDescriptionKey: "Ingredient linking requires CloudKit."]
        )
        #endif
    }

    // MARK: - DATA: remove / restore

    /// Soft-remove a grocery item.
    func removeGroceryItem(id: String) async {
        await editGroceryItem(id: id, removed: true)
    }

    /// Restore a previously-removed item (clears the tombstone).
    func restoreGroceryItem(id: String) async {
        await editGroceryItem(id: id, removed: false)
    }

    /// The current week's user-removed (tombstoned) grocery rows. CloudKit: delegates to
    /// WeekRepository.removedGroceryItems, the read-only counterpart of the filter that hides
    /// tombstones from `currentWeek.groceryItems`. Feeds GroceryArchiveSheet's "Removed items" list.
    func removedGroceryItems() -> [GroceryItem] {
        #if canImport(CloudKit)
        if let weekID = currentWeek?.weekId, let weekRepo = weekRepository {
            return weekRepo.removedGroceryItems(weekID: weekID)
        }
        #endif
        return []
    }

    // MARK: - DATA: event auto-merge toggle (SP-C slice 4: CloudKit-backed)

    func toggleEventAutoMerge(eventID: String, enabled: Bool) async {
        #if canImport(CloudKit)
        if let repo = eventRepository {
            _ = repo.toggleEventAutoMerge(eventID: eventID, enabled: enabled)
            mirrorEventsFromRepository()
            // Reload weeks so the grocery list reflects the merge/unmerge.
            weekRepository?.reload()
            mirrorWeekFromRepository()
            return
        }
        #endif
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

    // MARK: - DATA: plan shopping (stays on Fly — server-side projection)

    func loadPlanShopping(weekID: String) async throws -> PlanShoppingResponse {
        try await apiClient.planShopping(weekID: weekID)
    }

    func insertGroceryItemInWeek(_ item: GroceryItem, weekID: String) {
        if currentWeek?.weekId == weekID {
            insertGroceryItemInCurrentWeek(item)
        } else if var week = browsedWeek, week.weekId == weekID {
            var items = week.groceryItems
            if let index = items.firstIndex(where: { $0.groceryItemId == item.groceryItemId }) {
                items[index] = item
            } else {
                items.append(item)
            }
            browsedWeek = week.replacingGroceryItems(items)
        }
    }

    // MARK: - DATA: quick-add

    /// Quick-add a PlanShoppingItem to a week's grocery list. CloudKit: delegates to
    /// GroceryRepository.addItem with the resolved fields from the plan item.
    @discardableResult
    func quickAddPlanItem(
        _ planItem: PlanShoppingItem,
        weekID: String? = nil,
        storeLabel: String = ""
    ) async -> GroceryItem? {
        let targetWeekID = weekID ?? currentWeek?.weekId
        guard let targetWeekID else { return nil }
        #if canImport(CloudKit)
        if let groceryRepo = groceryRepository {
            let recordName = groceryRepo.addItem(
                weekID: targetWeekID,
                name: planItem.ingredientName,
                quantity: planItem.totalQuantity,
                unit: planItem.unit,
                notes: planItem.notes,
                category: planItem.category,
                storeLabel: storeLabel
            )
            weekRepository?.reload()
            mirrorWeekFromRepository()
            if currentWeek?.weekId == targetWeekID {
                await syncGroceryToReminders()
            }
            // Return the newly-added domain GroceryItem from the refreshed current week.
            if let id = recordName {
                return currentWeek?.groceryItems.first(where: { $0.groceryItemId == id })
            }
            return nil
        }
        #endif
        guard hasSavedConnection else { return nil }
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
            let item = try await apiClient.quickAddGroceryItem(weekID: targetWeekID, body: body)
            insertGroceryItemInWeek(item, weekID: targetWeekID)
            if currentWeek?.weekId == targetWeekID {
                if item.isChecked { checkedGroceryItemIDs.insert(item.groceryItemId) }
                await syncGroceryToReminders()
            }
            return item
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - DATA: store label

    /// Set or clear the store label on a single grocery item. CloudKit: delegates to
    /// GroceryRepository.setStoreLabel.
    func setStoreLabel(itemID: String, storeLabel: String) async {
        #if canImport(CloudKit)
        if let weekID = currentWeek?.weekId, let groceryRepo = groceryRepository {
            groceryRepo.setStoreLabel(weekID: weekID, itemID: itemID, storeLabel: storeLabel)
            weekRepository?.reload()
            mirrorWeekFromRepository()
            await syncGroceryToReminders()
            return
        }
        #endif
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

    // MARK: - DATA: dedupe (leak closure — was appState.apiClient.dedupeGrocery direct call)

    /// Route the dedupe operation through AppState so views never call apiClient directly.
    /// CloudKit: delegates to GroceryRepository.dedupe (the EventMergeAdapter/ConflictRepair port)
    /// for an immediate, user-visible result, then nudges the household's debounced
    /// RepairScheduler so the broader repair layer (slot/sort-order/week-collapse) also gets a
    /// pass soon after — the manual button becomes a "fix everything" action, not just grocery.
    func dedupeGrocery(weekID: String) async throws {
        #if canImport(CloudKit)
        if let groceryRepo = groceryRepository {
            _ = groceryRepo.dedupe(weekID: weekID)
            householdSession?.repairScheduler.signal()
            weekRepository?.reload()
            mirrorWeekFromRepository()
            return
        }
        #endif
        _ = try await apiClient.dedupeGrocery(weekID: weekID)
    }

    // MARK: - Known store options (Build 87)

    var knownStoreOptions: [String] {
        var set = Set<String>()
        let candidates = [
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

    // MARK: - Build 87: one-shot migration helpers

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

    func runBuild87GroceryMigrationIfNeeded() async {
        let key = "simmersmith.build87.clearedAutoGrocery"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        // CloudKit mode: no auto-grocery regen on Fly; skip the server-side clear.
        #if canImport(CloudKit)
        if groceryRepository != nil { return }
        #endif
        await clearAutoGroceryForCurrentWeek()
    }

    func runBuild88IngredientReresolveIfNeeded() async {
        let key = "simmersmith.build88.reresolvedIngredients"
        if UserDefaults.standard.bool(forKey: key) { return }
        UserDefaults.standard.set(true, forKey: key)
        // CloudKit mode: ingredient re-resolve is a server-side Fly operation; skip it.
        #if canImport(CloudKit)
        if recipeRepository != nil { return }
        #endif
        guard hasSavedConnection else { return }
        do {
            _ = try await apiClient.reresolveUnresolvedIngredients()
            recipes = try await apiClient.fetchRecipes(includeArchived: true)
            try? cacheStore.saveRecipes(recipes)
            if let week = try await apiClient.fetchCurrentWeek() {
                currentWeek = week
                try? cacheStore.saveCurrentWeek(week)
            }
        } catch {
            // Swallow — migration flag is set; won't retry. See original comment.
        }
    }
}
