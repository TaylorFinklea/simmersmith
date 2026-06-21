import Foundation
import Testing
import HouseholdRecords
@testable import SimmerSmithKit

// SP-C Task 4 — Headless unit tests for EventRecordMapper.
// Domain types are built via JSON round-trip (mirroring WeekRecordMapperTests conventions).
// Covers: Event + 2 meals + ingredients + 1 attendee + a Guest.

// MARK: - Test decoder

private let eventDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

// MARK: - Domain-object factories (JSON round-trip)

private func makeGuest(
    id: String = "G1",
    name: String = "Alice",
    relationshipLabel: String = "friend",
    dietaryNotes: String = "",
    allergies: String = "peanuts",
    ageGroup: String = "adult",
    active: Bool = true
) -> Guest {
    Guest(
        guestId: id,
        name: name,
        relationshipLabel: relationshipLabel,
        dietaryNotes: dietaryNotes,
        allergies: allergies,
        ageGroup: ageGroup,
        active: active,
        createdAt: Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_100_000)
    )
}

private func makeIngredientDict(
    id: String = "EMI-1",
    name: String = "Flour",
    quantity: Double? = 2.0,
    unit: String = "cups",
    prep: String = "sifted",
    category: String = "pantry",
    notes: String = "",
    baseIngredientId: String? = nil,
    variationId: String? = nil
) -> [String: Any] {
    var d: [String: Any] = [
        "ingredientId": id,
        "ingredientName": name,
        "unit": unit,
        "prep": prep,
        "category": category,
        "notes": notes,
    ]
    if let v = quantity          { d["quantity"] = v }
    if let v = baseIngredientId  { d["baseIngredientId"] = v }
    if let v = variationId       { d["ingredientVariationId"] = v }
    return d
}

private func makeMealDict(
    id: String = "EM-1",
    role: String = "main",
    recipeName: String = "Roast Chicken",
    recipeId: String? = "R1",
    servings: Double? = 6.0,
    scaleMultiplier: Double = 1.0,
    notes: String = "",
    sortOrder: Int = 0,
    aiGenerated: Bool = false,
    approved: Bool = true,
    assignedGuestId: String? = nil,
    constraintCoverage: [String] = [],
    ingredients: [[String: Any]] = []
) -> [String: Any] {
    var d: [String: Any] = [
        "mealId": id,
        "role": role,
        "recipeName": recipeName,
        "scaleMultiplier": scaleMultiplier,
        "notes": notes,
        "sortOrder": sortOrder,
        "aiGenerated": aiGenerated,
        "approved": approved,
        "constraintCoverage": constraintCoverage,
        "ingredients": ingredients,
        "createdAt": "2026-06-20T10:00:00Z",
        "updatedAt": "2026-06-20T10:00:00Z",
    ]
    if let rid = recipeId         { d["recipeId"] = rid }
    if let v = servings           { d["servings"] = v }
    if let gid = assignedGuestId  { d["assignedGuestId"] = gid }
    return d
}

private func makeAttendeeDict(
    guestId: String = "G1",
    plusOnes: Int = 0,
    guest: [String: Any]? = nil
) -> [String: Any] {
    let guestDict: [String: Any] = guest ?? [
        "guestId": guestId,
        "name": "Alice",
        "relationshipLabel": "friend",
        "dietaryNotes": "",
        "allergies": "peanuts",
        "ageGroup": "adult",
        "active": true,
        "createdAt": "2026-06-20T10:00:00Z",
        "updatedAt": "2026-06-20T10:00:00Z",
    ]
    return [
        "guestId": guestId,
        "plusOnes": plusOnes,
        "guest": guestDict,
    ]
}

private func makeEventDict(
    id: String = "E1",
    name: String = "Birthday Party",
    eventDate: String? = "2026-07-04T18:00:00Z",
    occasion: String = "birthday",
    attendeeCount: Int = 10,
    notes: String = "BYOB",
    status: String = "planning",
    linkedWeekId: String? = nil,
    autoMergeGrocery: Bool = true,
    meals: [[String: Any]] = [],
    attendees: [[String: Any]] = []
) -> [String: Any] {
    var d: [String: Any] = [
        "eventId": id,
        "name": name,
        "occasion": occasion,
        "attendeeCount": attendeeCount,
        "notes": notes,
        "status": status,
        "autoMergeGrocery": autoMergeGrocery,
        "mealCount": meals.count,
        "meals": meals,
        "attendees": attendees,
        "groceryItems": [[String: Any]](),
        "pantrySupplements": [[String: Any]](),
        "createdAt": "2026-06-20T10:00:00Z",
        "updatedAt": "2026-06-20T10:00:00Z",
    ]
    if let d2 = eventDate     { d["eventDate"] = d2 }
    if let wid = linkedWeekId { d["linkedWeekId"] = wid }
    return d
}

