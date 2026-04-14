import Foundation
import UserNotifications
import SimmerSmithKit

@MainActor
final class NotificationManager: @unchecked Sendable {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            return granted
        } catch {
            return false
        }
    }

    func checkPermission() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Dinner Reminder

    /// Schedule a daily "What's for dinner?" reminder at the given hour.
    func scheduleDinnerReminder(hour: Int = 16, minute: Int = 0, recipeName: String?) {
        let id = "dinner-reminder"
        center.removePendingNotificationRequests(withIdentifiers: [id])

        let content = UNMutableNotificationContent()
        content.title = "What's for dinner?"
        if let name = recipeName, !name.isEmpty {
            content.body = "Tonight: \(name)"
        } else {
            content.body = "Check your meal plan for tonight."
        }
        content.sound = .default
        content.categoryIdentifier = "MEAL_REMINDER"

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        center.add(request)
    }

    /// Schedule reminders for all meals in a week.
    func scheduleMealReminders(for meals: [WeekMeal], reminderMinutesBefore: Int = 30) {
        // Remove all existing meal reminders
        center.removePendingNotificationRequests(withIdentifiers: meals.map { "meal-\($0.mealId)" })

        let calendar = Calendar.current

        for meal in meals {
            let slotHour: Int
            switch meal.slot.lowercased() {
            case "breakfast": slotHour = 8
            case "lunch": slotHour = 12
            case "dinner": slotHour = 18
            case "snack": slotHour = 15
            default: continue
            }

            guard let reminderDate = calendar.date(
                bySettingHour: slotHour,
                minute: 0,
                second: 0,
                of: meal.mealDate
            )?.addingTimeInterval(TimeInterval(-reminderMinutesBefore * 60)) else { continue }

            // Don't schedule reminders in the past
            guard reminderDate > Date() else { continue }

            let content = UNMutableNotificationContent()
            content.title = "\(meal.slot.capitalized) time"
            content.body = meal.recipeName
            content.sound = .default
            content.categoryIdentifier = "MEAL_REMINDER"

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminderDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: "meal-\(meal.mealId)", content: content, trigger: trigger)

            center.add(request)
        }
    }

    // MARK: - Grocery Reminder

    /// Schedule a grocery shopping reminder for a specific day.
    func scheduleGroceryReminder(dayOfWeek: Int = 7, hour: Int = 9, itemCount: Int) {
        let id = "grocery-reminder"
        center.removePendingNotificationRequests(withIdentifiers: [id])

        guard itemCount > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Grocery day!"
        content.body = "You have \(itemCount) items on your list."
        content.sound = .default
        content.categoryIdentifier = "GROCERY_REMINDER"

        var dateComponents = DateComponents()
        dateComponents.weekday = dayOfWeek  // 1 = Sunday, 7 = Saturday
        dateComponents.hour = hour

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        center.add(request)
    }

    // MARK: - Cancel All

    func cancelAllReminders() {
        center.removeAllPendingNotificationRequests()
    }
}
