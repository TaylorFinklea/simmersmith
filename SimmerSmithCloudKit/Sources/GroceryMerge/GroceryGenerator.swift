import Foundation

// SP-C slice 3 — on-device grocery regeneration, ported from the server's
// app/services/grocery.py (`build_grocery_rows_for_week` + `regenerate_grocery_for_week`).
//
// This is the load-bearing port: the grocery list rebuilds from a week's meals on-device,
// preserving ALL sticky user state across a regen. High fidelity to the Python is the bar.
//
// Scope note vs. the server: the server's `build_grocery_rows_for_week` does two DB-backed
// steps this pure/headless port does NOT do — (1) per-user catalog re-resolution via
// `choice_for_base_ingredient`, and (2) pantry-staple filtering via `staple_names`. Those
// read household/profile tables the device store doesn't expose to this layer. The caller
// (GroceryRepository) supplies already-resolved ingredient lines (base/variation/status come
// in on the input) and pre-filters staples. Everything that IS pure aggregation +
// sticky-preservation is ported faithfully below. See `Caveats` in the report.

// MARK: - Inputs

/// One ingredient line feeding aggregation, mirroring the fields `_aggregate` reads off a
/// RecipeIngredient / WeekMealIngredient (grocery.py:176-226). `quantity` is the RAW recipe
/// quantity; the generator applies the meal/side `factor`. `normalizedName` is the recipe's
/// own normalized form (or empty → derived from `ingredientName`), matching the
/// `ingredient.normalized_name or ingredient_name` precedence on line 182.
public struct GroceryIngredientLine: Equatable {
    public var ingredientName: String
    public var normalizedName: String
    public var unit: String
    public var quantity: Double?
    public var quantityText: String
    public var category: String
    public var notes: String
    public var prep: String
    public var baseIngredientID: String?
    public var ingredientVariationID: String?
    public var resolutionStatus: String
    public init(
        ingredientName: String, normalizedName: String = "", unit: String = "",
        quantity: Double? = nil, quantityText: String = "", category: String = "",
        notes: String = "", prep: String = "", baseIngredientID: String? = nil,
        ingredientVariationID: String? = nil, resolutionStatus: String = "unresolved"
    ) {
        self.ingredientName = ingredientName; self.normalizedName = normalizedName
        self.unit = unit; self.quantity = quantity; self.quantityText = quantityText
        self.category = category; self.notes = notes; self.prep = prep
        self.baseIngredientID = baseIngredientID
        self.ingredientVariationID = ingredientVariationID
        self.resolutionStatus = resolutionStatus
    }
}

/// A recipe-backed side on a meal (grocery.py:247-262). A side WITHOUT a recipe contributes
/// nothing to grocery; the caller passes only recipe-backed sides, each with its own ingredient
/// lines + servings, plus the side's display name (for the `[side: <name>]` source label).
public struct GroceryMealSide: Equatable {
    public var name: String
    public var baseServings: Double?
    public var ingredients: [GroceryIngredientLine]
    public init(name: String, baseServings: Double? = nil, ingredients: [GroceryIngredientLine]) {
        self.name = name; self.baseServings = baseServings; self.ingredients = ingredients
    }
}

/// A meal slotted on the week, with enough to compute its scale `factor` and source label.
/// Mirrors `WeekMeal` + the `source_label` parts (grocery.py:116-118: dayName / slot / recipeName).
/// `scaleMultiplier`/`servings`/`baseServings` reproduce the factor calc on grocery.py:231-237 &
/// 253-257. A meal whose recipe is missing falls back to its inline `ingredients` with factor 1.0.
public struct GroceryMeal: Equatable {
    public var dayName: String
    public var slot: String
    public var recipeName: String
    public var scaleMultiplier: Double?
    public var servings: Double?
    public var baseServings: Double?        // recipe.servings; nil when no recipe (inline meal)
    public var ingredients: [GroceryIngredientLine]
    public var sides: [GroceryMealSide]
    public init(
        dayName: String = "", slot: String = "", recipeName: String = "",
        scaleMultiplier: Double? = nil, servings: Double? = nil, baseServings: Double? = nil,
        ingredients: [GroceryIngredientLine], sides: [GroceryMealSide] = []
    ) {
        self.dayName = dayName; self.slot = slot; self.recipeName = recipeName
        self.scaleMultiplier = scaleMultiplier; self.servings = servings
        self.baseServings = baseServings; self.ingredients = ingredients; self.sides = sides
    }
}

// MARK: - Outputs