private func decodeEvent(_ dict: [String: Any]) -> Event {
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! eventDecoder.decode(Event.self, from: data)
}

// MARK: - Tests

// Full round-trip: event + 2 meals (with ingredients) + 1 attendee + a guest.

@Test func eventRoundTripWithMealsAndAttendee() {
    let ing1 = makeIngredientDict(id: "EMI-1", name: "Flour", quantity: 2.0, unit: "cups",
                                   prep: "sifted", category: "pantry", baseIngredientId: "BI-1")
    let ing2 = makeIngredientDict(id: "EMI-2", name: "Butter", quantity: 0.5, unit: "cup",
                                   prep: "", category: "dairy", variationId: "V-1")
    let meal1 = makeMealDict(id: "EM-1", role: "main", recipeName: "Roast Chicken",
                              recipeId: "R1", servings: 6.0, scaleMultiplier: 1.5,
                              notes: "crispy skin", sortOrder: 0, approved: true,
                              constraintCoverage: ["G2", "G3"],
                              ingredients: [ing1, ing2])
    let meal2 = makeMealDict(id: "EM-2", role: "dessert", recipeName: "Chocolate Cake",
                              recipeId: nil, servings: nil, scaleMultiplier: 1.0,
                              sortOrder: 1, approved: false,
                              assignedGuestId: "G1",
                              ingredients: [])
    let attendee = makeAttendeeDict(guestId: "G1", plusOnes: 2)
    let event = decodeEvent(makeEventDict(
        id: "E1",
        name: "Birthday Party",
        eventDate: "2026-07-04T18:00:00Z",
        occasion: "birthday",
        attendeeCount: 10,
        notes: "BYOB",
        status: "planning",
        linkedWeekId: "W-42",
        autoMergeGrocery: true,
        meals: [meal1, meal2],
        attendees: [attendee]
    ))

    // --- Forward: domain → records ---
    let recs = EventRecordMapper.records(from: event)

    // Event record.
    #expect(recs.event.recordName == "E1")
    #expect(recs.event.type == .event)
    #expect(recs.event.scalars["name"] == .string("Birthday Party"))
    #expect(recs.event.scalars["occasion"] == .string("birthday"))
    #expect(recs.event.scalars["attendeeCount"] == .int(10))
    #expect(recs.event.scalars["notes"] == .string("BYOB"))
    #expect(recs.event.scalars["status"] == .string("planning"))
    #expect(recs.event.scalars["autoMergeGrocery"] == .bool(true))
    if case .date? = recs.event.scalars["eventDate"] {} else { Issue.record("eventDate missing") }
    if case .date? = recs.event.scalars["createdAt"] {} else { Issue.record("createdAt missing") }
    if case .date? = recs.event.scalars["updatedAt"] {} else { Issue.record("updatedAt missing") }
    // linkedWeekId stored as crossDBString ref.
    #expect(recs.event.refs["linkedWeekID"] == "W-42")

    // Meal records.
    #expect(recs.meals.count == 2)
    let mealRec1 = recs.meals.first { $0.recordName == "EM-1" }!
    #expect(mealRec1.type == .eventMeal)
    #expect(mealRec1.scalars["role"] == .string("main"))
    #expect(mealRec1.scalars["recipeName"] == .string("Roast Chicken"))
    #expect(mealRec1.scalars["servings"] == .double(6.0))
    #expect(mealRec1.scalars["scaleMultiplier"] == .double(1.5))
    #expect(mealRec1.scalars["approved"] == .bool(true))
    #expect(mealRec1.scalars["sortOrder"] == .int(0))
    #expect(mealRec1.refs["event"] == "E1")   // cascadeParent
    #expect(mealRec1.refs["recipe"] == "R1")  // setNullInZone
    // constraintCoverage serialised as JSON array string.
    if case let .string(cc) = mealRec1.scalars["constraintCoverage"] {
        #expect(cc.contains("G2"))
    } else {
        Issue.record("constraintCoverage missing or wrong type")
    }

    let mealRec2 = recs.meals.first { $0.recordName == "EM-2" }!
    #expect(mealRec2.refs["recipe"] == nil)           // no recipeId
    #expect(mealRec2.refs["assignedGuest"] == "G1")   // setNullInZone

    // Ingredient records (belong to meal1 only).
    #expect(recs.ingredients.count == 2)
    let ingRec1 = recs.ingredients.first { $0.recordName == "EMI-1" }!
    #expect(ingRec1.type == .eventMealIngredient)
    #expect(ingRec1.scalars["ingredientName"] == .string("Flour"))
    #expect(ingRec1.scalars["quantity"] == .double(2.0))
    #expect(ingRec1.scalars["unit"] == .string("cups"))
    #expect(ingRec1.scalars["prep"] == .string("sifted"))
    #expect(ingRec1.scalars["category"] == .string("pantry"))
    #expect(ingRec1.refs["eventMeal"] == "EM-1")    // cascadeParent
    #expect(ingRec1.refs["baseIngredientID"] == "BI-1")  // crossDBString

    let ingRec2 = recs.ingredients.first { $0.recordName == "EMI-2" }!
    #expect(ingRec2.refs["ingredientVariationID"] == "V-1")  // crossDBString
    #expect(ingRec2.refs["baseIngredientID"] == nil)

    // Attendee record.
    #expect(recs.attendees.count == 1)
    let attRec = recs.attendees[0]
    #expect(attRec.type == .eventAttendee)
    #expect(attRec.recordName == "E1_G1")   // det-key <eventID>_<guestID>
    #expect(attRec.scalars["plusOnes"] == .int(2))
    #expect(attRec.refs["event"] == "E1")   // cascadeParent
    #expect(attRec.refs["guest"] == "G1")   // setNullInZone

    // --- Reverse: records → domain ---
    let ingredientsByMeal: [String: [HouseholdRecordValue]] = ["EM-1": [ingRec1, ingRec2]]
    let back = EventRecordMapper.event(
        from: recs.event,
        meals: recs.meals,
        ingredientsByMeal: ingredientsByMeal,
        attendees: recs.attendees
    )

    #expect(back.eventId == "E1")
    #expect(back.name == "Birthday Party")
    #expect(back.occasion == "birthday")
    #expect(back.attendeeCount == 10)
    #expect(back.notes == "BYOB")
    #expect(back.status == "planning")
    #expect(back.autoMergeGrocery == true)
    #expect(back.linkedWeekId == "W-42")
    #expect(back.eventDate != nil)
    #expect(back.meals.count == 2)

    let backMeal1 = back.meals.first { $0.mealId == "EM-1" }!
    #expect(backMeal1.role == "main")
    #expect(backMeal1.recipeName == "Roast Chicken")
    #expect(backMeal1.servings == 6.0)
    #expect(backMeal1.scaleMultiplier == 1.5)
    #expect(backMeal1.approved == true)
    #expect(backMeal1.recipeId == "R1")
    #expect(backMeal1.constraintCoverage == ["G2", "G3"])
    #expect(backMeal1.ingredients.count == 2)

    let backIng1 = backMeal1.ingredients.first { $0.ingredientId == "EMI-1" }!
    #expect(backIng1.ingredientName == "Flour")
    #expect(backIng1.quantity == 2.0)
    #expect(backIng1.unit == "cups")
    #expect(backIng1.prep == "sifted")
    #expect(backIng1.category == "pantry")
    #expect(backIng1.baseIngredientId == "BI-1")

    let backIng2 = backMeal1.ingredients.first { $0.ingredientId == "EMI-2" }!
    #expect(backIng2.ingredientVariationId == "V-1")
    #expect(backIng2.baseIngredientId == nil)

    let backMeal2 = back.meals.first { $0.mealId == "EM-2" }!
    #expect(backMeal2.recipeId == nil)
    #expect(backMeal2.assignedGuestId == "G1")
    #expect(backMeal2.ingredients.isEmpty)

    // Attendees round-trip.
    #expect(back.attendees.count == 1)
    let backAtt = back.attendees[0]
    #expect(backAtt.guestId == "G1")
    #expect(backAtt.plusOnes == 2)

    // Derived fields (§D) — NOT fabricated.
    #expect(back.groceryItems.isEmpty)
    #expect(back.pantrySupplements.isEmpty)
    // mealCount is recomputed from meals.count on reverse (not stored).
    #expect(back.mealCount == 2)
}

