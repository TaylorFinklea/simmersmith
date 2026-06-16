import Foundation

// SP-A Phase 5 — verbatim port of the event↔week cross-aggregate merge lifecycle from
// app/services/event_grocery.py. Pure value-type functions (no CloudKit) → unit-tested
// headlessly; the CKSyncEngine adapter applies the returned mutations.
//
// Two DISTINCT deletion semantics (the review's blocking finding): dedupe (ConflictRepair)
// TOMBSTONES losers; unmerge HARD-DELETES event-only rows. They are not the same — this engine
// returns `hardDeletedRecordNames` for the unmerge case, never tombstones.
//
// `EventGroceryItem.eventQuantity` here is the event row's contribution (= prod total_quantity);
// it accumulates into the WEEK GroceryItem.eventQuantity. `Event.eventDate == ""` means "no date".
public enum EventMergeEngine {

    /// Pair of match keys (`_match_keys`, event_grocery.py:285). base wins when an id exists;
    /// name falls back to normalized name. Both carry the normalized unit.
    struct MatchKey: Hashable { let a: String; let b: String; let c: String }

    static func matchKeys(baseIngredientID: String?, normalizedName: String, unit: String)
        -> (base: MatchKey, name: MatchKey) {
        let base = baseIngredientID ?? ""
        let norm = normalizedName
        let u = GroceryNormalize.unit(unit)
        let baseKey = base.isEmpty ? MatchKey(a: "", b: u, c: norm) : MatchKey(a: base, b: u, c: "")
        let nameKey = MatchKey(a: norm, b: u, c: "")
        return (baseKey, nameKey)
    }

    private static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    // MARK: merge_event_into_week (event_grocery.py:309)

    public struct EventMergeOutcome: Equatable {
        public var weekRows: [GroceryItem]        // input week rows (some updated) + created, by recordName
        public var createdRecordNames: [String]
        public var eventRows: [EventGroceryItem]  // pointer updates, original order
        public var linkedWeekID: String?
        public var matched: Int
        public var created: Int
        public var unmatchedTextOnly: Int
    }

    /// `makeID` mints a recordName for each newly-created event-only week row.
    public static func mergeEventIntoWeek(
        event: Event, eventRows: [EventGroceryItem], weekRows: [GroceryItem],
        weekID: String, makeID: () -> String
    ) -> EventMergeOutcome {
        var rowsByName: [String: GroceryItem] = [:]
        var index: [MatchKey: String] = [:]            // first-wins for existing rows
        for row in weekRows {
            rowsByName[row.recordName] = row
            let (bk, nk) = matchKeys(baseIngredientID: row.baseIngredientID, normalizedName: row.normalizedName, unit: row.unit)
            if index[bk] == nil { index[bk] = row.recordName }
            if index[nk] == nil { index[nk] = row.recordName }
        }

        var events = eventRows
        var createdNames: [String] = []
        var matched = 0, created = 0, textOnly = 0

        for i in events.indices {
            let ev = events[i]
            // Idempotency: an event row already merged into this week is skipped.
            if ev.mergedIntoWeekID == weekID && ev.mergedIntoGroceryItemID != nil { continue }
            // Quantity-text-only contribution: mark merged for traceability, no numeric add.
            guard let contribution = ev.eventQuantity else {
                textOnly += 1
                events[i].mergedIntoWeekID = weekID
                continue
            }
            let (bk, nk) = matchKeys(baseIngredientID: ev.baseIngredientID, normalizedName: ev.normalizedName, unit: ev.unit)
            if let matchName = index[bk] ?? index[nk], var match = rowsByName[matchName] {
                match.eventQuantity = round2((match.eventQuantity ?? 0) + contribution)
                rowsByName[matchName] = match
                events[i].mergedIntoWeekID = weekID
                events[i].mergedIntoGroceryItemID = matchName
                matched += 1
            } else {
                let newID = makeID()
                let newRow = GroceryItem(
                    recordName: newID, weekID: weekID,
                    baseIngredientID: ev.baseIngredientID, ingredientVariationID: ev.ingredientVariationID,
                    resolutionStatus: ev.resolutionStatus, unit: ev.unit, quantityText: ev.quantityText,
                    normalizedName: ev.normalizedName, totalQuantity: nil, notes: ev.notes,
                    sourceMeals: "event:\(event.name)", reviewFlag: ev.reviewFlag,
                    eventQuantity: contribution)
                rowsByName[newID] = newRow
                createdNames.append(newID)
                events[i].mergedIntoWeekID = weekID
                events[i].mergedIntoGroceryItemID = newID
                // Index so later event rows in THIS call dedupe onto the new row (prod overwrites).
                let (nbk, nnk) = matchKeys(baseIngredientID: newRow.baseIngredientID, normalizedName: newRow.normalizedName, unit: newRow.unit)
                index[nbk] = newID
                index[nnk] = newID
                created += 1
            }
        }

        return EventMergeOutcome(
            weekRows: rowsByName.values.sorted { $0.recordName < $1.recordName },
            createdRecordNames: createdNames.sorted(),
            eventRows: events, linkedWeekID: weekID,
            matched: matched, created: created, unmatchedTextOnly: textOnly)
    }