/// The write plan a regen produces. `upserts` are GroceryItems to SAVE (new + refreshed);
/// `tombstones` are eligible auto rows that no longer match any meal AND have no event /
/// user investment — they get hard-deleted on the server (`session.delete`), so the caller
/// engine.deletes them. Untouched rows (user-added, event-only, tombstones, unchanged) are
/// neither — they're left exactly as they were.
public struct GroceryRegenResult: Equatable {
    public var upserts: [GroceryItem]
    public var tombstones: [GroceryItem]   // to DELETE (auto rows with no remaining attribution)
    public init(upserts: [GroceryItem] = [], tombstones: [GroceryItem] = []) {
        self.upserts = upserts; self.tombstones = tombstones
    }
}

// MARK: - Generator

/// Port of the server's smart-merge grocery regeneration. Pure + headless.
public enum GroceryGenerator {

    /// An aggregated row, mirroring a `bucket` from `build_grocery_rows_for_week`
    /// (grocery.py:196-211) folded into the final `rows.append(...)` shape (264-310).
    struct AggregatedRow {
        var ingredientName: String
        var normalizedName: String
        var baseIngredientID: String?
        var ingredientVariationID: String?
        var resolutionStatus: String
        var totalQuantity: Double?
        var unit: String
        var quantityText: String
        var category: String
        var sourceMeals: Set<String>
        var notes: Set<String>
        var reviewFlag: String

        /// `_key_for_row` (grocery.py:315-324): base = baseIngredientID || normalizedName;
        /// variation only when status == "locked"; then unit + quantityText.
        var key: MergeKey {
            let base = baseIngredientID ?? (normalizedName.isEmpty ? "" : normalizedName)
            let lockedVariation = (resolutionStatus == "locked" ? ingredientVariationID : nil) ?? ""
            return MergeKey(base: base, variation: lockedVariation, unit: unit, quantityText: quantityText)
        }
    }

