import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
#endif

extension AppState {

    // MARK: - DATA: refresh / fetch (CloudKit-backed)

    /// Refresh the current week. In CloudKit mode the store is already synced
    /// by HouseholdSession; reload is a local read that mirrors the week list
    /// onto AppState (mirrors refreshRecipes pattern). Falls back to the Fly
    /// HTTP path when no CloudKit session is active.
    func refreshWeek() async {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            syncPhase = .loading
            repo.reload()
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return
        }
        #endif
        guard hasSavedConnection else { return }
        syncPhase = .loading
        do {
            let fetched = try await apiClient.fetchCurrentWeek()
            currentWeek = try await advanceCurrentWeekToTodayIfStaleOrNil(fetched)
            if let currentWeek {
                try? cacheStore.saveCurrentWeek(currentWeek)
                exports = try await apiClient.fetchWeekExports(weekID: currentWeek.weekId)
                try? cacheStore.saveExports(exports, for: currentWeek.weekId)
                checkedGroceryItemIDs = Set(
                    currentWeek.groceryItems
                        .filter(\.isChecked)
                        .map(\.groceryItemId)
                )
            } else {
                exports = []
                checkedGroceryItemIDs = []
            }
            syncPhase = .synced(.now)

            if let week = currentWeek, !week.meals.isEmpty {
                NotificationManager.shared.scheduleMealReminders(for: week.meals)
                NotificationManager.shared.scheduleGroceryReminder(itemCount: week.groceryItems.count)
            }

            Task { [weak self] in await self?.runBuild87GroceryMigrationIfNeeded() }
            Task { [weak self] in await self?.runBuild88IngredientReresolveIfNeeded() }
        } catch {
            if isExpectedCancellation(error) { return }
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    /// Fetch the list of weeks. CloudKit: derive WeekSummary projections from the
    /// repo's in-memory snapshots (all fields present; spec §5 notes nutrition/export
    /// counts are nil/0 in this slice).
    func fetchWeeks(limit: Int = 12) async throws -> [WeekSummary] {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            let all = repo.weeks.prefix(limit)
            // Use JSON round-trip to build WeekSummary from WeekSnapshot (they share
            // the same top-level fields; WeekSummary is a count-only projection).
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return all.compactMap { snap in
                var d: [String: Any] = [
                    "weekId": snap.weekId,
                    "weekStart": ISO8601DateFormatter().string(from: snap.weekStart),
                    "weekEnd": ISO8601DateFormatter().string(from: snap.weekEnd),
                    "status": snap.status,
                    "notes": snap.notes,
                    "updatedAt": ISO8601DateFormatter().string(from: snap.updatedAt),
                    "mealCount": snap.meals.count,
                    "groceryItemCount": snap.groceryItems.count,
                    "stagedChangeCount": snap.stagedChangeCount,
                    "feedbackCount": snap.feedbackCount,
                    "exportCount": snap.exportCount,
                ]
                if let v = snap.readyForAiAt { d["readyForAiAt"] = ISO8601DateFormatter().string(from: v) }
                if let v = snap.approvedAt   { d["approvedAt"]   = ISO8601DateFormatter().string(from: v) }
                if let v = snap.pricedAt     { d["pricedAt"]     = ISO8601DateFormatter().string(from: v) }
                guard let data = try? JSONSerialization.data(withJSONObject: d),
                      let summary = try? decoder.decode(WeekSummary.self, from: data)
                else { return nil }
                return summary
            }
        }
        #endif
        return try await apiClient.fetchWeeks(limit: limit)
    }

    /// Server-side `get_current_week` returns the most recently-started week record,
    /// which goes stale if the user hasn't generated a plan past a week boundary.
    /// CloudKit mode: the repo already holds the correct week; this is a no-op
    /// (mirrorWeekFromRepository already resolves today's week by date).
    func advanceCurrentWeekToTodayIfStaleOrNil(_ week: WeekSnapshot?) async throws -> WeekSnapshot? {
        #if canImport(CloudKit)
        if weekRepository != nil {
            // CloudKit: mirrorWeekFromRepository() already resolved today's week from
            // the store; no Fly call needed.
            return week
        }
        #endif
        guard hasSavedConnection, let week else { return week }
        var utcCalendar = Calendar(identifier: .iso8601)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let localComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let todayUTC = utcCalendar.date(from: localComponents) else { return week }

        var target = week.weekStart
        if let weekEndExclusive = utcCalendar.date(byAdding: .day, value: 7, to: target),
           todayUTC >= weekEndExclusive {
            for _ in 0..<260 {
                guard let next = utcCalendar.date(byAdding: .day, value: 7, to: target) else { break }
                if todayUTC < next { break }
                target = next
            }
        } else if todayUTC < target {
            for _ in 0..<260 {
                guard let prev = utcCalendar.date(byAdding: .day, value: -7, to: target) else { break }
                target = prev
                if todayUTC >= target { break }
            }
        }

        guard !utcCalendar.isDate(target, inSameDayAs: week.weekStart) else { return week }
        return try await apiClient.createWeek(weekStart: target, notes: "")
    }

