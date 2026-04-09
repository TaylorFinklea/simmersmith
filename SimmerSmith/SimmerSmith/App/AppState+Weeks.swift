import Foundation
import SimmerSmithKit

extension AppState {
    func refreshWeek() async {
        guard hasSavedConnection else { return }
        syncPhase = .loading
        do {
            currentWeek = try await apiClient.fetchCurrentWeek()
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
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    func fetchWeeks(limit: Int = 12) async throws -> [WeekSummary] {
        try await apiClient.fetchWeeks(limit: limit)
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
