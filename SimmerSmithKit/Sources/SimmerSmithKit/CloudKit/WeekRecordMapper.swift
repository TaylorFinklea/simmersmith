import Foundation
import HouseholdRecords

// SP-C Task 2 — WeekSnapshot ⇄ CloudKit records mapper (both directions).
//
// Mirrors RecipeRecordMapper in structure and conventions. Maps a WeekSnapshot
// to its primary .week record plus its .weekMeal children and each meal's
// .weekMealSide grandchildren.
//
// Field classification:
//   A. Direct scalar ↔ .week / .weekMeal / .weekMealSide record scalar field (1:1)
//   B. References — .weekMeal: week cascadeParent, recipe setNullInZone
//                   .weekMealSide: weekMeal cascadeParent, recipe setNullInZone
//   C. Child/grandchild records — meals as .weekMeal children of week;
//      sides as .weekMealSide children of each meal
//   D. Derived / NOT stored — nil/recompute on reverse map:
//      WeekSnapshot: stagedChangeCount, feedbackCount, exportCount, nutritionTotals, weeklyTotals
//      WeekMeal: ingredients (denormalized copy — resolved from RecipeRepository), macros
//      GroceryItem: NOT mapped here (owned by GroceryCodec / GroceryRepository)
//
// WeekMeal.ingredients (the denormalized per-meal ingredient list from the server) are NOT
// stored as records — they are derived at read time from the recipe's own RecipeIngredient
// records. Storing them separately would duplicate data and risk divergence.
//
// GroceryItems are NOT mapped here; GroceryCodec + GroceryRepository own them.

public enum WeekRecordMapper {

    // MARK: - Shared formatters

    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Domain → Records

    /// Map a `WeekSnapshot` to its primary record plus meal and side child records.
    /// GroceryItems are excluded — they are owned by GroceryCodec.
    public static func records(from week: WeekSnapshot)
        -> (week: HouseholdRecordValue, meals: [HouseholdRecordValue], sides: [HouseholdRecordValue])
    {
        let weekRecord = buildWeekRecord(week)
        var mealRecords: [HouseholdRecordValue] = []
        var sideRecords: [HouseholdRecordValue] = []

        for meal in week.meals {
            mealRecords.append(buildMealRecord(meal, weekId: week.weekId))
            for side in meal.sides {
                sideRecords.append(buildSideRecord(side, weekMealId: meal.mealId))
            }
        }

        return (weekRecord, mealRecords, sideRecords)
    }

    // MARK: - Records → Domain

    /// Reconstruct a `WeekSnapshot` from its CloudKit record set.
    /// Category-D (derived) fields are returned as nil/0/[]. GroceryItems must be
    /// supplied separately (they come from GroceryCodec / GroceryRepository).
    public static func week(
        from rec: HouseholdRecordValue,
        meals: [HouseholdRecordValue],
        sidesByMeal: [String: [HouseholdRecordValue]],
        groceryItems: [GroceryItem] = []
    ) -> WeekSnapshot {
        let s = rec.scalars

        var dict: [String: Any] = [
            "weekId": rec.recordName,
            "status": string(s, "status") ?? "staging",
            "notes": string(s, "notes") ?? "",
            // Derived fields (§5-D) — NOT echoed; recompute from store or return zero/empty.
            "stagedChangeCount": 0,
            "feedbackCount": 0,
            "exportCount": 0,
            "meals": [],
            "groceryItems": [],
            "nutritionTotals": [],
        ]

        // Required dates — use stored value or stable fallback (1970-01-01).
        dict["weekStart"] = iso8601(date(s, "weekStart") ?? Date(timeIntervalSince1970: 0))
        dict["weekEnd"]   = iso8601(date(s, "weekEnd")   ?? Date(timeIntervalSince1970: 0))
        dict["updatedAt"] = iso8601(date(s, "updatedAt") ?? Date())

        // Optional dates.
        if let v = date(s, "readyForAIAt") { dict["readyForAiAt"] = iso8601(v) }
        if let v = date(s, "approvedAt")   { dict["approvedAt"]  = iso8601(v) }
        if let v = date(s, "pricedAt")     { dict["pricedAt"]    = iso8601(v) }

        // Build meals (each with their sides).
        let mealDicts: [[String: Any]] = meals.map { mealRec in
            let sides = sidesByMeal[mealRec.recordName] ?? []
            return mealDict(mealRec, sides: sides)
        }
        dict["meals"] = mealDicts

        // Grocery items (supplied by caller from GroceryCodec / GroceryRepository).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let groceryDicts: [[String: Any]] = groceryItems.compactMap {
            (try? encoder.encode($0)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        dict["groceryItems"] = groceryDicts

        let jsonData = try! JSONSerialization.data(withJSONObject: dict)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try! decoder.decode(WeekSnapshot.self, from: jsonData)
    }

    // MARK: - Private helpers: domain → record

    private static func buildWeekRecord(_ week: WeekSnapshot) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        scalars["weekStart"] = .date(week.weekStart)
        scalars["weekEnd"]   = .date(week.weekEnd)
        setIfNonEmpty(&scalars, "status", week.status)
        setIfNonEmpty(&scalars, "notes", week.notes)
        if let v = week.readyForAiAt { scalars["readyForAIAt"] = .date(v) }
        if let v = week.approvedAt   { scalars["approvedAt"]   = .date(v) }
        if let v = week.pricedAt     { scalars["pricedAt"]     = .date(v) }
        scalars["updatedAt"] = .date(Date())

        return HouseholdRecordValue(type: .week, recordName: week.weekId, scalars: scalars, refs: [:])
    }