    /// Fetch a specific week by its start date. CloudKit: scan the repo's list.
    func fetchWeekByStart(_ weekStart: Date) async throws -> WeekSnapshot? {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            return repo.week(forStart: weekStart)
        }
        #endif
        return try await apiClient.fetchWeekByStart(weekStart)
    }

    /// Create a new week. CloudKit: write via WeekRepository; return the reloaded snapshot.
    func createWeek(weekStart: Date, notes: String = "") async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            // Derive weekEnd (7 days after weekStart, same day-of-week convention).
            var utcCal = Calendar(identifier: .iso8601)
            utcCal.timeZone = TimeZone(secondsFromGMT: 0)!
            let weekEnd = utcCal.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart
            guard let snap = repo.createWeek(weekStart: weekStart, weekEnd: weekEnd, notes: notes) else {
                throw NSError(
                    domain: "SimmerSmith.WeekRepository",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create week in CloudKit store."]
                )
            }
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return snap
        }
        #endif
        let week = try await apiClient.createWeek(weekStart: weekStart, notes: notes)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        return week
    }

    /// Batch-replace a week's meals. CloudKit: write via WeekRepository.
    func saveWeekMeals(weekID: String, meals: [MealUpdateRequest]) async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            guard let snap = repo.saveWeekMeals(weekID: weekID, meals: meals) else {
                throw NSError(
                    domain: "SimmerSmith.WeekRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Week not found after saveWeekMeals."]
                )
            }
            groceryRepository?.regenerate(weekID: weekID)
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return snap
        }
        #endif
        let week = try await apiClient.updateWeekMeals(weekID: weekID, meals: meals)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    // MARK: - DATA: sides

    /// Add a side to a meal. CloudKit: write via WeekRepository.
    func addMealSide(
        weekID: String,
        mealID: String,
        name: String,
        recipeID: String? = nil,
        notes: String = ""
    ) async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            guard let snap = repo.addMealSide(
                weekID: weekID, mealID: mealID, name: name, recipeID: recipeID, notes: notes)
            else {
                throw NSError(
                    domain: "SimmerSmith.WeekRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Week not found after addMealSide."]
                )
            }
            groceryRepository?.regenerate(weekID: weekID)
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return snap
        }
        #endif
        _ = try await apiClient.addMealSide(
            weekID: weekID,
            mealID: mealID,
            body: SimmerSmithAPIClient.WeekMealSideAddBody(
                name: name, recipeId: recipeID, notes: notes
            )
        )
        return try await refreshWeekAfterSideMutation(weekID: weekID)
    }

    /// Patch an existing side. CloudKit: write via WeekRepository.
    func patchMealSide(
        weekID: String,
        mealID: String,
        sideID: String,
        body: SimmerSmithAPIClient.WeekMealSidePatchBody
    ) async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            guard let snap = repo.updateMealSide(
                weekID: weekID,
                sideID: sideID,
                name: body.name,
                notes: body.notes
            ) else {
                throw NSError(
                    domain: "SimmerSmith.WeekRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Week not found after patchMealSide."]
                )
            }
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return snap
        }
        #endif
        _ = try await apiClient.patchMealSide(
            weekID: weekID, mealID: mealID, sideID: sideID, body: body
        )
        return try await refreshWeekAfterSideMutation(weekID: weekID)
    }

    /// Delete a side. CloudKit: write via WeekRepository.
    func deleteMealSide(weekID: String, mealID: String, sideID: String) async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            guard let snap = repo.deleteMealSide(weekID: weekID, sideID: sideID) else {
                throw NSError(
                    domain: "SimmerSmith.WeekRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Week not found after deleteMealSide."]
                )
            }
            groceryRepository?.regenerate(weekID: weekID)
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return snap
        }
        #endif
        try await apiClient.deleteMealSide(weekID: weekID, mealID: mealID, sideID: sideID)
        return try await refreshWeekAfterSideMutation(weekID: weekID)
    }

    private func refreshWeekAfterSideMutation(weekID: String) async throws -> WeekSnapshot {
        let week = try await apiClient.fetchWeek(weekID: weekID)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        } else if browsedWeek?.weekId == week.weekId {
            browsedWeek = week
        }
        syncPhase = .synced(.now)
        return week
    }

    // MARK: - DATA: approve

    /// Approve a week. CloudKit: write via WeekRepository.
    func approveWeek(weekID: String) async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let repo = weekRepository {
            guard let snap = repo.approveWeek(weekID: weekID) else {
                throw NSError(
                    domain: "SimmerSmith.WeekRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Week not found after approveWeek."]
                )
            }
            mirrorWeekFromRepository()
            syncPhase = .synced(.now)
            return snap
        }
        #endif
        let week = try await apiClient.approveWeek(weekID: weekID)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    // MARK: - DATA: grocery regen

    /// Regenerate the grocery list from the week's meals. CloudKit: delegates to
    /// GroceryRepository.regenerate (the on-device GroceryGenerator port). Returns
    /// the reloaded snapshot.
    func regenerateGrocery(weekID: String) async throws -> WeekSnapshot {
        #if canImport(CloudKit)
        if let weekRepo = weekRepository, let groceryRepo = groceryRepository {
            groceryRepo.regenerate(weekID: weekID)
            weekRepo.reload()
            mirrorWeekFromRepository()
            let snap = weekRepo.week(forId: weekID) ?? currentWeek
            syncPhase = .synced(.now)
            guard let result = snap else {
                throw NSError(
                    domain: "SimmerSmith.GroceryRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Week not found after regenerateGrocery."]
                )
            }
            return result
        }
        #endif
        let week = try await apiClient.regenerateGrocery(weekID: weekID)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    // MARK: - AI TRACK: rebalanceDay (coming-soon; stays on Fly)

    /// AI day-rebalance. NOT cut over to CloudKit — AI track. Guarded in the UI
    /// by the rebalanceBanner being hidden when `isCloudKitOnly` (no profile
    /// dietaryGoal is returned by CloudKit, so the banner condition never fires).
    /// // AI TRACK
    func rebalanceDay(weekID: String, mealDate: Date) async throws -> WeekSnapshot {
        // AI TRACK: rewire to AIProviderKit when the AI slice lands. Stays on Fly.
        let week = try await apiClient.rebalanceDay(weekID: weekID, mealDate: mealDate)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    // MARK: - AI TRACK: generateWeekFromAI (coming-soon)

    /// AI week generation. NOT cut over to CloudKit — AI track.
    /// The "generate week" affordance in WeekView is gated by the AI coordinator
    /// sheet (sparkle FAB → Smith tab). No explicit guard needed here beyond
    /// the `isCloudKitOnly` mode keeping Fly auth absent.
    /// // AI TRACK
    func generateWeekFromAI(weekID: String, prompt: String) async throws -> WeekSnapshot {
        // AI TRACK: rewire to AIProviderKit when the AI slice lands. Stays on Fly.
        let week = try await apiClient.generateWeekPlan(weekID: weekID, prompt: prompt)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    // MARK: - DATA: feedback (stays on Fly — feedback ingestion is server-side)

    func submitMealFeedback(for meal: WeekMeal, in weekID: String, sentiment: Int, notes: String) async throws {
        _ = try await apiClient.submitFeedback(
            weekID: weekID,
            entries: [
                FeedbackEntryRequest(
                    mealId: meal.mealId,
                    targetType: "meal",
                    targetName: meal.recipeName,
                    sentiment: sentiment,
                    notes: notes
                )
            ]
        )
        // Reload the week after feedback (mirrors the old refreshWeekAfterSideMutation).
        #if canImport(CloudKit)
        if weekRepository != nil {
            await refreshWeek()
            return
        }
        #endif
        _ = try await refreshWeekAfterSideMutation(weekID: weekID)
    }

    func submitGroceryFeedback(for item: GroceryItem, sentiment: Int, notes: String) async throws {
        guard let weekID = currentWeek?.weekId else { return }
        _ = try await apiClient.submitFeedback(
            weekID: weekID,
            entries: [
                FeedbackEntryRequest(
                    groceryItemId: item.groceryItemId,
                    targetType: "shopping_item",
                    targetName: item.ingredientName,
                    normalizedName: item.normalizedName,
                    sentiment: sentiment,
                    notes: notes
                )
            ]
        )
        await refreshWeek()
    }

    func isGroceryChecked(_ groceryItemID: String) -> Bool {
        checkedGroceryItemIDs.contains(groceryItemID)
    }

    /// Toggle the household-shared check state. CloudKit: delegates to
    /// GroceryRepository.toggleChecked (the field-merge handles household convergence).
    func toggleGroceryChecked(_ groceryItemID: String) async {
        #if canImport(CloudKit)
        if let weekID = currentWeek?.weekId, let groceryRepo = groceryRepository {
            let willCheck = !checkedGroceryItemIDs.contains(groceryItemID)
            if willCheck { checkedGroceryItemIDs.insert(groceryItemID) }
            else { checkedGroceryItemIDs.remove(groceryItemID) }
            groceryRepo.toggleChecked(weekID: weekID, itemID: groceryItemID)
            await syncGroceryToReminders()
            return
        }
        #endif
        guard hasSavedConnection, let weekID = currentWeek?.weekId else { return }
        let willCheck = !checkedGroceryItemIDs.contains(groceryItemID)
        if willCheck { checkedGroceryItemIDs.insert(groceryItemID) }
        else { checkedGroceryItemIDs.remove(groceryItemID) }
        do {
            let updated = willCheck
                ? try await apiClient.checkGroceryItem(weekID: weekID, itemID: groceryItemID)
                : try await apiClient.uncheckGroceryItem(weekID: weekID, itemID: groceryItemID)
            replaceGroceryItemInCurrentWeek(updated)
            await syncGroceryToReminders()
        } catch {
            if willCheck { checkedGroceryItemIDs.remove(groceryItemID) }
            else { checkedGroceryItemIDs.insert(groceryItemID) }
            lastErrorMessage = error.localizedDescription
        }
    }
}
