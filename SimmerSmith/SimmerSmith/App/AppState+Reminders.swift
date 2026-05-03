import EventKit
import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - Settings

    private static let reminderListIDKey = "simmersmith.grocery.reminderListID"
    private static let lastSyncedAtKey = "simmersmith.grocery.lastSyncedAt"

    /// Identifier of the EKCalendar the user picked as the Reminders
    /// destination. Empty/nil means sync is OFF.
    var reminderListIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.reminderListIDKey) }
        set {
            if let value = newValue, !value.isEmpty {
                UserDefaults.standard.set(value, forKey: Self.reminderListIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.reminderListIDKey)
            }
        }
    }

    var lastReminderSyncAt: Date? {
        UserDefaults.standard.object(forKey: Self.lastSyncedAtKey) as? Date
    }

    // MARK: - List picker / authorization

    /// Trigger the iOS permission prompt and return whether full access
    /// was granted. Bound to the `Sync to Reminders` toggle in Settings.
    func requestRemindersAccess() async -> Bool {
        await RemindersService.shared.requestFullAccess()
    }

    /// Returns the user's current Reminders lists for the picker UI.
    func availableReminderLists() -> [EKCalendar] {
        RemindersService.shared.availableReminderLists()
    }

    func chooseReminderList(_ calendar: EKCalendar) async {
        // Switching lists: drop the prior mapping so we don't reuse
        // stale calendarItemIdentifiers on the new list.
        if let previous = reminderListIdentifier, previous != calendar.calendarIdentifier {
            GroceryReminderMapping.shared.clear(calendarID: previous)
        }
        reminderListIdentifier = calendar.calendarIdentifier
        await syncGroceryToReminders()
    }

    func createAndChooseReminderList(name: String) async -> Bool {
        do {
            let calendar = try RemindersService.shared.createReminderList(name: name)
            await chooseReminderList(calendar)
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func clearReminderList() {
        if let id = reminderListIdentifier {
            GroceryReminderMapping.shared.clear(calendarID: id)
        }
        reminderListIdentifier = nil
    }

    // MARK: - Push direction (app → Reminders)

    /// Mirror the current week's grocery items into the user's chosen
    /// Reminders list. Best-effort: failures don't surface a banner —
    /// the toggle in Settings is the user-facing mechanism for opting
    /// out if the bridge misbehaves.
    func syncGroceryToReminders() async {
        guard
            let calendarID = reminderListIdentifier,
            let calendar = RemindersService.shared.calendar(identifier: calendarID),
            let items = currentWeek?.groceryItems
        else { return }

        var mapping = GroceryReminderMapping.shared.load(calendarID: calendarID)

        // Propagate tombstones: anything in our mapping that the server
        // now flags as removed should also disappear from Reminders.
        let visible = items.filter { !$0.isUserRemoved }
        let visibleIDs = Set(visible.map(\.groceryItemId))
        for (groceryID, _) in mapping where !visibleIDs.contains(groceryID) {
            try? RemindersService.shared.deleteReminder(
                forGroceryItemID: groceryID,
                mapping: &mapping
            )
        }

        do {
            try RemindersService.shared.upsertReminders(
                in: calendar,
                items: visible,
                mapping: &mapping
            )
            GroceryReminderMapping.shared.save(mapping, calendarID: calendarID)
            UserDefaults.standard.set(Date(), forKey: Self.lastSyncedAtKey)
        } catch {
            print("[AppState+Reminders] syncGroceryToReminders failed: \(error)")
        }
    }

    // MARK: - Pull direction (Reminders → app)

    /// Walk the user's chosen Reminders list, diff against the
    /// `groceryReminderMapping`, and propagate edits made directly in
    /// Reminders.app back to the server. Triggered by the
    /// `EKEventStoreChanged` notification (debounced upstream).
    func handleReminderStoreChange() async {
        guard
            hasSavedConnection,
            let weekID = currentWeek?.weekId,
            let calendarID = reminderListIdentifier,
            let calendar = RemindersService.shared.calendar(identifier: calendarID)
        else { return }

        var mapping = GroceryReminderMapping.shared.load(calendarID: calendarID)
        let reminders: [EKReminder]
        do {
            reminders = try await RemindersService.shared.fetchReminders(in: calendar)
        } catch {
            print("[AppState+Reminders] fetchReminders failed: \(error)")
            return
        }

        let serverItems = currentWeek?.groceryItems ?? []
        let serverByID = Dictionary(uniqueKeysWithValues: serverItems.map { ($0.groceryItemId, $0) })
        let reverseMapping: [String: String] = Dictionary(
            uniqueKeysWithValues: mapping.map { ($0.value, $0.key) }
        )

        // 1. Reminders that we know about: detect check-state diffs and
        //    push them back to the server.
        var seenServerIDs: Set<String> = []
        for reminder in reminders {
            let reminderID = reminder.calendarItemIdentifier
            if let groceryID = reverseMapping[reminderID], let serverItem = serverByID[groceryID] {
                seenServerIDs.insert(groceryID)
                if reminder.isCompleted != serverItem.isChecked {
                    do {
                        let updated = reminder.isCompleted
                            ? try await apiClient.checkGroceryItem(weekID: weekID, itemID: groceryID)
                            : try await apiClient.uncheckGroceryItem(weekID: weekID, itemID: groceryID)
                        replaceGroceryItemInCurrentWeek(updated)
                        if updated.isChecked { checkedGroceryItemIDs.insert(groceryID) }
                        else { checkedGroceryItemIDs.remove(groceryID) }
                    } catch {
                        print("[AppState+Reminders] check propagation failed: \(error)")
                    }
                }
                continue
            }
            // 2. New reminder added directly in Reminders.app — create
            //    a matching server-side user-added grocery item.
            let title = (reminder.title ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { continue }
            do {
                let item = try await apiClient.addGroceryItem(
                    weekID: weekID,
                    body: .init(name: title, notes: reminder.notes ?? "")
                )
                mapping[item.groceryItemId] = reminderID
                insertGroceryItemInCurrentWeek(item)
            } catch {
                print("[AppState+Reminders] addGroceryItem from reminder failed: \(error)")
            }
        }

        // 3. Mapped grocery items whose reminders disappeared from
        //    Reminders.app — treat as user-removed.
        for (groceryID, _) in mapping where !seenServerIDs.contains(groceryID) {
            // Skip items we never saw in the fetched reminders set —
            // EKEventStore can return a partial set if the calendar
            // is mid-sync. We only act when the server still has the
            // grocery item (i.e. the user really pruned it).
            if !reminders.contains(where: { $0.calendarItemIdentifier == mapping[groceryID] }) {
                if serverByID[groceryID] != nil {
                    do {
                        _ = try await apiClient.patchGroceryItem(
                            weekID: weekID,
                            itemID: groceryID,
                            body: {
                                var b = SimmerSmithAPIClient.GroceryItemPatchBody()
                                b.removed = true
                                return b
                            }()
                        )
                        removeGroceryItemFromCurrentWeek(id: groceryID)
                        checkedGroceryItemIDs.remove(groceryID)
                        mapping.removeValue(forKey: groceryID)
                    } catch {
                        print("[AppState+Reminders] remove propagation failed: \(error)")
                    }
                }
            }
        }

        GroceryReminderMapping.shared.save(mapping, calendarID: calendarID)
    }

    // MARK: - Lifecycle

    /// Called from `resetConnection` to clear every Reminders mapping.
    func clearReminderMappings() {
        GroceryReminderMapping.shared.clearAll()
        reminderListIdentifier = nil
    }
}
