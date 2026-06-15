import Foundation

/// Logical clock standing in for CKRecord's server change tag (higher = later).
public typealias SyncClock = Int

/// Common surface every synced record exposes for conflict resolution.
public protocol Mergeable {
    var recordName: String { get }
    var modifiedAt: SyncClock { get }
}

/// The grocery aggregation match key. Verbatim port of `_key_for_item` /
/// `_key_for_row` (app/services/grocery.py:315/327), INCLUDING the guard that the
/// variation id only participates when `resolutionStatus == "locked"`.
public struct MergeKey: Hashable {
    public let base: String
    public let variation: String
    public let unit: String
    public let quantityText: String
}

/// Per-actor check state, resolved as ONE unit (fixes review finding C4 — the
/// (is_checked, checked_at, checked_by) triple must never tear under per-field LWW).
public struct CheckState: Equatable {
    public var isChecked: Bool
    public var at: SyncClock            // clock of the last check-state mutation
    public var by: String?
    public init(isChecked: Bool = false, at: SyncClock = 0, by: String? = nil) {
        self.isChecked = isChecked; self.at = at; self.by = by
    }
}

/// The merge-relevant subset of the production GroceryItem (app/models/week.py:184).
public struct GroceryItem: Mergeable, Equatable {
    public let recordName: String
    // merge-key inputs
    public var baseIngredientID: String?
    public var ingredientVariationID: String?
    public var resolutionStatus: String
    public var unit: String
    public var quantityText: String
    public var normalizedName: String
    // auto-managed payload
    public var totalQuantity: Double?
    public var notes: String
    public var sourceMeals: String
    public var reviewFlag: String
    // sticky semantics
    public var isUserAdded: Bool
    public var isUserRemoved: Bool          // tombstone — monotonic
    public var quantityOverride: Double?
    public var unitOverride: String?
    public var notesOverride: String?
    public var check: CheckState
    public var eventQuantity: Double?       // owned by the event merge/unmerge pair
    // bookkeeping
    public var createdAt: SyncClock
    public var modifiedAt: SyncClock

    public init(
        recordName: String, baseIngredientID: String? = nil, ingredientVariationID: String? = nil,
        resolutionStatus: String = "unresolved", unit: String = "", quantityText: String = "",
        normalizedName: String = "", totalQuantity: Double? = nil, notes: String = "",
        sourceMeals: String = "", reviewFlag: String = "", isUserAdded: Bool = false,
        isUserRemoved: Bool = false, quantityOverride: Double? = nil, unitOverride: String? = nil,
        notesOverride: String? = nil, check: CheckState = CheckState(), eventQuantity: Double? = nil,
        createdAt: SyncClock = 0, modifiedAt: SyncClock = 0
    ) {
        self.recordName = recordName; self.baseIngredientID = baseIngredientID
        self.ingredientVariationID = ingredientVariationID; self.resolutionStatus = resolutionStatus
        self.unit = unit; self.quantityText = quantityText; self.normalizedName = normalizedName
        self.totalQuantity = totalQuantity; self.notes = notes; self.sourceMeals = sourceMeals
        self.reviewFlag = reviewFlag; self.isUserAdded = isUserAdded; self.isUserRemoved = isUserRemoved
        self.quantityOverride = quantityOverride; self.unitOverride = unitOverride
        self.notesOverride = notesOverride; self.check = check; self.eventQuantity = eventQuantity
        self.createdAt = createdAt; self.modifiedAt = modifiedAt
    }

    public var mergeKey: MergeKey {
        let base = baseIngredientID ?? (normalizedName.isEmpty ? "" : normalizedName)
        let lockedVariation = (resolutionStatus == "locked" ? ingredientVariationID : nil) ?? ""
        return MergeKey(base: base, variation: lockedVariation, unit: unit, quantityText: quantityText)
    }

    /// True for rows created purely by event merge — `_is_event_only` (grocery.py:354).
    public var isEventOnly: Bool {
        guard let eq = eventQuantity, eq > 0 else { return false }
        return sourceMeals.hasPrefix("event:")
    }
}

/// Event-side grocery contribution that points back into a week's GroceryItem.
/// Mirrors the `merged_into_*` + additive `event_quantity` semantics in
/// app/services/event_grocery.py.
public struct EventGroceryItem: Mergeable, Equatable {
    public let recordName: String
    public var mergedIntoGroceryItemID: String?   // → a week GroceryItem.recordName
    public var mergedIntoWeekID: String?
    public var eventQuantity: Double?
    public var modifiedAt: SyncClock
    public init(recordName: String, mergedIntoGroceryItemID: String? = nil,
                mergedIntoWeekID: String? = nil, eventQuantity: Double? = nil, modifiedAt: SyncClock = 0) {
        self.recordName = recordName; self.mergedIntoGroceryItemID = mergedIntoGroceryItemID
        self.mergedIntoWeekID = mergedIntoWeekID; self.eventQuantity = eventQuantity
        self.modifiedAt = modifiedAt
    }
}

/// A meal slotted on a week. Slot uniqueness is `(weekID, dayName, slot)` — the
/// old DEFERRABLE constraint with no CloudKit equivalent.
public struct WeekMeal: Mergeable, Equatable {
    public let recordName: String
    public var weekID: String
    public var dayName: String
    public var slot: String
    public var sortOrder: Int
    public var modifiedAt: SyncClock
    public init(recordName: String, weekID: String, dayName: String, slot: String,
                sortOrder: Int = 0, modifiedAt: SyncClock = 0) {
        self.recordName = recordName; self.weekID = weekID; self.dayName = dayName
        self.slot = slot; self.sortOrder = sortOrder; self.modifiedAt = modifiedAt
    }
}

/// A planning week. `weekStart` is the household-unique key (was
/// `UNIQUE(household_id, week_start)`).
public struct Week: Mergeable, Equatable {
    public let recordName: String
    public var weekStart: String
    public var modifiedAt: SyncClock
    public init(recordName: String, weekStart: String, modifiedAt: SyncClock = 0) {
        self.recordName = recordName; self.weekStart = weekStart; self.modifiedAt = modifiedAt
    }
}

/// An event plan. `manuallyMerged` is a sticky pin.
public struct Event: Mergeable, Equatable {
    public let recordName: String
    public var name: String
    public var eventDate: String
    public var linkedWeekID: String?
    public var manuallyMerged: Bool
    public var autoMergeGrocery: Bool
    public var modifiedAt: SyncClock
    public init(recordName: String, name: String = "", eventDate: String = "",
                linkedWeekID: String? = nil, manuallyMerged: Bool = false,
                autoMergeGrocery: Bool = true, modifiedAt: SyncClock = 0) {
        self.recordName = recordName; self.name = name; self.eventDate = eventDate
        self.linkedWeekID = linkedWeekID; self.manuallyMerged = manuallyMerged
        self.autoMergeGrocery = autoMergeGrocery; self.modifiedAt = modifiedAt
    }
}