    // MARK: unmerge_event_from_week (event_grocery.py:475) — HARD delete, not tombstone

    public struct EventUnmergeOutcome: Equatable {
        public var weekRows: [GroceryItem]        // remaining rows (hard-deleted removed), by recordName
        public var hardDeletedRecordNames: [String]
        public var eventRows: [EventGroceryItem]
        public var linkedWeekID: String?
        public var clearedLink: Bool
        public var touched: Int
    }

    public static func unmergeEventFromWeek(
        eventRows: [EventGroceryItem], weekRows: [GroceryItem], weekID: String, eventName: String,
        keepLink: Bool = false, currentLinkedWeekID: String?
    ) -> EventUnmergeOutcome {
        var rowsByName: [String: GroceryItem] = [:]
        for row in weekRows { rowsByName[row.recordName] = row }

        var events = eventRows
        var hardDeleted: [String] = []
        var touched = 0

        for i in events.indices {
            let ev = events[i]
            if ev.mergedIntoWeekID != weekID { continue }
            if let targetName = ev.mergedIntoGroceryItemID, var target = rowsByName[targetName],
               let contribution = ev.eventQuantity {
                let current = target.eventQuantity ?? 0
                let newQty = round2(current - contribution)
                target.eventQuantity = newQty > 0.0001 ? newQty : nil
                // Strip legacy "+event: <name>" note parts (pre-M22.2).
                if !target.notes.isEmpty {
                    target.notes = target.notes.components(separatedBy: "; ")
                        .filter { !$0.isEmpty && !$0.contains("+event: \(eventName)") }
                        .joined(separator: "; ")
                }
                // Event-only rows self-delete (HARD) when their contribution is gone and the user
                // hasn't invested. event-only detected name-agnostically by the "event:" prefix.
                let eventOnly = target.sourceMeals.hasPrefix("event:")
                let noRemainingQty = (target.totalQuantity ?? 0) <= 0 && (target.eventQuantity ?? 0) <= 0
                let noUserInvestment = target.quantityOverride == nil && target.unitOverride == nil
                    && target.notesOverride == nil && !target.check.isChecked && !target.isUserAdded
                if eventOnly && noRemainingQty && noUserInvestment {
                    rowsByName[targetName] = nil
                    hardDeleted.append(targetName)
                } else {
                    rowsByName[targetName] = target
                }
            }
            events[i].mergedIntoWeekID = nil
            events[i].mergedIntoGroceryItemID = nil
            touched += 1
        }

        var linkedWeekID = currentLinkedWeekID
        var cleared = false
        if !keepLink && currentLinkedWeekID == weekID { linkedWeekID = nil; cleared = true }

        return EventUnmergeOutcome(
            weekRows: rowsByName.values.sorted { $0.recordName < $1.recordName },
            hardDeletedRecordNames: hardDeleted.sorted(),
            eventRows: events, linkedWeekID: linkedWeekID, clearedLink: cleared, touched: touched)
    }

