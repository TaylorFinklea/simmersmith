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
    ///
    /// Returns `(created, updated)` counts so callers can surface
    /// per-sync feedback. We commit each save individually rather than
    /// batching — the batched pattern intermittently lost writes on
    /// iOS 26 in dogfood (silent success, empty list).
    @discardableResult
    func upsertReminders(
        in calendar: EKCalendar,
        items: [GroceryItem],
        mapping: inout [String: String]
    ) throws -> (created: Int, updated: Int) {
        var created = 0
        var updated = 0
        for item in items where !item.isUserRemoved {
            let title = remindersTitle(for: item)
            let body = remindersBody(for: item)
            if let reminderID = mapping[item.groceryItemId],
               let reminder = eventStore.calendarItem(withIdentifier: reminderID) as? EKReminder {
                if reminder.title != title { reminder.title = title }
                if (reminder.notes ?? "") != body { reminder.notes = body.isEmpty ? nil : body }
                reminder.isCompleted = item.isChecked
                try eventStore.save(reminder, commit: true)
                updated += 1
            } else {
                let reminder = EKReminder(eventStore: eventStore)
                reminder.calendar = calendar
                reminder.title = title
                reminder.notes = body.isEmpty ? nil : body
                reminder.isCompleted = item.isChecked
                try eventStore.save(reminder, commit: true)
                mapping[item.groceryItemId] = reminder.calendarItemIdentifier
                created += 1
            }
        }
        return (created, updated)
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

    /// Reminder title is just the ingredient name. Build 47 moved
    /// quantity + meal context into the body per dogfood feedback:
    /// the title is what the user reads while shopping, and "1/4 cup"
    /// in front of the name is noisy when they just want to see
    /// "fresh dill" at a glance.
    private func remindersTitle(for item: GroceryItem) -> String {
        item.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the Reminders notes/body. First line is quantity + unit,
    /// subsequent lines are meal context and any user-curated notes.
    /// The M23 cart-automation skill reads qty/unit from this body —
    /// the parser is updated to scan the first numeric line.
    private func remindersBody(for item: GroceryItem) -> String {
        var lines: [String] = []
        let qty = item.effectiveQuantity
        let unit = item.effectiveUnit.trimmingCharacters(in: .whitespaces)
        var qtyLine = ""
        if let qty {
            qtyLine = formatQuantity(qty)
            if !unit.isEmpty { qtyLine += " " + unit }
        } else if !item.quantityText.isEmpty {
            qtyLine = item.quantityText
        } else if !unit.isEmpty {
            qtyLine = unit
        }
        if !qtyLine.isEmpty { lines.append(qtyLine) }
        let meals = parseSourceMeals(item.sourceMeals)
        if !meals.isEmpty {
            lines.append("For: \(meals.joined(separator: "; "))")
        }
        if let override = item.notesOverride, !override.isEmpty {
            lines.append(override)
        }
        return lines.joined(separator: "\n")
    }

    /// `source_meals` arrives as semicolon-separated entries shaped
    /// like "Tuesday / Dinner / Recipe Name". Convert each into the
    /// shopping-friendly "Tuesday Dinner — Recipe Name" so the
    /// Reminders preview reads naturally.
    private func parseSourceMeals(_ raw: String) -> [String] {
        raw.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { entry in
                let parts = entry
                    .split(separator: "/")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                switch parts.count {
                case 0: return entry
                case 1: return parts[0]
                case 2: return "\(parts[0]) \(parts[1])"
                default:
                    let day = parts[0]
                    let slot = parts[1].capitalized
                    let recipe = parts[2...].joined(separator: " ")
                    return "\(day) \(slot) — \(recipe)"
                }
            }
    }

    private func formatQuantity(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
        // Common kitchen fractions read better than decimals on a
        // shopping list.
        let rounded3 = (value * 1000).rounded() / 1000
        let fractionMap: [(value: Double, label: String)] = [
            (0.125, "1/8"), (0.25, "1/4"), (0.333, "1/3"), (0.375, "3/8"),
            (0.5, "1/2"), (0.625, "5/8"), (0.667, "2/3"), (0.75, "3/4"),
            (0.875, "7/8")
        ]
        let whole = floor(rounded3)
        let frac = rounded3 - whole
        if let match = fractionMap.first(where: { abs($0.value - frac) < 0.01 }) {
            return whole > 0 ? "\(Int(whole)) \(match.label)" : match.label
        }
        return String(format: "%g", value)
    }
}
