import Foundation

/// Per-device JSON store of `(grocery_item_id ↔ EKReminder.calendarItemIdentifier)`.
/// Lives in `UserDefaults` keyed by the chosen `EKCalendar.calendarIdentifier`
/// so a user who switches their target Reminders list doesn't bleed
/// stale mappings across.
///
/// Mapping is per-device (NOT shared across household members) because
/// each iOS install has its own Reminders database — household sync
/// happens on the server. When a member opens the app, they sync the
/// shared server-side grocery list into *their* local Reminders list.
@MainActor
final class GroceryReminderMapping {
    static let shared = GroceryReminderMapping()

    private let defaults: UserDefaults
    private let keyPrefix = "simmersmith.grocery.reminderMapping."

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for calendarID: String) -> String {
        "\(keyPrefix)\(calendarID)"
    }

    /// Load the mapping for a calendar id; empty dict on first use.
    func load(calendarID: String) -> [String: String] {
        guard
            let data = defaults.data(forKey: key(for: calendarID)),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ mapping: [String: String], calendarID: String) {
        guard let data = try? JSONEncoder().encode(mapping) else { return }
        defaults.set(data, forKey: key(for: calendarID))
    }

    func clear(calendarID: String) {
        defaults.removeObject(forKey: key(for: calendarID))
    }

    /// Wipe every persisted mapping — used on sign-out.
    func clearAll() {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: k)
        }
    }
}