    // MARK: _resolve_target_week (event_grocery.py:396)

    public static func resolveTargetWeek(event: Event, weeks: [Week]) -> Week? {
        if let linked = event.linkedWeekID, !linked.isEmpty {
            return weeks.first { $0.recordName == linked }
        }
        if event.eventDate.isEmpty { return nil }   // event_date is None
        let covering = weeks.filter { $0.weekStart <= event.eventDate && $0.weekEnd >= event.eventDate }
        // Prefer the latest-starting covering week (M71), recordName breaks ties deterministically.
        return covering.max { ($0.weekStart, $0.recordName) < ($1.weekStart, $1.recordName) }
    }

    // MARK: apply_auto_merge_policy (event_grocery.py:426)

    public struct EventPolicyOutcome: Equatable {
        public var event: Event
        public var eventRows: [EventGroceryItem]
        public var weekRowsByID: [String: [GroceryItem]]
        public var createdRecordNames: [String]
        public var hardDeletedRecordNames: [String]
    }

    /// Orchestrates merge/unmerge against the event's target week. `weeksByID` is every household
    /// week (to resolve the target); `weekRowsByID` is each week's current grocery rows.
    public static func applyAutoMergePolicy(
        event: Event, eventRows: [EventGroceryItem],
        weeksByID: [String: Week], weekRowsByID: [String: [GroceryItem]], makeID: () -> String
    ) -> EventPolicyOutcome {
        var ev = event
        var rows = eventRows
        var weekRows = weekRowsByID
        var created: [String] = []
        var deleted: [String] = []
        let weeks = Array(weeksByID.values)

        func merge(into weekID: String) {
            let outcome = mergeEventIntoWeek(event: ev, eventRows: rows, weekRows: weekRows[weekID] ?? [],
                                             weekID: weekID, makeID: makeID)
            rows = outcome.eventRows
            weekRows[weekID] = outcome.weekRows
            ev.linkedWeekID = outcome.linkedWeekID
            created.append(contentsOf: outcome.createdRecordNames)
        }
        func unmerge(from weekID: String, keepLink: Bool) {
            let outcome = unmergeEventFromWeek(eventRows: rows, weekRows: weekRows[weekID] ?? [],
                                               weekID: weekID, eventName: ev.name, keepLink: keepLink,
                                               currentLinkedWeekID: ev.linkedWeekID)
            rows = outcome.eventRows
            weekRows[weekID] = outcome.weekRows
            ev.linkedWeekID = outcome.linkedWeekID
            deleted.append(contentsOf: outcome.hardDeletedRecordNames)
        }

        if ev.manuallyMerged {
            if let lw = ev.linkedWeekID, weeksByID[lw] != nil { merge(into: lw) }
            return outcome()
        }

        if ev.autoMergeGrocery {
            if let lw = ev.linkedWeekID, !ev.eventDate.isEmpty, let linked = weeksByID[lw],
               !(linked.weekStart <= ev.eventDate && ev.eventDate <= linked.weekEnd) {
                // Date moved off the linked week — drop the stale merge so it re-resolves.
                unmerge(from: lw, keepLink: false)
            }
            if let target = resolveTargetWeek(event: ev, weeks: weeks) { merge(into: target.recordName) }
            return outcome()
        }

        if let lw = ev.linkedWeekID, weeksByID[lw] != nil { unmerge(from: lw, keepLink: false) }
        return outcome()

        func outcome() -> EventPolicyOutcome {
            EventPolicyOutcome(event: ev, eventRows: rows, weekRowsByID: weekRows,
                               createdRecordNames: created.sorted(), hardDeletedRecordNames: deleted.sorted())
        }
    }
}
