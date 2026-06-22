import Foundation

// SP-C slice 4 — on-device EVENT-grocery generation, ported from the server's
// app/services/event_grocery.py (`_aggregate_event_rows` + `regenerate_event_grocery`).
//
// The event analog of GroceryGenerator (the week-grocery port). Same 4-tuple aggregation key,
// same factor math, same per-ingredient fold, same GroceryNormalize calls — but driven by an
// event's meals (recipe-backed OR inline EventMealIngredient) instead of week meals, and emitting
// EventGroceryItem rows (the event-side contribution that the merge later folds into a week).
//
// Three event-specific divergences from the week port (event_grocery.py:75-142):
//   1. A meal assigned to a guest contributes NO grocery — the guest is bringing the dish
//      (event_grocery.py:78-81). The caller filters these out (assignedGuestID set) before building
//      the input, mirroring the server's `continue`.
//   2. No sides. Event meals have no recipe-backed-side plane (unlike WeekMeal); the input carries
//      only the meal's own ingredient lines.
//   3. `sourceMeals` is a JSON array of the contributing meal IDs (sorted), not the
//      day/slot/recipe label the week list uses (event_grocery.py:142,185). The downstream merge
//      engine does NOT read this field for matching — it writes `event:<name>` onto the week row it
//      creates — so this is purely the iOS event view's per-row attribution label.
//
// Scope note vs. the server (same boundary as GroceryGenerator): event_grocery.py runs two
// DB-backed steps this pure/headless port does NOT — (1) per-user catalog re-resolution via
// `choice_for_base_ingredient` (event_grocery.py:146-166), and (2) household pantry-staple
// filtering via `staple_names` (event_grocery.py:72,99). Those read household/profile tables the
// device store doesn't expose to this layer. The caller (EventRepository) supplies already-resolved
// ingredient lines and pre-filters staples; everything that IS pure aggregation is ported below.
// Consequently the server's `base is None → review_flag = "ingredient review"` branch
// (event_grocery.py:171-172) — which only fires after a failed catalog re-resolution — is the
// caller's concern, exactly as the `null base` review flag is for the week port.
//
// Pantry supplements (event_grocery.py:190-219, M28) are DEFERRED with the Pantry plane and are
// NOT ported here.

// MARK: - Input

/// One event meal feeding event-grocery aggregation. Mirrors `EventMeal` + the fields
/// `_aggregate_event_rows` reads (event_grocery.py:75-92). A recipe-backed meal carries its
/// recipe's ingredient lines + `baseServings` (recipe.servings, drives the scale factor); an
/// inline meal (no recipe) carries its own EventMealIngredient lines at factor `scaleMultiplier ?? 1`.
/// `assignedGuestID` lets the caller mirror the server's guest-brings-the-dish skip — the caller
/// drops these before building, but the field is carried for symmetry/clarity.
public struct EventGroceryMeal: Equatable {
    public var mealID: String
    public var assignedGuestID: String?
    public var scaleMultiplier: Double?
    public var servings: Double?
    public var baseServings: Double?        // recipe.servings; nil when no recipe (inline meal)
    public var ingredients: [GroceryIngredientLine]
    public init(
        mealID: String, assignedGuestID: String? = nil,
        scaleMultiplier: Double? = nil, servings: Double? = nil, baseServings: Double? = nil,
        ingredients: [GroceryIngredientLine]
    ) {
        self.mealID = mealID; self.assignedGuestID = assignedGuestID
        self.scaleMultiplier = scaleMultiplier; self.servings = servings
        self.baseServings = baseServings; self.ingredients = ingredients
    }
}

// MARK: - Generator

/// Port of the server's event-grocery generation. Pure + headless. Reuses GroceryNormalize and
/// the same MergeKey 4-tuple as GroceryGenerator; the aggregation fold mirrors that of
/// `build_grocery_rows_for_week` line-for-line against `_aggregate_event_rows`.
public enum EventGroceryGenerator {

