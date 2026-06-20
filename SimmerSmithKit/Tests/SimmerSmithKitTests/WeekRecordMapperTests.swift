import Foundation
import Testing
import HouseholdRecords
@testable import SimmerSmithKit

// SP-C Task 2 — Headless unit tests for WeekRecordMapper.
// WeekSnapshot is Codable so instances are built via JSON round-trip (makeWeek/makeWeekMeal/makeWeekMealSide).
// Mirrors RecipeRecordMapperTests conventions.

// MARK: - Test helpers

private let weekDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        // Try ISO8601 first, then date-only (YYYY-MM-DD), then numeric timestamp.
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        // Date-only: 2026-06-29
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "UTC")
        if let d = dateFormatter.date(from: s) { return d }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Cannot decode date: \(s)")
        )
    }
    return d
}()

private func makeWeek(_ overrides: [String: Any] = [:]) -> WeekSnapshot {
    var base: [String: Any] = [
        "weekId": "W-test",
        "weekStart": "2026-06-29T00:00:00Z",
        "weekEnd": "2026-07-05T00:00:00Z",
        "status": "staging",
        "notes": "",
        "updatedAt": "2026-06-29T12:00:00Z",
        "stagedChangeCount": 0,
        "feedbackCount": 0,
        "exportCount": 0,
        "meals": [[String: Any]](),
        "groceryItems": [[String: Any]](),
        "nutritionTotals": [[String: Any]](),
    ]
    for (k, v) in overrides { base[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: base)
    return try! weekDecoder.decode(WeekSnapshot.self, from: data)
}

private func makeMealDict(
    id: String = "meal-1",
    day: String = "Monday",
    date: String = "2026-06-29T00:00:00Z",
    slot: String = "dinner",
    recipeName: String = "Tacos",
    recipeId: String? = "R1",
    servings: Double? = 4.0,
    scaleMultiplier: Double = 1.0,
    approved: Bool = false,
    aiGenerated: Bool = false,
    sides: [[String: Any]] = []
) -> [String: Any] {
    var d: [String: Any] = [
        "mealId": id,
        "dayName": day,
        "mealDate": date,
        "slot": slot,
        "recipeName": recipeName,
        "scaleMultiplier": scaleMultiplier,
        "source": "user",
        "approved": approved,
        "notes": "",
        "aiGenerated": aiGenerated,
        "updatedAt": "2026-06-29T12:00:00Z",
        "ingredients": [[String: Any]](),
        "sides": sides,
    ]
    if let rid = recipeId { d["recipeId"] = rid }
    if let s = servings { d["servings"] = s }
    return d
}

private func makeSideDict(
    id: String = "side-1",
    weekMealId: String = "meal-1",
    name: String = "Guacamole",
    notes: String = "",
    sortOrder: Int = 0,
    recipeId: String? = nil,
    recipeName: String? = nil
) -> [String: Any] {
    var d: [String: Any] = [
        "sideId": id,
        "weekMealId": weekMealId,
        "name": name,
        "notes": notes,
        "sortOrder": sortOrder,
        "updatedAt": "2026-06-29T12:00:00Z",
    ]
    if let rid = recipeId { d["recipeId"] = rid }
    if let rn = recipeName { d["recipeName"] = rn }
    return d
}

// MARK: - Round-trip test: week + 2 meals + 1 side

@Test func weekRoundTripWithMealsAndSide() {
    let side1 = makeSideDict(id: "side-1", weekMealId: "meal-1",
                              name: "Guacamole", notes: "extra lime",
                              sortOrder: 0, recipeId: "R2", recipeName: "Guac")
    let meal1 = makeMealDict(id: "meal-1", day: "Monday", slot: "dinner",
                              recipeName: "Tacos", recipeId: "R1", servings: 4.0,
                              scaleMultiplier: 1.5, approved: true, sides: [side1])
    let meal2 = makeMealDict(id: "meal-2", day: "Tuesday", slot: "lunch",
                              recipeName: "Salad", recipeId: nil, servings: nil,
                              scaleMultiplier: 1.0, approved: false, sides: [])
    let week = makeWeek([
        "weekId": "W1",
        "status": "approved",
        "notes": "good week",
        "meals": [meal1, meal2],
    ])

    // Forward: domain → records.
    let recs = WeekRecordMapper.records(from: week)

    // Week record.
    #expect(recs.week.recordName == "W1")
    #expect(recs.week.type == .week)
    #expect(recs.week.scalars["status"] == .string("approved"))
    #expect(recs.week.scalars["notes"] == .string("good week"))
    #expect(recs.week.refs.isEmpty)
    if case .date? = recs.week.scalars["weekStart"] {} else { Issue.record("weekStart missing") }
    if case .date? = recs.week.scalars["weekEnd"]   {} else { Issue.record("weekEnd missing") }

    // Meal records.
    #expect(recs.meals.count == 2)
    let mealRec1 = recs.meals.first { $0.recordName == "meal-1" }!
    #expect(mealRec1.type == .weekMeal)
    #expect(mealRec1.scalars["slot"] == .string("dinner"))
    #expect(mealRec1.scalars["recipeName"] == .string("Tacos"))
    #expect(mealRec1.scalars["servings"] == .double(4.0))
    #expect(mealRec1.scalars["scaleMultiplier"] == .double(1.5))
    #expect(mealRec1.scalars["approved"] == .bool(true))
    #expect(mealRec1.refs["week"] == "W1")         // cascade parent
    #expect(mealRec1.refs["recipe"] == "R1")       // set-null ref

    let mealRec2 = recs.meals.first { $0.recordName == "meal-2" }!
    #expect(mealRec2.refs["recipe"] == nil)        // no recipeId → no ref

    // Side record.
    #expect(recs.sides.count == 1)
    let sideRec = recs.sides[0]
    #expect(sideRec.type == .weekMealSide)
    #expect(sideRec.recordName == "side-1")
    #expect(sideRec.scalars["name"] == .string("Guacamole"))
    #expect(sideRec.scalars["notes"] == .string("extra lime"))
    #expect(sideRec.scalars["sortOrder"] == .int(0))
    #expect(sideRec.scalars["recipeName"] == .string("Guac"))
    #expect(sideRec.refs["weekMeal"] == "meal-1")  // cascade parent
    #expect(sideRec.refs["recipe"] == "R2")        // set-null ref

    // Reverse: records → domain.
    let sidesByMeal: [String: [HouseholdRecordValue]] = ["meal-1": [sideRec]]
    let back = WeekRecordMapper.week(
        from: recs.week,
        meals: recs.meals,
        sidesByMeal: sidesByMeal
    )

    #expect(back.weekId == "W1")
    #expect(back.status == "approved")
    #expect(back.notes == "good week")
    #expect(back.meals.count == 2)

    let backMeal1 = back.meals.first { $0.mealId == "meal-1" }!
    #expect(backMeal1.slot == "dinner")
    #expect(backMeal1.recipeName == "Tacos")
    #expect(backMeal1.servings == 4.0)
    #expect(backMeal1.scaleMultiplier == 1.5)
    #expect(backMeal1.approved == true)
    #expect(backMeal1.recipeId == "R1")
    #expect(backMeal1.sides.count == 1)

    let backSide = backMeal1.sides[0]
    #expect(backSide.sideId == "side-1")
    #expect(backSide.weekMealId == "meal-1")
    #expect(backSide.name == "Guacamole")
    #expect(backSide.notes == "extra lime")
    #expect(backSide.sortOrder == 0)
    #expect(backSide.recipeId == "R2")
    #expect(backSide.recipeName == "Guac")

    let backMeal2 = back.meals.first { $0.mealId == "meal-2" }!
    #expect(backMeal2.sides.isEmpty)
    #expect(backMeal2.recipeId == nil)

    // Derived fields (§5-D) are NOT fabricated.
    #expect(back.stagedChangeCount == 0)
    #expect(back.feedbackCount == 0)
    #expect(back.exportCount == 0)
    #expect(back.nutritionTotals.isEmpty)
    #expect(back.weeklyTotals == nil)
    // Meal ingredients are NOT echoed (recomputed from RecipeRepository).
    #expect(backMeal1.ingredients.isEmpty)
    #expect(backMeal1.macros == nil)
}

// MARK: - .weekMealSide manifest ref kinds (the irreversible classification)

@Test func weekMealSideRefsClassification() {
    let refs = HouseholdRecordType.weekMealSide.refs
    #expect(refs.first { $0.name == "weekMeal" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "recipe" }?.kind == .setNullInZone)
}

// MARK: - Minimal week (no meals, no sides)

@Test func minimalWeekRoundTrip() {
    let week = makeWeek(["weekId": "W-min", "status": "staging"])
    let recs = WeekRecordMapper.records(from: week)
    #expect(recs.week.recordName == "W-min")
    #expect(recs.meals.isEmpty)
    #expect(recs.sides.isEmpty)

    let back = WeekRecordMapper.week(from: recs.week, meals: [], sidesByMeal: [:])
    #expect(back.weekId == "W-min")
    #expect(back.status == "staging")
    #expect(back.meals.isEmpty)
    #expect(back.groceryItems.isEmpty)
}

// MARK: - Optional date fields

@Test func weekOptionalDatesRoundTrip() {
    let week = makeWeek([
        "weekId": "W-dates",
        "approvedAt": "2026-06-29T12:00:00Z",
        "readyForAiAt": "2026-06-28T10:00:00Z",
    ])
    let recs = WeekRecordMapper.records(from: week)
    if case .date? = recs.week.scalars["approvedAt"]   {} else { Issue.record("approvedAt missing") }
    if case .date? = recs.week.scalars["readyForAIAt"] {} else { Issue.record("readyForAIAt missing") }
    #expect(recs.week.scalars["pricedAt"] == nil)  // not set → absent

    let back = WeekRecordMapper.week(from: recs.week, meals: [], sidesByMeal: [:])
    #expect(back.approvedAt != nil)
    #expect(back.readyForAiAt != nil)
    #expect(back.pricedAt == nil)
}

// MARK: - Side with no recipeId (anonymous side dish)

@Test func sideWithNoRecipeIdOmitsRef() {
    let sideDict = makeSideDict(id: "side-anon", weekMealId: "meal-1",
                                 name: "Rice", recipeId: nil, recipeName: nil)
    let meal = makeMealDict(id: "meal-1", sides: [sideDict])
    let week = makeWeek(["weekId": "W-anon", "meals": [meal]])
    let recs = WeekRecordMapper.records(from: week)
    let sideRec = recs.sides.first!
    #expect(sideRec.refs["recipe"] == nil)
    #expect(sideRec.scalars["recipeName"] == nil)
}
