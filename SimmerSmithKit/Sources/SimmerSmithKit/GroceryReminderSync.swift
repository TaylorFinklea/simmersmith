import Foundation

/// Pure, host-testable helpers backing the grocery ↔ Apple Reminders bridge
/// (`SimmerSmith/App/AppState+Reminders.swift` + `Services/RemindersService.swift`).
///
/// simmersmith-990.7 pulled the title/body formatting and the per-reminder match /
/// stale-cleanup / check-state-merge decisions out of those EventKit-touching files so
/// they unit-test headlessly. No behavior changed in the extraction — every function here
/// mirrors what shipped inline.
///
/// FROZEN CONTRACT: `title(ingredientName:)`'s output is read by the
/// `skills/simmersmith-shopping` cart-automation skill (see its `parser.py`). Changing the
/// shape here requires a matching change to that parser.
public enum GroceryReminderSync {

    // MARK: - Title / body formatting (RemindersService.remindersTitle/remindersBody mirror)

    /// The reminder's title: just the trimmed ingredient name. Quantity/unit/meal context
    /// live in the body (see `body(quantity:unit:...)`) — the title is what the user reads
    /// at a glance while shopping.
    public static func title(ingredientName: String) -> String {
        ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The reminder's notes/body. First line is quantity + unit (or `quantityText`, or a
    /// bare unit when there's no quantity), optionally prefixed with "At <store>" and
    /// followed by "For: <meals>" / any user-curated notes override.
    public static func body(
        quantity: Double?,
        unit: String,
        quantityText: String,
        storeLabel: String,
        sourceMeals: String,
        notesOverride: String?
    ) -> String {
        var lines: [String] = []
        let store = storeLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !store.isEmpty {
            lines.append("At \(store)")
        }
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        var qtyLine = ""
        if let quantity {
            qtyLine = formatQuantity(quantity)
            if !trimmedUnit.isEmpty { qtyLine += " " + trimmedUnit }
        } else if !quantityText.isEmpty {
            qtyLine = quantityText
        } else if !trimmedUnit.isEmpty {
            qtyLine = trimmedUnit
        }
        if !qtyLine.isEmpty { lines.append(qtyLine) }
        let meals = parseSourceMeals(sourceMeals)
        if !meals.isEmpty {
            lines.append("For: \(meals.joined(separator: "; "))")
        }
        if let notesOverride, !notesOverride.isEmpty {
            lines.append(notesOverride)
        }
        return lines.joined(separator: "\n")
    }

    /// Render a decimal quantity the way a shopping list reads best: whole numbers as-is,
    /// common kitchen fractions as "1/2" / "1 1/2" / etc., anything else via `%g`.
    public static func formatQuantity(_ value: Double) -> String {
        if value.rounded() == value { return String(Int(value)) }
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

    /// `source_meals` arrives as semicolon-separated entries shaped like
    /// "Tuesday / Dinner / Recipe Name". Convert each into the shopping-friendly
    /// "Tuesday Dinner — Recipe Name" so the Reminders preview reads naturally.
    public static func parseSourceMeals(_ raw: String) -> [String] {
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

    // MARK: - Title normalization (AppState.normalizedReminderTitle mirror)

    /// Canonicalize a title for the dedup hash — collapse whitespace, case-fold, and trim
    /// the trailing punctuation Reminders.app occasionally appends.
    public static func normalizedTitle(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!"))
    }

    // MARK: - Per-reminder match (handleReminderStoreChange step 1)

    public enum MatchResult: Equatable, Sendable {
        /// Reminder already mapped to a grocery item that's still present server-side.
        case mapped(groceryItemID: String)
        /// Unmapped reminder whose (normalized) title matches an existing grocery item —
        /// re-bind rather than create a duplicate (the iCloud-round-trip recovery path).
        case titleRebind(groceryItemID: String)
        /// Neither — a genuinely new reminder (or a mapped id whose item vanished
        /// server-side; the caller re-creates it as a new user-added item, matching the
        /// pre-extraction fallthrough behavior).
        case unmatched
    }

    /// Resolve one Reminders.app reminder against the mapping + server-item lookups.
    /// Mirrors `handleReminderStoreChange`'s exact precedence: an existing id-mapping is
    /// tried FIRST and, if its target item is gone, falls straight to `.unmatched` —
    /// title-rebind is only attempted when there was no id-mapping at all.
    public static func match(
        reminderID: String,
        reminderTitle: String,
        reverseMapping: [String: String],
        serverItemIDs: Set<String>,
        serverItemIDsByNormalizedTitle: [String: String]
    ) -> MatchResult {
        if let groceryItemID = reverseMapping[reminderID] {
            return serverItemIDs.contains(groceryItemID) ? .mapped(groceryItemID: groceryItemID) : .unmatched
        }
        let key = normalizedTitle(reminderTitle)
        if let groceryItemID = serverItemIDsByNormalizedTitle[key] {
            return .titleRebind(groceryItemID: groceryItemID)
        }
        return .unmatched
    }

    // MARK: - Stale-mapping cleanup (handleReminderStoreChange step 3)

    /// Mapping entries whose reminder never showed up in this pull pass — dropped from the
    /// LOCAL mapping only (never propagated as a removal; see the call site's comment on
    /// why removals stay strictly app→Reminders).
    public static func staleMappingIDs(
        mapping: [String: String],
        seenGroceryItemIDs: Set<String>,
        presentReminderIDs: Set<String>
    ) -> [String] {
        mapping
            .filter { !seenGroceryItemIDs.contains($0.key) }
            .compactMap { groceryItemID, reminderID in
                presentReminderIDs.contains(reminderID) ? nil : groceryItemID
            }
    }

    // MARK: - Check-state two-way merge

    /// Whether a Reminders.app check-state edit should propagate to the grocery item (pull
    /// direction). Reminders.app is the source of truth here — any diff pushes the
    /// reminder's `isCompleted` onto the item. The opposite direction (push: server →
    /// Reminders) is an unconditional assignment in `RemindersService.upsertReminders`, so
    /// together the pair is "last write, from whichever side changed, wins" — no separate
    /// merge decision needed on the push side.
    public static func reminderCheckStateShouldPropagate(
        reminderIsCompleted: Bool,
        itemIsChecked: Bool
    ) -> Bool {
        reminderIsCompleted != itemIsChecked
    }
}