// MARK: - Guest round-trip

@Test func guestRoundTrip() {
    let guest = makeGuest(id: "G99", name: "Bob", relationshipLabel: "cousin",
                           allergies: "shellfish", ageGroup: "teen", active: false)

    let rec = EventRecordMapper.record(from: guest)
    #expect(rec.recordName == "G99")
    #expect(rec.type == .guest)
    #expect(rec.scalars["name"] == .string("Bob"))
    #expect(rec.scalars["relationshipLabel"] == .string("cousin"))
    #expect(rec.scalars["allergies"] == .string("shellfish"))
    #expect(rec.scalars["ageGroup"] == .string("teen"))
    #expect(rec.scalars["active"] == .bool(false))
    if case .date? = rec.scalars["createdAt"] {} else { Issue.record("createdAt missing") }
    if case .date? = rec.scalars["updatedAt"] {} else { Issue.record("updatedAt missing") }
    #expect(rec.refs.isEmpty)

    let back = EventRecordMapper.guest(from: rec)
    #expect(back.guestId == "G99")
    #expect(back.name == "Bob")
    #expect(back.relationshipLabel == "cousin")
    #expect(back.allergies == "shellfish")
    #expect(back.ageGroup == "teen")
    #expect(back.active == false)
}

// MARK: - Minimal event (no meals, no attendees, no linked week)

