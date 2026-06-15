import Foundation

/// Logical clock value standing in for CKRecord's server-assigned change tag.
/// Higher = later write. A single shared `ClockSource` across both replicas
/// gives a deterministic total order for last-writer-wins resolution.
public typealias Clock = Int

/// The merge key. Mirrors `_key_for_item` / `_key_for_row`
/// (app/services/grocery.py:315/327):
/// `(base_ingredient_id or normalized_name, locked_variation_id, unit, quantity_text)`.
public struct MergeKey: Hashable {
    public let base: String
    public let variation: String
    public let unit: String
    public let quantityText: String
}

/// The merge-relevant subset of the production `GroceryItem`
/// (app/models/week.py:184). Only fields read or written by
/// `regenerate_grocery_for_week` and the four user mutations matter here;
/// pricing, catalog resolution, store labels, etc. are intentionally omitted.
public struct GroceryItem: Equatable, Identifiable {
    public let id: String
    // --- identity / merge key inputs ---
    public var baseIngredientID: String?
    public var ingredientVariationID: String?
    public var resolutionStatus: String   // "locked" gates the variation into the key
    public var unit: String
    public var quantityText: String
    public var normalizedName: String
    // --- auto-managed payload (refreshed by regen) ---
    public var totalQuantity: Double?
    public var reviewFlag: String
    public var sourceMeals: String
    // --- "sticky" user/event semantics that LWW would corrupt ---
    public var isUserAdded: Bool
    public var isUserRemoved: Bool         // tombstone — kept as a row, hidden in UI
    public var quantityOverride: Double?
    public var unitOverride: String?
    public var notesOverride: String?
    public var isChecked: Bool
    public var eventQuantity: Double?      // owned solely by the event merge/unmerge pair
    // --- sync bookkeeping ---
    public var modifiedAt: Clock

    public init(
        id: String,
        baseIngredientID: String? = nil,
        ingredientVariationID: String? = nil,
        resolutionStatus: String = "unresolved",
        unit: String = "",
        quantityText: String = "",
        normalizedName: String = "",
        totalQuantity: Double? = nil,
        reviewFlag: String = "",
        sourceMeals: String = "",
        isUserAdded: Bool = false,
        isUserRemoved: Bool = false,
        quantityOverride: Double? = nil,
        unitOverride: String? = nil,
        notesOverride: String? = nil,
        isChecked: Bool = false,
        eventQuantity: Double? = nil,
        modifiedAt: Clock = 0
    ) {
        self.id = id
        self.baseIngredientID = baseIngredientID
        self.ingredientVariationID = ingredientVariationID
        self.resolutionStatus = resolutionStatus
        self.unit = unit
        self.quantityText = quantityText
        self.normalizedName = normalizedName
        self.totalQuantity = totalQuantity
        self.reviewFlag = reviewFlag
        self.sourceMeals = sourceMeals
        self.isUserAdded = isUserAdded
        self.isUserRemoved = isUserRemoved
        self.quantityOverride = quantityOverride
        self.unitOverride = unitOverride
        self.notesOverride = notesOverride
        self.isChecked = isChecked
        self.eventQuantity = eventQuantity
        self.modifiedAt = modifiedAt
    }

    public var mergeKey: MergeKey {
        let base = baseIngredientID ?? (normalizedName.isEmpty ? "" : normalizedName)
        let lockedVariation = (resolutionStatus == "locked" ? ingredientVariationID : nil) ?? ""
        return MergeKey(base: base, variation: lockedVariation, unit: unit, quantityText: quantityText)
    }

    /// Mirrors `_is_event_only` (grocery.py:354).
    public var isEventOnly: Bool {
        guard let eq = eventQuantity, eq > 0 else { return false }
        return sourceMeals.hasPrefix("event:")
    }

    /// Mirrors `_has_user_investment` (grocery.py:363).
    public var hasUserInvestment: Bool {
        quantityOverride != nil || unitOverride != nil || notesOverride != nil || isChecked
    }
}

/// A freshly-aggregated grocery row — the output of `build_grocery_rows_for_week`,
/// supplied as test input here (the aggregation itself is not under test).
public struct FreshRow {
    public var baseIngredientID: String?
    public var ingredientVariationID: String?
    public var resolutionStatus: String
    public var unit: String
    public var quantityText: String
    public var normalizedName: String
    public var totalQuantity: Double?
    public var reviewFlag: String
    public var sourceMeals: String

    public init(
        baseIngredientID: String? = nil,
        ingredientVariationID: String? = nil,
        resolutionStatus: String = "unresolved",
        unit: String = "",
        quantityText: String = "",
        normalizedName: String = "",
        totalQuantity: Double? = nil,
        reviewFlag: String = "",
        sourceMeals: String = ""
    ) {
        self.baseIngredientID = baseIngredientID
        self.ingredientVariationID = ingredientVariationID
        self.resolutionStatus = resolutionStatus
        self.unit = unit
        self.quantityText = quantityText
        self.normalizedName = normalizedName
        self.totalQuantity = totalQuantity
        self.reviewFlag = reviewFlag
        self.sourceMeals = sourceMeals
    }

    public var mergeKey: MergeKey {
        let base = baseIngredientID ?? (normalizedName.isEmpty ? "" : normalizedName)
        let lockedVariation = (resolutionStatus == "locked" ? ingredientVariationID : nil) ?? ""
        return MergeKey(base: base, variation: lockedVariation, unit: unit, quantityText: quantityText)
    }
}

/// Monotonic logical-clock source shared by both replicas.
public final class ClockSource {
    private var value: Clock = 0
    public init() {}
    public func next() -> Clock {
        value += 1
        return value
    }
}
