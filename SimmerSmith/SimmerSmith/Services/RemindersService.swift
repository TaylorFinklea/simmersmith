import EventKit
import Foundation
import SimmerSmithKit

/// EventKit bridge for the M22 grocery → Apple Reminders sync.
///
/// On iOS 17+ Reminders access is gated by `NSRemindersFullAccessUsageDescription`
/// in Info.plist plus an explicit user grant from
/// `requestFullAccessToReminders`. This service mirrors the
/// `PushService` pattern: a single shared event store, async
/// authorization helpers, and an upsert pass that diffs
/// `[GroceryItem]` against the existing reminders in a chosen list.
///
/// Reminder ↔ grocery-item mapping is handled by
/// `GroceryReminderMapping` (a per-device JSON file). The mapping
/// stores `(grocery_item_id ↔ EKReminder.calendarItemIdentifier)`
/// so we never duplicate reminders across regen runs.
@MainActor
final class RemindersService {
    static let shared = RemindersService()

    let eventStore = EKEventStore()

    private init() {}

    // MARK: - Authorization

    func currentAuthorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestFullAccess() async -> Bool {
        switch currentAuthorizationStatus() {
        case .fullAccess:
            return true
        case .notDetermined:
            do {
                if #available(iOS 17.0, *) {
                    return try await eventStore.requestFullAccessToReminders()
                } else {
                    return try await withCheckedThrowingContinuation { cont in
                        eventStore.requestAccess(to: .reminder) { granted, error in
                            if let error { cont.resume(throwing: error) }
                            else { cont.resume(returning: granted) }
                        }
                    }
                }
            } catch {
                print("[RemindersService] requestFullAccess error: \(error)")
                return false
            }
        case .denied, .restricted, .writeOnly:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - List management

    /// Reminders calendars the user already has. Filtered to writable
    /// ones the user can target as the grocery destination.
    func availableReminderLists() -> [EKCalendar] {
        eventStore.calendars(for: .reminder).filter { $0.allowsContentModifications }
    }

    func calendar(identifier: String) -> EKCalendar? {
        eventStore.calendar(withIdentifier: identifier)
    }

    /// Create a new "SimmerSmith" Reminders list. Returns the new
    /// calendar's identifier (stored in UserDefaults by the caller).
    func createReminderList(name: String) throws -> EKCalendar {
        let calendar = EKCalendar(for: .reminder, eventStore: eventStore)
        calendar.title = name
        // Reminders calendars must live on a source that supports them.
        // Try iCloud first; fall back to the local source.
        let preferredSource = eventStore.sources.first(where: {
            $0.sourceType == .calDAV && $0.title.lowercased().contains("icloud")
        }) ?? eventStore.sources.first(where: { $0.sourceType == .local })
        guard let source = preferredSource else {
            throw NSError(
                domain: "SimmerSmith.Reminders",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No Reminders source available."]
            )
        }
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    // MARK: - Upsert pass

    /// Push the given grocery items into the chosen Reminders list,
    /// updating the in-out `mapping` as new reminders are created.
    /// Items with `isUserRemoved=true` are not handled here — callers
    /// should filter those out and call `deleteReminder(for:)` for any
    /// item whose tombstone newly arrived from the server.
    func upsertReminders(
        in calendar: EKCalendar,
        items: [GroceryItem],
        mapping: inout [String: String]
    ) throws {
        for item in items where !item.isUserRemoved {
            let title = remindersTitle(for: item)
            let body = item.effectiveNotes
            if let reminderID = mapping[item.groceryItemId],
               let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
                if reminder.title != title { reminder.title = title }
                if (reminder.notes ?? "") != body { reminder.notes = body }
                reminder.isCompleted = item.isChecked
                try eventStore.save(reminder, commit: false)
            } else {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = calendar
                reminder.title = title
                reminder.notes = body
                reminder.isCompleted = item.isChecked
                try eventStore.save(reminder, commit: false)
                mapping[item.groceryItemId] = reminder.calendarItemIdentifier
            }
        }
        try eventStore.commit()
    }

    /// Remove the reminder linked to a grocery item id (e.g. when the
    /// server has marked it `isUserRemoved=true`).
    func deleteReminder(forGroceryItemID id: String, mapping: inout [String: String]) throws {
        guard let reminderID = mapping[id] else { return }
        if let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
            try eventStore.remove(reminder, commit: true)
        }
        mapping.removeValue(forKey: id)
    }

    /// Read all reminders in the given calendar. Used by the pull
    /// direction (Reminders → app) to detect user edits made in
    /// Reminders.app. EventKit's callback fires on a background queue
    /// and `[EKReminder]` isn't Sendable; we send the array through
    /// an `@unchecked Sendable` wrapper because EventKit's contract
    /// is that the returned array is owned by the caller and never
    /// mutated after.
    func fetchReminders(in calendar: EKCalendar) async throws -> [EKReminder] {
        let store = eventStore
        let predicate = store.predicateForReminders(in: [calendar])
        let box: ReminderBox = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { results in
                continuation.resume(returning: ReminderBox(reminders: results ?? []))
            }
        }
        return box.reminders
    }

    private struct ReminderBox: @unchecked Sendable {
        let reminders: [EKReminder]
    }

    /// Subscribe to EKEventStoreChanged notifications. Returns the
    /// observation token so callers can `NotificationCenter.default.removeObserver`
    /// during sign-out.
    func observeChanges(handler: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main,
            using: { _ in handler() }
        )
    }

    // MARK: - Title formatting

    /// Build the parse-friendly title used by the future M23 cart
    /// automation skill: `"<qty> <unit> <name>"` (e.g. "2 cups flour"),
    /// falling back to just the name when no quantity is available.
    private func remindersTitle(for item: GroceryItem) -> String {
        var pieces: [String] = []
        if let qty = item.effectiveQuantity {
            pieces.append(formatQuantity(qty))
        } else if !item.quantityText.isEmpty {
            pieces.append(item.quantityText)
        }
        let unit = item.effectiveUnit.trimmingCharacters(in: .whitespaces)
        if !unit.isEmpty { pieces.append(unit) }
        pieces.append(item.ingredientName)
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func formatQuantity(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        return String(format: "%g", value)
    }
}
