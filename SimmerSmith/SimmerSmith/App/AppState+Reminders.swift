import EventKit
import Foundation
import SimmerSmithKit

extension AppState {
    // MARK: - Settings

    static let reminderListIDKey = "simmersmith.grocery.reminderListID"
    static let lastSyncedAtKey = "simmersmith.grocery.lastSyncedAt"
    static let lastSyncedSummaryKey = "simmersmith.grocery.lastSyncedSummary"

    /// Hydrate the @Observable stored properties from UserDefaults.
    /// Called once during `loadCachedData()` so Settings opens with
    /// the right toggle state and "Last synced" summary.
    func loadReminderState() {
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: Self.reminderListIDKey)
        reminderListIdentifier = (id?.isEmpty ?? true) ? nil : id
        lastReminderSyncAt = defaults.object(forKey: Self.lastSyncedAtKey) as? Date
        lastReminderSyncSummary = defaults.string(forKey: Self.lastSyncedSummaryKey)
        if reminderListIdentifier != nil {
            startObservingReminders()
        }
    }

    /// Subscribe to `EKEventStoreChanged` so adds/edits in
    /// Reminders.app round-trip back into SimmerSmith without the
    /// user waiting for iOS to schedule the BGAppRefreshTask. Idempotent
    /// — calling twice doesn't create duplicate subscriptions.
    func startObservingReminders() {
        if reminderObserver != nil { return }
        reminderObserver = RemindersService.shared.observeChanges { [weak self] in
            self?.scheduleReminderPull()
        }
    }

    func stopObservingReminders() {
        if let token = reminderObserver {
            NotificationCenter.default.removeObserver(token)
        }
        reminderObserver = nil
        reminderChangeDebounce?.cancel()
        reminderChangeDebounce = nil
    }

    /// Debounce iCloud's chatty change stream — collapse a burst of
    /// `EKEventStoreChanged` notifications into one server-bound sync.
    private func scheduleReminderPull() {
        reminderChangeDebounce?.cancel()
        reminderChangeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.handleReminderStoreChange()
        }
    }

    /// Persist the chosen Reminders calendar id, mirroring the
    /// in-memory @Observable property. Always invoked through this
    /// helper so the UserDefaults write and SwiftUI invalidation stay
    /// in sync.
    private func setReminderListIdentifier(_ value: String?) {
        reminderListIdentifier = (value?.isEmpty ?? true) ? nil : value
        if let value, !value.isEmpty {
            UserDefaults.standard.set(value, forKey: Self.reminderListIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.reminderListIDKey)
        }
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
        setReminderListIdentifier(calendar.calendarIdentifier)
        startObservingReminders()
        // Bidirectional first sync: pull anything the user already had
        // in Reminders into SimmerSmith, then push the merged set
        // back so the list is identical on both sides.
        await handleReminderStoreChange()
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
        setReminderListIdentifier(nil)
        lastReminderSyncAt = nil
        lastReminderSyncSummary = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedAtKey)
        UserDefaults.standard.removeObject(forKey: Self.lastSyncedSummaryKey)
        stopObservingReminders()
    }

    // MARK: - Push direction (app → Reminders)

    /// Mirror the current week's grocery items into the user's chosen
    /// Reminders list. Failures surface via `lastErrorMessage` so the
    /// user can see why the list stayed empty (no week loaded yet,
    /// permission revoked at the system level, EventKit save error,
    /// etc.). Item counts go in the human-readable summary.
    func syncGroceryToReminders() async {
        // Clear any stale error so the user can tell whether *this*
        // sync attempt succeeded or failed.
        lastErrorMessage = nil
        guard let calendarID = reminderListIdentifier else {
            return
        }
        guard let calendar = RemindersService.shared.calendar(identifier: calendarID) else {
            lastErrorMessage = "Reminders list isn't available — pick another in Settings."
            return
        }
        guard let week = currentWeek else {
            // Don't fail loudly here — refreshAll() will trigger sync
            // again once the week loads. Show a hint anyway so the
            // user knows nothing populated.
            updateSyncSummary("No week loaded yet — sync will retry on refresh.")
            return
        }
        let items = week.groceryItems
        var mapping = GroceryReminderMapping.shared.load(calendarID: calendarID)

        // Propagate tombstones first so the upsert pass sees a clean state.
        let visible = items.filter { !$0.isUserRemoved }
        let visibleIDs = Set(visible.map(\.groceryItemId))
        var deleted = 0
        for (groceryID, _) in mapping where !visibleIDs.contains(groceryID) {
            do {
                try RemindersService.shared.deleteReminder(
                    forGroceryItemID: groceryID,
                    mapping: &mapping
                )
                deleted += 1
            } catch {
                print("[AppState+Reminders] delete reminder for \(groceryID) failed: \(error)")
            }
        }

        do {
            let counts = try RemindersService.shared.upsertReminders(
                in: calendar,
                items: visible,
                mapping: &mapping
            )
            GroceryReminderMapping.shared.save(mapping, calendarID: calendarID)
            let now = Date()
            lastReminderSyncAt = now
            UserDefaults.standard.set(now, forKey: Self.lastSyncedAtKey)
            updateSyncSummary(
                "Synced \(visible.count) item\(visible.count == 1 ? "" : "s") "
                + "(\(counts.created) created, \(counts.updated) updated"
                + (deleted > 0 ? ", \(deleted) removed" : "")
                + ")."
            )
        } catch {
            print("[AppState+Reminders] syncGroceryToReminders failed: \(error)")
            lastErrorMessage = "Reminders sync failed: \(error.localizedDescription)"
            updateSyncSummary("Last sync failed: \(error.localizedDescription)")
        }
    }

    private func updateSyncSummary(_ summary: String) {
        // @Observable stored property — assignment triggers SwiftUI
        // re-render. UserDefaults persistence is a side effect.
        lastReminderSyncSummary = summary
        UserDefaults.standard.set(summary, forKey: Self.lastSyncedSummaryKey)
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
        // Build TWO lookup tables: by id (for mapped items) and by
        // normalized title (for the unmapped-but-matching case that
        // caused the build-45 duplicate explosion). EKEventStore can
        // mint a fresh `calendarItemIdentifier` after iCloud round-
        // trips a reminder, so the mapping miss-rate is non-zero;
        // without title dedup we re-create the row every sync and
        // each new row syncs out as a new reminder, infinite loop.
        let serverByID = Dictionary(uniqueKeysWithValues: serverItems.map { ($0.groceryItemId, $0) })
        let serverByTitle: [String: GroceryItem] = Dictionary(
            serverItems.map { (Self.normalizedReminderTitle($0.ingredientName), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let reverseMapping: [String: String] = Dictionary(
            uniqueKeysWithValues: mapping.map { ($0.value, $0.key) }
        )

        // Bail if we don't have a fresh server view of the week —
        // running the add path against an empty list re-creates
        // every reminder server-side. Better to no-op than corrupt.
        guard !serverItems.isEmpty || reminders.isEmpty else {
            print("[AppState+Reminders] skipping pull: server items not loaded yet (\(reminders.count) reminders pending).")
            return
        }

        // 1. Reminders that we know about: detect check-state diffs and
        //    push them back to the server.
        //
        // Build 80 — bail mid-loop when iOS revokes our background
        // budget (or the timeout in BackgroundSyncService fires). Each
        // iteration can do up to two network round-trips, so a long
        // grocery list can easily push past iOS's 30s BGAppRefresh
        // budget; without these checks the cancel from the BG task
        // expiration handler is a no-op and iOS SIGKILLs the process.
        var seenServerIDs: Set<String> = []
        for reminder in reminders {
            if Task.isCancelled {
                print("[AppState+Reminders] pull cancelled — bailing after \(seenServerIDs.count) of \(reminders.count) reminders")
                GroceryReminderMapping.shared.save(mapping, calendarID: calendarID)
                return
            }
            let reminderID = reminder.calendarItemIdentifier
            // Title-based recovery: if a reminder isn't in our mapping
            // but its title matches an existing server item, treat it
            // as the same row and re-bind the mapping. This happens
            // after iCloud syncs the reminder back with a new
            // identifier, after a fresh install rehydrates the
            // mapping cache, and after the user manually re-creates a
            // reminder with the same title.
            if reverseMapping[reminderID] == nil {
                let titleKey = Self.normalizedReminderTitle(reminder.title ?? "")
                if let existing = serverByTitle[titleKey] {
                    mapping[existing.groceryItemId] = reminderID
                    seenServerIDs.insert(existing.groceryItemId)
                    if reminder.isCompleted != existing.isChecked {
                        do {
                            let updated = reminder.isCompleted
                                ? try await apiClient.checkGroceryItem(weekID: weekID, itemID: existing.groceryItemId)
                                : try await apiClient.uncheckGroceryItem(weekID: weekID, itemID: existing.groceryItemId)
                            replaceGroceryItemInCurrentWeek(updated)
                            if updated.isChecked { checkedGroceryItemIDs.insert(existing.groceryItemId) }
                            else { checkedGroceryItemIDs.remove(existing.groceryItemId) }
                        } catch {
                            print("[AppState+Reminders] check propagation (title-rebind) failed: \(error)")
                        }
                    }
                    continue
                }
            }
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
            // 2. Genuinely new reminder added directly in Reminders.app
            //    — create a matching server-side user-added grocery
            //    item. We've already checked title dedup above, so if
            //    we get here the title is truly new.
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
        //    Reminders.app — clean up our LOCAL mapping only.
        //
        // We deliberately do NOT propagate removals back to the server
        // anymore. The previous version PATCHed `removed=true` here,
        // but EKEventStore's `fetchReminders` returns a partial list
        // mid-sync, on iCloud round-trips, and after toggling the
        // master Reminders permission. Build 35/36 dogfood lost
        // user-curated items because the partial fetch tombstoned
        // everything the device hadn't re-synced yet. Removal is now
        // strictly app→Reminders: swipe in iOS to remove. The skill
        // and Reminders.app stay read-only/check-state for the
        // user's grocery list.
        let staleMappingIDs: [String] = mapping
            .filter { !seenServerIDs.contains($0.key) }
            .compactMap { (groceryID, reminderID) -> String? in
                let reminderStillPresent = reminders.contains { $0.calendarItemIdentifier == reminderID }
                guard !reminderStillPresent else { return nil }
                return groceryID
            }
        for groceryID in staleMappingIDs {
            mapping.removeValue(forKey: groceryID)
        }
        if !staleMappingIDs.isEmpty {
            print("[AppState+Reminders] dropped \(staleMappingIDs.count) stale mapping entr\(staleMappingIDs.count == 1 ? "y" : "ies"); next sync will recreate reminders for items still on SimmerSmith.")
        }

        GroceryReminderMapping.shared.save(mapping, calendarID: calendarID)
    }

    // MARK: - Lifecycle

    /// Called from `resetConnection` to clear every Reminders mapping.
    func clearReminderMappings() {
        GroceryReminderMapping.shared.clearAll()
        clearReminderList()
    }

    /// Title canonicalization for the dedup hash — collapse whitespace,
    /// case-fold, and trim the trailing punctuation Reminders.app
    /// occasionally appends.
    static func normalizedReminderTitle(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
    }
}