    /// An aggregated event-grocery row (a `bucket` in event_grocery.py:114-127), holding the meal
    /// IDs that contributed so the final row can emit the JSON `source_meals` array.
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
        var sourceMeals: Set<String>     // contributing meal IDs (event_grocery.py:142)
        var notes: Set<String>
        var reviewFlag: String
    }

    /// Aggregate an event's meals into fresh rows — port of `_aggregate_event_rows`'s loop
    /// (event_grocery.py:75-142). The aggregation key is the same 4-tuple
    /// `(base_key, locked_variation_id, unit, quantity_text)` GroceryGenerator uses; `base_key`
    /// falls back to the row's NORMALIZED name (event_grocery.py:110).
    static func buildRows(meals: [EventGroceryMeal]) -> [AggregatedRow] {
        var order: [MergeKey] = []
        var buckets: [MergeKey: AggregatedRow] = [:]

        for meal in meals {
            // Guest-assigned dishes are brought by the guest → no grocery (event_grocery.py:78-81).
            if let g = meal.assignedGuestID, !g.isEmpty { continue }

            // Factor: scale_multiplier, else servings/baseServings, else 1.0 (event_grocery.py:82-92).
            let factor: Double
            if let base = meal.baseServings {            // recipe-backed meal
                let baseServings = base == 0 ? 1.0 : base
                let mealServings = meal.servings ?? baseServings
                factor = meal.scaleMultiplier ?? (baseServings == 0 ? 1.0 : mealServings / baseServings)
            } else {                                     // inline meal (no recipe) — event_grocery.py:90-92
                factor = meal.scaleMultiplier ?? 1.0
            }

            for ingredient in meal.ingredients {
                let name = ingredient.ingredientName.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { continue }   // event_grocery.py:95-97

                // event_grocery.py:98 — normalize(normalized_name or ingredient_name)
                let normalized = GroceryNormalize.name(
                    ingredient.normalizedName.isEmpty ? name : ingredient.normalizedName
                )
                // NOTE: staple filtering (event_grocery.py:99) is the caller's concern (DB-backed).

                let unit = GroceryNormalize.unit(ingredient.unit)          // event_grocery.py:102
                let quantity = ingredient.quantity.map { $0 * factor }     // event_grocery.py:103
                // quantity_text is only carried when there's no numeric quantity (event_grocery.py:104).
                let quantityText = quantity == nil ? ingredient.quantityText : ""
                // locked variation participates in the key only when status == "locked"
                // (event_grocery.py:105-109).
                let lockedVariationID = ingredient.resolutionStatus == "locked"
                    ? (ingredient.ingredientVariationID ?? "") : ""
                let baseKey = ingredient.baseIngredientID ?? normalized    // event_grocery.py:110

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
                        totalQuantity: quantity == nil ? nil : 0.0,   // event_grocery.py:120
                        unit: unit,
                        quantityText: "",
                        category: ingredient.category,
                        sourceMeals: [],
                        notes: [],
                        reviewFlag: ""
                    )
                }

                // event_grocery.py:130-134
                if let q = quantity {
                    buckets[key]!.totalQuantity = (buckets[key]!.totalQuantity ?? 0) + q
                } else if !quantityText.isEmpty {
                    buckets[key]!.quantityText = quantityText
                    buckets[key]!.reviewFlag = "quantity review"
                }

                // event_grocery.py:136-142
                if !ingredient.notes.isEmpty { buckets[key]!.notes.insert(ingredient.notes) }
                if !ingredient.prep.isEmpty { buckets[key]!.notes.insert(ingredient.prep) }
                if !ingredient.category.isEmpty && buckets[key]!.category.isEmpty {
                    buckets[key]!.category = ingredient.category
                }
                buckets[key]!.sourceMeals.insert(meal.mealID)
            }
        }

        // Finalize: round totalQuantity to 2 dp (event_grocery.py:167-169). Catalog re-resolution
        // (event_grocery.py:146-166) is skipped — the caller supplied resolved identity; the
        // `base is None → "ingredient review"` flag (171-172) is therefore the caller's concern.
        return order.map { key in
            var row = buckets[key]!
            if let q = row.totalQuantity { row.totalQuantity = (q * 100).rounded() / 100 }
            return row
        }
    }

    /// Port of `regenerate_event_grocery` (event_grocery.py:225-282): wipe + rebuild the event's
    /// grocery list from its current meals. Unlike the week regen, event regen carries NO sticky
    /// state — the server hard-deletes every prior EventGroceryItem and recreates the set, so this
    /// returns a freshly built list. (The unmerge-before-wipe / re-merge dance the server does
    /// around this — event_grocery.py:236-247 — is the EventRepository's wiring concern, not the
    /// generator's: the generator only produces the fresh rows.)
    ///
    /// Rows are sorted by `(category.lower(), ingredient_name.lower())` to match the server's final
    /// `rows.sort(...)` (event_grocery.py:221), giving a stable, display-ready order.
    /// `newRecordName` mints the CloudKit record name for each fresh row (keyed by its MergeKey so
    /// tests can pin deterministic names).
    public static func regenerate(
        eventID: String,
        meals: [EventGroceryMeal],
        clock: SyncClock = 0,
        newRecordName: (MergeKey) -> String = { _ in UUID().uuidString }
    ) -> [EventGroceryItem] {
        let rows = buildRows(meals: meals)
        let items = rows.map { row -> EventGroceryItem in
            let key = MergeKey(
                base: row.baseIngredientID ?? (row.normalizedName.isEmpty ? "" : row.normalizedName),
                variation: (row.resolutionStatus == "locked" ? row.ingredientVariationID : nil) ?? "",
                unit: row.unit,
                quantityText: row.quantityText
            )
            return eventGroceryItem(from: row, recordName: newRecordName(key), clock: clock)
        }
        // event_grocery.py:221 — sort by (category, name), case-insensitive.
        return items.sorted { lhs, rhs in
            let lc = lhs.category.lowercased(), rc = rhs.category.lowercased()
            if lc != rc { return lc < rc }
            return lhs.ingredientName.lowercased() < rhs.ingredientName.lowercased()
        }
    }

    /// Build a fresh EventGroceryItem from an aggregated row — the `EventGroceryItem(...)`
    /// construction in `regenerate_event_grocery` (event_grocery.py:258-273). New event rows carry
    /// no merge pointers (merged_into_* default nil) — the merge sets those later.
    /// `eventQuantity` here is THIS row's contribution (= prod `total_quantity`).
    static func eventGroceryItem(
        from row: AggregatedRow, recordName: String, clock: SyncClock
    ) -> EventGroceryItem {
        EventGroceryItem(
            recordName: recordName,
            eventQuantity: row.totalQuantity,
            baseIngredientID: row.baseIngredientID,
            ingredientVariationID: row.ingredientVariationID,
            ingredientName: row.ingredientName,
            normalizedName: row.normalizedName,
            unit: row.unit,
            quantityText: row.quantityText,
            category: row.category,
            sourceMeals: jsonMealIDs(row.sourceMeals),
            notes: joined(row.notes),
            reviewFlag: row.reviewFlag,
            resolutionStatus: row.resolutionStatus,
            modifiedAt: clock
        )
    }

    /// `json.dumps(sorted(source_meals))` (event_grocery.py:185). A JSON array of the contributing
    /// meal IDs, sorted — the iOS event view's per-row attribution. Matches Python's default
    /// separators (`", "` / `": "`) for a list of strings: `["a", "b"]`.
    static func jsonMealIDs(_ ids: Set<String>) -> String {
        let sorted = ids.sorted()
        let elements = sorted.map { "\"\(jsonEscape($0))\"" }.joined(separator: ", ")
        return "[\(elements)]"
    }

    /// Minimal JSON string escaping for a meal ID (backslash + double-quote), matching json.dumps.
    private static func jsonEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// "; "-join a set sorted, matching `"; ".join(sorted(...))` (event_grocery.py:186).
    static func joined(_ values: Set<String>) -> String {
        values.sorted().joined(separator: "; ")
    }
}
