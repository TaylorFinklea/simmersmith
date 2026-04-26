import Foundation
import SimmerSmithKit

extension AppState {
    func refreshWeek() async {
        guard hasSavedConnection else { return }
        syncPhase = .loading
        do {
            let fetched = try await apiClient.fetchCurrentWeek()
            currentWeek = try await advanceCurrentWeekToTodayIfStale(fetched)
            if let currentWeek {
                try? cacheStore.saveCurrentWeek(currentWeek)
                exports = try await apiClient.fetchWeekExports(weekID: currentWeek.weekId)
                try? cacheStore.saveExports(exports, for: currentWeek.weekId)
                checkedGroceryItemIDs = Set(
                    currentWeek.groceryItems
                        .filter { cacheStore.isChecked(groceryItemID: $0.groceryItemId) }
                        .map(\.groceryItemId)
                )
            } else {
                exports = []
                checkedGroceryItemIDs = []
            }
            syncPhase = .synced(.now)

            // Schedule meal reminders for the current week
            if let week = currentWeek, !week.meals.isEmpty {
                NotificationManager.shared.scheduleMealReminders(for: week.meals)
                NotificationManager.shared.scheduleGroceryReminder(itemCount: week.groceryItems.count)
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    func fetchWeeks(limit: Int = 12) async throws -> [WeekSummary] {
        try await apiClient.fetchWeeks(limit: limit)
    }

    /// Server-side `get_current_week` returns the most recently-started
    /// week record, which goes stale if the user hasn't generated a plan
    /// past a week boundary — they'd open the Week tab and see last
    /// week's data labeled "this week". Calendar apps default to
    /// "today's view" on open; we match that by lazily creating a week
    /// for today when the server's current week ends before today.
    /// Uses the existing record's day-of-week convention so a Monday-
    /// start user keeps Monday-start, Sunday-start keeps Sunday-start.
    ///
    /// "Today" is the user's local calendar date, projected onto UTC
    /// midnight for comparison with `week_start` (which the server
    /// stores as a date-only and ships as UTC-midnight). Using
    /// `Date()` directly here would falsely advance for any user in a
    /// timezone west of UTC whose local clock is past UTC midnight
    /// (e.g. CDT evening), because that absolute instant lands on the
    /// next UTC day even though it's still "today" to the user.
    private func advanceCurrentWeekToTodayIfStale(_ week: WeekSnapshot?) async throws -> WeekSnapshot? {
        guard hasSavedConnection, let week else { return week }
        var utcCalendar = Calendar(identifier: .iso8601)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let localComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        guard let todayUTC = utcCalendar.date(from: localComponents) else { return week }

        var target = week.weekStart
        if let weekEndExclusive = utcCalendar.date(byAdding: .day, value: 7, to: target),
           todayUTC >= weekEndExclusive {
            // Server's current week ends before today — step forward.
            for _ in 0..<260 {
                guard let next = utcCalendar.date(byAdding: .day, value: 7, to: target) else { break }
                if todayUTC < next { break }
                target = next
            }
        } else if todayUTC < target {
            // Server's current week starts after today — step backward.
            // Recovers from any drift that left the user on a future
            // week record.
            for _ in 0..<260 {
                guard let prev = utcCalendar.date(byAdding: .day, value: -7, to: target) else { break }
                target = prev
                if todayUTC >= target { break }
            }
        }

        guard !utcCalendar.isDate(target, inSameDayAs: week.weekStart) else { return week }
        return try await apiClient.createWeek(weekStart: target, notes: "")
    }

    func fetchWeekByStart(_ weekStart: Date) async throws -> WeekSnapshot? {
        try await apiClient.fetchWeekByStart(weekStart)
    }

    func createWeek(weekStart: Date, notes: String = "") async throws -> WeekSnapshot {
        let week = try await apiClient.createWeek(weekStart: weekStart, notes: notes)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        return week
    }

    func saveWeekMeals(weekID: String, meals: [MealUpdateRequest]) async throws -> WeekSnapshot {
        let week = try await apiClient.updateWeekMeals(weekID: weekID, meals: meals)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    func approveWeek(weekID: String) async throws -> WeekSnapshot {
        let week = try await apiClient.approveWeek(weekID: weekID)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    func regenerateGrocery(weekID: String) async throws -> WeekSnapshot {
        let week = try await apiClient.regenerateGrocery(weekID: weekID)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    func rebalanceDay(weekID: String, mealDate: Date) async throws -> WeekSnapshot {
        let week = try await apiClient.rebalanceDay(weekID: weekID, mealDate: mealDate)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    func generateWeekFromAI(weekID: String, prompt: String) async throws -> WeekSnapshot {
        let week = try await apiClient.generateWeekPlan(weekID: weekID, prompt: prompt)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    func submitMealFeedback(for meal: WeekMeal, sentiment: Int, notes: String) async throws {
        guard let weekID = currentWeek?.weekId else { return }
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
        await refreshWeek()
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

    func toggleGroceryChecked(_ groceryItemID: String) {
        let checked = !checkedGroceryItemIDs.contains(groceryItemID)
        if checked {
            checkedGroceryItemIDs.insert(groceryItemID)
        } else {
            checkedGroceryItemIDs.remove(groceryItemID)
        }
        try? cacheStore.setChecked(checked, groceryItemID: groceryItemID)
    }
}