    private static func buildMealRecord(_ meal: WeekMeal, weekId: String) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        set(&scalars, "dayName", .string(meal.dayName))
        scalars["mealDate"] = .date(meal.mealDate)
        set(&scalars, "slot", .string(meal.slot))
        set(&scalars, "recipeName", .string(meal.recipeName))
        if let v = meal.servings { scalars["servings"] = .double(v) }
        scalars["scaleMultiplier"] = .double(meal.scaleMultiplier)
        setIfNonEmpty(&scalars, "source", meal.source)
        scalars["approved"]    = .bool(meal.approved)
        setIfNonEmpty(&scalars, "notes", meal.notes)
        scalars["aiGenerated"] = .bool(meal.aiGenerated)
        // sortOrder: WeekMeal domain struct does not expose sortOrder; default to 0.
        // The manifest stores it for CloudKit ordering; reloading from the store
        // provides ordering through the existing mealDate/slot fields.
        scalars["sortOrder"]   = .int(0)
        scalars["updatedAt"]   = .date(Date())

        var refs: [String: String] = [:]
        refs["week"] = weekId   // cascadeParent
        if let rid = meal.recipeId { refs["recipe"] = rid }   // setNullInZone

        return HouseholdRecordValue(type: .weekMeal, recordName: meal.mealId, scalars: scalars, refs: refs)
    }

    private static func buildSideRecord(_ side: WeekMealSide, weekMealId: String) -> HouseholdRecordValue {
        var scalars: [String: ScalarValue] = [:]

        if let v = side.recipeName, !v.isEmpty { scalars["recipeName"] = .string(v) }
        set(&scalars, "name", .string(side.name))
        setIfNonEmpty(&scalars, "notes", side.notes)
        scalars["sortOrder"] = .int(side.sortOrder)
        scalars["updatedAt"] = .date(side.updatedAt)

        var refs: [String: String] = [:]
        refs["weekMeal"] = weekMealId   // cascadeParent
        if let rid = side.recipeId { refs["recipe"] = rid }   // setNullInZone

        return HouseholdRecordValue(type: .weekMealSide, recordName: side.sideId, scalars: scalars, refs: refs)
    }

    // MARK: - Private helpers: record → domain

    /// Build a meal dictionary (for JSON round-trip to WeekMeal) including its sides.
    private static func mealDict(_ rec: HouseholdRecordValue, sides: [HouseholdRecordValue]) -> [String: Any] {
        let s = rec.scalars
        var d: [String: Any] = [
            "mealId": rec.recordName,
            "dayName": string(s, "dayName") ?? "",
            "slot": string(s, "slot") ?? "",
            "recipeName": string(s, "recipeName") ?? "",
            "scaleMultiplier": double(s, "scaleMultiplier") ?? 1.0,
            "source": string(s, "source") ?? "user",
            "approved": bool(s, "approved") ?? false,
            "notes": string(s, "notes") ?? "",
            "aiGenerated": bool(s, "aiGenerated") ?? false,
            // Derived fields (§5-D) — NOT echoed; recompute from RecipeRepository.
            "ingredients": [[String: Any]](),
        ]

        // Required date fields.
        d["mealDate"] = iso8601(date(s, "mealDate") ?? Date(timeIntervalSince1970: 0))
        d["updatedAt"] = iso8601(date(s, "updatedAt") ?? Date())

        // Optional scalars.
        if let v = double(s, "servings") { d["servings"] = v }
        if let recipeId = rec.refs["recipe"] { d["recipeId"] = recipeId }

        // Sides.
        d["sides"] = sides.map { sideDict($0, weekMealId: rec.recordName) }

        return d
    }

    /// Build a side dictionary (for JSON round-trip to WeekMealSide).
    private static func sideDict(_ rec: HouseholdRecordValue, weekMealId: String) -> [String: Any] {
        let s = rec.scalars
        var d: [String: Any] = [
            "sideId": rec.recordName,
            "weekMealId": weekMealId,
            "name": string(s, "name") ?? "",
            "notes": string(s, "notes") ?? "",
            "sortOrder": int(s, "sortOrder") ?? 0,
        ]
        d["updatedAt"] = iso8601(date(s, "updatedAt") ?? Date())

        if let v = string(s, "recipeName") { d["recipeName"] = v }
        if let rid = rec.refs["recipe"]    { d["recipeId"]   = rid }

        return d
    }

    // MARK: - Scalar accessors

    private static func string(_ scalars: [String: ScalarValue], _ key: String) -> String? {
        if case let .string(v) = scalars[key] { return v }
        return nil
    }

    private static func int(_ scalars: [String: ScalarValue], _ key: String) -> Int? {
        if case let .int(v) = scalars[key] { return v }
        return nil
    }

    private static func double(_ scalars: [String: ScalarValue], _ key: String) -> Double? {
        if case let .double(v) = scalars[key] { return v }
        return nil
    }

    private static func bool(_ scalars: [String: ScalarValue], _ key: String) -> Bool? {
        if case let .bool(v) = scalars[key] { return v }
        return nil
    }

    private static func date(_ scalars: [String: ScalarValue], _ key: String) -> Date? {
        if case let .date(v) = scalars[key] { return v }
        return nil
    }

    private static func set(_ scalars: inout [String: ScalarValue], _ key: String, _ value: ScalarValue) {
        scalars[key] = value
    }

    private static func setIfNonEmpty(_ scalars: inout [String: ScalarValue], _ key: String, _ value: String) {
        if !value.isEmpty { scalars[key] = .string(value) }
    }

    private static func iso8601(_ date: Date) -> String {
        iso8601Formatter.string(from: date)
    }
}