    /// `source_label` (grocery.py:116-118): join day / slot / recipeName with " / ", dropping empties.
    static func sourceLabel(_ meal: GroceryMeal) -> String {
        [meal.dayName, meal.slot, meal.recipeName].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    /// Aggregate a week's meals into fresh rows — port of `build_grocery_rows_for_week`'s
    /// `_aggregate` loop (grocery.py:176-263). The aggregation key is a 4-tuple
    /// `(base_key, locked_variation_id, unit, quantity_text)` (grocery.py:194-195); note
    /// `base_key` falls back to the row's NORMALIZED name (line 194) which is what feeds
    /// `key.base` below.
    static func buildRows(meals: [GroceryMeal]) -> [AggregatedRow] {
        // Insertion-ordered accumulation keyed by the 4-tuple aggregation key.
        var order: [MergeKey] = []
        var buckets: [MergeKey: AggregatedRow] = [:]

        func aggregate(_ ingredients: [GroceryIngredientLine], factor: Double, sourceLabel: String) {
            for ingredient in ingredients {
                let name = ingredient.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { continue }   // grocery.py:178-180

                // grocery.py:182 — normalize(normalized_name or ingredient_name)
                let normalized = GroceryNormalize.name(
                    ingredient.normalizedName.isEmpty ? name : ingredient.normalizedName
                )
                // NOTE: staple filtering (grocery.py:183) is done by the caller (DB-backed).

                let unit = GroceryNormalize.unit(ingredient.unit)            // grocery.py:186
                let quantity = ingredient.quantity.map { $0 * factor }       // grocery.py:187
                // quantity_text is only carried when there's no numeric quantity (grocery.py:188).
                let quantityText = quantity == nil ? ingredient.quantityText : ""
                // locked variation participates in the key only when status == "locked" (grocery.py:189-193).
                let lockedVariationID = ingredient.resolutionStatus == "locked"
                    ? (ingredient.ingredientVariationID ?? "") : ""
                let baseKey = ingredient.baseIngredientID ?? normalized      // grocery.py:194

                let key = MergeKey(base: baseKey, variation: lockedVariationID,
                                   unit: unit, quantityText: quantityText)

                if buckets[key] == nil {
                    order.append(key)
                    buckets[key] = AggregatedRow(
                        ingredientName: name,
                        normalizedName: normalized,
                        baseIngredientID: ingredient.baseIngredientID,
                        ingredientVariationID: ingredient.ingredientVariationID,
                        resolutionStatus: ingredient.resolutionStatus,
                        totalQuantity: quantity == nil ? nil : 0.0,   // grocery.py:204
                        unit: unit,
                        quantityText: "",
                        category: ingredient.category,
                        sourceMeals: [],
                        notes: [],
                        reviewFlag: ""
                    )
                }

                // grocery.py:214-218
                if let q = quantity {
                    buckets[key]!.totalQuantity = (buckets[key]!.totalQuantity ?? 0) + q
                } else if !quantityText.isEmpty {
                    buckets[key]!.quantityText = quantityText
                    buckets[key]!.reviewFlag = "quantity review"
                }

                // grocery.py:220-226
                if !ingredient.notes.isEmpty { buckets[key]!.notes.insert(ingredient.notes) }
                if !ingredient.prep.isEmpty { buckets[key]!.notes.insert(ingredient.prep) }
                if !ingredient.category.isEmpty && buckets[key]!.category.isEmpty {
                    buckets[key]!.category = ingredient.category
                }
                buckets[key]!.sourceMeals.insert(sourceLabel)
            }
        }

        for meal in meals {
            // Factor: scale_multiplier, else servings/baseServings, else 1.0 (grocery.py:228-237).
            let factor: Double
            let ingredients: [GroceryIngredientLine]
            if let base = meal.baseServings {           // recipe-backed meal
                let baseServings = base == 0 ? 1.0 : base
                let mealServings = meal.servings ?? baseServings
                factor = meal.scaleMultiplier ?? (baseServings == 0 ? 1.0 : mealServings / baseServings)
                ingredients = meal.ingredients
            } else {                                     // inline meal (no recipe) — grocery.py:235-237
                factor = 1.0
                ingredients = meal.ingredients
            }
            aggregate(ingredients, factor: factor, sourceLabel: sourceLabel(meal))

            // Recipe-backed sides scale by the parent meal's multiplier (grocery.py:247-262).
            for side in meal.sides {
                guard let sideBase = side.baseServings else { continue }
                let sideBaseServings = sideBase == 0 ? 1.0 : sideBase
                let sideMealServings = meal.servings ?? sideBaseServings
                let sideFactor = meal.scaleMultiplier
                    ?? (sideBaseServings == 0 ? 1.0 : sideMealServings / sideBaseServings)
                aggregate(side.ingredients, factor: sideFactor,
                          sourceLabel: "\(sourceLabel(meal)) [side: \(side.name)]")
            }
        }

        // Finalize: round totalQuantity to 2 dp (grocery.py:287-289); join sourceMeals/notes
        // sorted (grocery.py:306-307). Catalog re-resolution (grocery.py:265-301) is skipped —
        // the caller already supplied resolved identity; review_flag for a null base
        // (grocery.py:291-292) is therefore the caller's concern.
        return order.map { key in
            var row = buckets[key]!
            if let q = row.totalQuantity { row.totalQuantity = (q * 100).rounded() / 100 }
            // Flag quantity-less rows that also have no quantityText: the server equivalent is
            // the `elif quantity_text` branch (grocery.py:216-218), which never fires for these,
            // leaving them unflagged. Mirror the intended semantic: no numeric quantity AND no
            // text fallback → the user needs to review the amount.
            if row.totalQuantity == nil && row.quantityText.isEmpty && row.reviewFlag.isEmpty {
                row.reviewFlag = "quantity review"
            }
            return row
        }
    }

    /// Port of `regenerate_grocery_for_week` (grocery.py:500-579). Given the week's meals and
    /// the EXISTING GroceryItem set, produce the upserts (new + refreshed) and tombstones
    /// (auto rows to delete). Preserves user-added rows, removed-item tombstones, override
    /// fields, household-shared check state, eventQuantity, and storeLabel. Only the
    /// auto-derived totalQuantity / unit / sourceMeals / notes / category / review recompute.
    ///
    /// `clock` stamps the modifiedAt on freshly created/refreshed rows (CloudKit change-tag
    /// stand-in); the caller passes a monotonically advancing value. Pantry-recurring folding
    /// (grocery.py:573-575) is a separate server concern, not ported here.
    public static func regenerate(
        meals: [GroceryMeal],
        existing: [GroceryItem],
        weekID: String,
        clock: SyncClock = 0,
        newRecordName: (MergeKey) -> String = { _ in UUID().uuidString }
    ) -> GroceryRegenResult {
        // Untouchable rows: user-added OR event-only. The auto path never duplicates or
        // deletes these (grocery.py:519-522).
        var untouchableKeys = Set<MergeKey>()
        for item in existing where item.isUserAdded || item.isEventOnly {
            untouchableKeys.insert(item.mergeKey)
        }

        // Eligible rows keyed by merge key (grocery.py:524-528). Last-writer-wins on key
        // collision matches the dict assignment in Python.
        var eligibleByKey: [MergeKey: GroceryItem] = [:]
        for item in existing where !(item.isUserAdded || item.isEventOnly) {
            eligibleByKey[item.mergeKey] = item
        }

        let rows = buildRows(meals: meals)
        var matchedKeys = Set<MergeKey>()
        var upserts: [GroceryItem] = []

        for row in rows {
            let key = row.key
            if untouchableKeys.contains(key) { continue }   // grocery.py:535-538
            if let existingItem = eligibleByKey[key] {
                matchedKeys.insert(key)
                if existingItem.isUserRemoved { continue }  // tombstone stays (grocery.py:542-544)
                var refreshed = existingItem
                applyFreshToExisting(&refreshed, row: row)
                refreshed.modifiedAt = clock
                upserts.append(refreshed)
            } else {
                upserts.append(groceryItem(from: row, weekID: weekID,
                                           recordName: newRecordName(key), clock: clock))
            }
        }

        // Unmatched eligible rows (grocery.py:549-567).
        var tombstones: [GroceryItem] = []
        for (key, item) in eligibleByKey {
            if matchedKeys.contains(key) { continue }
            if item.isUserRemoved { continue }              // tombstone stays
            let hasEventQty = (item.eventQuantity ?? 0) > 0
            if hasEventQty {
                // Drop the stale week portion, keep the event portion (grocery.py:558-562).
                var stripped = item
                stripped.totalQuantity = nil
                stripped.reviewFlag = ""
                stripped.modifiedAt = clock
                upserts.append(stripped)
                continue
            }
            if hasUserInvestment(item) {
                // Keep, flag "no longer in any meal" if not already flagged (grocery.py:563-565).
                if item.reviewFlag.isEmpty {
                    var flagged = item
                    flagged.reviewFlag = "no longer in any meal"
                    flagged.modifiedAt = clock
                    upserts.append(flagged)
                }
                continue
            }
            // Pure auto row whose meal is gone → delete (grocery.py:567).
            tombstones.append(item)
        }

        // Deterministic ordering for stable diffs / tests.
        return GroceryRegenResult(
            upserts: upserts.sorted { $0.recordName < $1.recordName },
            tombstones: tombstones.sorted { $0.recordName < $1.recordName }
        )
    }

    /// `_has_user_investment` (grocery.py:363-372): override set OR checked.
    static func hasUserInvestment(_ item: GroceryItem) -> Bool {
        item.quantityOverride != nil
            || item.unitOverride != nil
            || item.notesOverride != nil
            || item.check.isChecked
    }

    /// `_apply_fresh_to_existing` (grocery.py:375-399): refresh auto-managed fields only.
    /// A field guarded by a user override keeps the user's value on display, but the auto
    /// value still lands in the base field (so iOS can show "you overrode X → Y").
    static func applyFreshToExisting(_ item: inout GroceryItem, row: AggregatedRow) {
        if item.quantityOverride == nil { item.totalQuantity = row.totalQuantity }
        if item.unitOverride == nil { item.unit = row.unit }
        if item.notesOverride == nil { item.notes = joined(row.notes) }
        item.quantityText = row.quantityText
        if !row.category.isEmpty { item.category = row.category }   // grocery.py:390: row || existing
        item.sourceMeals = joined(row.sourceMeals)
        item.reviewFlag = row.reviewFlag
        item.baseIngredientID = row.baseIngredientID
        item.ingredientVariationID = row.ingredientVariationID
        if !row.ingredientName.isEmpty { item.ingredientName = row.ingredientName }
        if !row.normalizedName.isEmpty { item.normalizedName = row.normalizedName }
        if !row.resolutionStatus.isEmpty { item.resolutionStatus = row.resolutionStatus }
    }

    /// Build a fresh GroceryItem from an aggregated row — `_grocery_item_from_row`
    /// (grocery.py:402-417). New rows have NO sticky state (overrides/check/tombstone all default).
    static func groceryItem(
        from row: AggregatedRow, weekID: String, recordName: String, clock: SyncClock
    ) -> GroceryItem {
        GroceryItem(
            recordName: recordName,
            weekID: weekID,
            baseIngredientID: row.baseIngredientID,
            ingredientVariationID: row.ingredientVariationID,
            resolutionStatus: row.resolutionStatus,
            unit: row.unit,
            quantityText: row.quantityText,
            normalizedName: row.normalizedName,
            ingredientName: row.ingredientName,
            category: row.category,
            totalQuantity: row.totalQuantity,
            notes: joined(row.notes),
            sourceMeals: joined(row.sourceMeals),
            reviewFlag: row.reviewFlag,
            createdAt: clock,
            modifiedAt: clock
        )
    }

    /// "; "-join a set sorted, matching `"; ".join(sorted(...))` (grocery.py:306-307).
    static func joined(_ values: Set<String>) -> String {
        values.sorted().joined(separator: "; ")
    }
}