@Test func minimalEventRoundTrip() {
    let event = decodeEvent(makeEventDict(
        id: "E-min",
        name: "Quick Dinner",
        eventDate: nil,
        linkedWeekId: nil,
        meals: [],
        attendees: []
    ))

    let recs = EventRecordMapper.records(from: event)
    #expect(recs.event.recordName == "E-min")
    #expect(recs.meals.isEmpty)
    #expect(recs.ingredients.isEmpty)
    #expect(recs.attendees.isEmpty)
    #expect(recs.event.scalars["eventDate"] == nil)   // absent when nil
    #expect(recs.event.refs["linkedWeekID"] == nil)   // absent when nil

    let back = EventRecordMapper.event(
        from: recs.event,
        meals: [],
        ingredientsByMeal: [:],
        attendees: []
    )
    #expect(back.eventId == "E-min")
    #expect(back.meals.isEmpty)
    #expect(back.attendees.isEmpty)
    #expect(back.eventDate == nil)
    #expect(back.linkedWeekId == nil)
}

// MARK: - Attendee det-key derivation

@Test func attendeeDetKey() {
    let attendee = makeAttendeeDict(guestId: "G-alpha", plusOnes: 1)
    let event = decodeEvent(makeEventDict(id: "E-key", attendees: [attendee]))
    let recs = EventRecordMapper.records(from: event)
    #expect(recs.attendees[0].recordName == "E-key_G-alpha")
}

// MARK: - constraintCoverage serialisation (§B)

@Test func constraintCoverageSerialisation() {
    let coverage = ["G1", "G2", "G3"]
    let encoded = EventRecordMapper.encodeStringArray(coverage)
    let decoded = EventRecordMapper.decodeStringArray(encoded)
    #expect(decoded == coverage)

    // Empty array encodes cleanly.
    #expect(EventRecordMapper.decodeStringArray(EventRecordMapper.encodeStringArray([])) == [])

    // Malformed input → empty.
    #expect(EventRecordMapper.decodeStringArray("") == [])
    #expect(EventRecordMapper.decodeStringArray("not-json") == [])
}

// MARK: - .eventAttendee manifest ref classification

@Test func eventAttendeeRefsClassification() {
    let refs = HouseholdRecordType.eventAttendee.refs
    #expect(refs.first { $0.name == "event" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "guest" }?.kind == .setNullInZone)
}

// MARK: - .eventMeal manifest ref classification

@Test func eventMealRefsClassification() {
    let refs = HouseholdRecordType.eventMeal.refs
    #expect(refs.first { $0.name == "event" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "recipe" }?.kind == .setNullInZone)
    #expect(refs.first { $0.name == "assignedGuest" }?.kind == .setNullInZone)
}

// MARK: - .event linkedWeekID is crossDBString

@Test func eventLinkedWeekIDIsCrossDBString() {
    let refs = HouseholdRecordType.event.refs
    #expect(refs.first { $0.name == "linkedWeekID" }?.kind == .crossDBString)
}

// MARK: - Ingredient with no optional fields

@Test func ingredientNoOptionalFields() {
    let ing = makeIngredientDict(id: "EMI-bare", name: "Salt", quantity: nil,
                                  unit: "", prep: "", category: "", baseIngredientId: nil, variationId: nil)
    let meal = makeMealDict(id: "EM-bare", ingredients: [ing])
    let event = decodeEvent(makeEventDict(id: "E-bare", meals: [meal]))
    let recs = EventRecordMapper.records(from: event)
    let ingRec = recs.ingredients.first { $0.recordName == "EMI-bare" }!
    #expect(ingRec.scalars["quantity"] == nil)
    #expect(ingRec.refs["baseIngredientID"] == nil)
    #expect(ingRec.refs["ingredientVariationID"] == nil)
    // unit/prep/category omitted when empty (setIfNonEmpty)
    #expect(ingRec.scalars["unit"] == nil)
}
