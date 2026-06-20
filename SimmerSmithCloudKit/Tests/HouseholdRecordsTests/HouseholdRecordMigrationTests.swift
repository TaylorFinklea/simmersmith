import Foundation
import Testing
import CloudKit
@testable import HouseholdRecords

// SP-A Phase 7 — the generic Postgres→CloudKit migration transform for the 12 plain-CRUD
// household record types. The column mapping is IRREVERSIBLE (it's the migration contract), so
// these pin: acronym-aware snake_case, the .pk/.det recordName policy, ref-column derivation,
// defensive null/type handling, the one hand-renamed column (Guest.relationship), and a full
// migrate→encode→decode round-trip (CloudKit is headless on macOS).

// MARK: acronym-aware snake_case (the load-bearing column derivation)

@Test func snakeCase_handlesAcronymRunsAndBoundaries() {
    #expect(snakeCase("mealType") == "meal_type")
    #expect(snakeCase("instructionsSummary") == "instructions_summary")
    #expect(snakeCase("sourceURL") == "source_url")                       // trailing acronym
    #expect(snakeCase("overridePayloadJSON") == "override_payload_json")  // mid+trailing acronym
    #expect(snakeCase("recipeTemplateID") == "recipe_template_id")        // ID suffix
    #expect(snakeCase("proteinG") == "protein_g")                         // single-letter acronym
    #expect(snakeCase("upc") == "upc")                                    // already lower
    #expect(snakeCase("plusOnes") == "plus_ones")
    #expect(snakeCase("value") == "value")
    #expect(snakeCase("nutritionReferenceAmount") == "nutrition_reference_amount")
}

// MARK: .pk type — full field/ref/date/bool/null coverage (Recipe)

@Test func migrateRecipe_mapsScalarsRefsDatesBoolsAndSkipsNulls() {
    let row: [String: Any] = [
        "id": "R1",
        "name": "Lasagna", "meal_type": "dinner", "cuisine": "italian",
        "servings": NSNumber(value: 6), "prep_minutes": NSNumber(value: 30),
        "favorite": NSNumber(value: true), "archived": NSNumber(value: 0),
        "source_url": "https://x.test/l", "override_payload_json": "{\"a\":1}",
        "instructions_summary": "layer + bake",
        "created_at": "2026-06-16T20:22:00Z",
        "last_used": "2026-06-10",
        "cook_minutes": NSNull(),                       // explicit null → absent
        "base_recipe_id": "R0",                         // in-zone SET-NULL ref
        "recipe_template_id": "TPL9",                   // cross-DB String ref
    ]
    let v = migrateHouseholdRecord(.recipe, row)
    #expect(v?.recordName == "R1")
    #expect(v?.scalars["name"] == .string("Lasagna"))
    #expect(v?.scalars["mealType"] == .string("dinner"))
    #expect(v?.scalars["servings"] == .double(6))
    #expect(v?.scalars["prepMinutes"] == .int(30))
    #expect(v?.scalars["favorite"] == .bool(true))
    #expect(v?.scalars["archived"] == .bool(false))
    #expect(v?.scalars["sourceURL"] == .string("https://x.test/l"))
    #expect(v?.scalars["overridePayloadJSON"] == .string("{\"a\":1}"))
    #expect(v?.scalars["cookMinutes"] == nil)           // null column stays absent
    #expect(v?.scalars["notes"] == nil)                 // missing column stays absent
    #expect(v?.refs["baseRecipe"] == "R0")
    #expect(v?.refs["recipeTemplateID"] == "TPL9")
    // Dates parsed (datetime + date-only forms).
    if case .date(let d)? = v?.scalars["createdAt"] {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2026, 6, 16, 20, 22, 0)
        c.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(abs(d.timeIntervalSince(cal.date(from: c)!)) < 1)   // 2026-06-16T20:22:00Z
    } else { Issue.record("createdAt not parsed") }
    #expect({ if case .date? = v?.scalars["lastUsed"] { return true }; return false }())
}

// MARK: date parser robustness (adversarial-review-driven — micros / space sep / no offset)

@Test func migrate_parsesEveryRealisticTimestampShape() {
    // All represent the same instant 2026-06-16T20:22:00(.000000) UTC (the date-only form is midnight).
    let forms = [
        "2026-06-16T20:22:00Z",                  // ISO8601, Z
        "2026-06-16T20:22:00+00:00",             // ISO8601, offset
        "2026-06-16T20:22:00.123Z",              // ISO8601, millis
        "2026-06-16T20:22:00.123456+00:00",      // Python isoformat, microseconds (ISO8601DateFormatter rejects)
        "2026-06-16T20:22:00.123456",            // isoformat, microseconds, naive
        "2026-06-16T20:22:00",                   // naive, T
        "2026-06-16 20:22:00+00:00",             // Postgres str(), space separator
        "2026-06-16 20:22:00.123456+00:00",      // space, microseconds
        "2026-06-16 20:22:00",                   // space, naive
        "2026-06-16",                            // Date column
    ]
    for form in forms {
        let v = migrateHouseholdRecord(.recipe, ["id": "R", "created_at": form])
        if case .date? = v?.scalars["createdAt"] {} else {
            Issue.record("timestamp form not parsed: \(form)")
        }
    }
    // A garbage string is dropped (absent), not a crash.
    #expect(migrateHouseholdRecord(.recipe, ["id": "R", "created_at": "not a date"])?.scalars["createdAt"] == nil)
}

// MARK: missing identity → nil

@Test func migrate_returnsNilWithoutIdentity() {
    #expect(migrateHouseholdRecord(.recipe, ["name": "x"]) == nil)         // no id
    #expect(migrateHouseholdRecord(.recipe, ["id": ""]) == nil)           // empty id
    #expect(migrateHouseholdRecord(.recipe, ["id": NSNull()]) == nil)     // null id
    #expect(migrateHouseholdRecord(.householdSetting, ["value": "v"]) == nil)   // no key
    #expect(migrateHouseholdRecord(.eventAttendee, ["event_id": "E"]) == nil)   // missing guest_id
}

// MARK: .det recordName policy

@Test func migrate_detRecordNames() {
    #expect(migrateHouseholdRecord(.householdSetting, ["key": "Theme Mode", "value": "dark"])?.recordName
            == "hset:theme mode")                                          // normalized
    #expect(migrateHouseholdRecord(.householdTermAlias, ["term": "  EVOO ", "expansion": "olive oil"])?.recordName
            == "alias:evoo")
    let att = migrateHouseholdRecord(.eventAttendee, ["event_id": "EV1", "guest_id": "G1", "plus_ones": NSNumber(value: 2)])
    #expect(att?.recordName == "EV1_G1")
    #expect(att?.scalars["plusOnes"] == .int(2))
    #expect(att?.refs["event"] == "EV1" && att?.refs["guest"] == "G1")     // junction cols are also refs
}

// MARK: the one hand-renamed column

@Test func migrateGuest_readsRelationshipColumnNotRelationshipLabel() {
    let v = migrateHouseholdRecord(.guest, [
        "id": "G1", "name": "Aunt May", "relationship": "aunt",
        "active": NSNumber(value: true), "age_group": "adult"])
    #expect(v?.scalars["relationshipLabel"] == .string("aunt"))            // DB column `relationship`
    #expect(v?.scalars["name"] == .string("Aunt May"))
    #expect(v?.scalars["active"] == .bool(true))
}

// MARK: type mismatch is defensive (absent, not crash)

@Test func migrate_typeMismatchFallsToAbsent() {
    let v = migrateHouseholdRecord(.recipe, [
        "id": "R2", "servings": "not a number", "favorite": "yes", "prep_minutes": NSNull()])
    #expect(v?.recordName == "R2")
    #expect(v?.scalars["servings"] == nil)     // string in a double column → absent
    #expect(v?.scalars["favorite"] == nil)     // string in a bool column → absent
    #expect(v?.scalars["prepMinutes"] == nil)
}

// MARK: Phase-4-remainder week types — classification + migrate + cascade (irreversible)

@Test func migrateWeek_mapsDatesNoRefs() {
    let v = migrateHouseholdRecord(.week, [
        "id": "W1", "week_start": "2026-06-29", "week_end": "2026-07-05", "status": "approved",
        "notes": "n", "ready_for_ai_at": "2026-06-28T12:00:00Z", "approved_at": NSNull()])
    #expect(v?.recordName == "W1")
    #expect(v?.scalars["status"] == .string("approved"))
    #expect(v?.refs.isEmpty == true)                              // aggregate root, no outbound refs
    #expect({ if case .date? = v?.scalars["weekStart"] { return true }; return false }())
    #expect({ if case .date? = v?.scalars["readyForAIAt"] { return true }; return false }())
    #expect(v?.scalars["approvedAt"] == nil)                      // NSNull → absent
    #expect(HouseholdRecordType.week.refs.isEmpty)
}

@Test func migrateWeekMeal_cascadeWeekSetNullRecipe() {
    let row: [String: Any] = [
        "id": "M1", "week_id": "W1", "recipe_id": "R1", "day_name": "Monday", "meal_date": "2026-06-29",
        "slot": "dinner", "recipe_name": "Tacos", "servings": NSNumber(value: 4),
        "scale_multiplier": NSNumber(value: 1.5), "approved": NSNumber(value: true),
        "ai_generated": NSNumber(value: 0), "sort_order": NSNumber(value: 2)]
    let v = migrateHouseholdRecord(.weekMeal, row)!
    #expect(v.refs["week"] == "W1" && v.refs["recipe"] == "R1")
    #expect(v.scalars["slot"] == .string("dinner") && v.scalars["sortOrder"] == .int(2))
    #expect(v.scalars["approved"] == .bool(true) && v.scalars["aiGenerated"] == .bool(false))
    // Cascade vs SET-NULL ref kinds round-trip through the codec.
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let rec = HouseholdRecordCodec.encode(v, zoneID: zoneID)
    #expect((rec["week"] as? CKRecord.Reference)?.action == .deleteSelf)        // CASCADE
    #expect((rec["recipe"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none) // SET-NULL
}

@Test func migrateAuditTypes_cascadeChain() {
    let b = migrateHouseholdRecord(.weekChangeBatch, [
        "id": "B1", "week_id": "W1", "actor_type": "user", "actor_label": "Sam",
        "summary": "added 3 meals", "created_at": "2026-06-29T10:00:00Z"])!
    #expect(b.refs["week"] == "W1" && b.scalars["actorLabel"] == .string("Sam"))
    let e = migrateHouseholdRecord(.weekChangeEvent, [
        "id": "E1", "batch_id": "B1", "entity_type": "WeekMeal", "entity_id": "M1",
        "field_name": "slot", "before_value": "lunch", "after_value": "dinner"])!
    #expect(e.refs["batch"] == "B1" && e.scalars["entityID"] == .string("M1"))
    #expect(e.scalars["fieldName"] == .string("slot") && e.scalars["afterValue"] == .string("dinner"))
    // batch → WeekChangeBatch and batch's week → Week are both CASCADE (prune sweeps events).
    #expect(HouseholdRecordType.weekChangeEvent.refs.first?.kind == .cascadeParent)
    #expect(HouseholdRecordType.weekChangeBatch.refs.first?.kind == .cascadeParent)
}

// MARK: SP-C Task 2 — .weekMealSide manifest type

@Test func migrateWeekMealSide_cascadeWeekMealSetNullRecipe() {
    let row: [String: Any] = [
        "id": "S1",
        "week_meal_id": "M1",
        "recipe_id": "R1",
        "recipe_name": "Guac",
        "name": "Guacamole",
        "notes": "extra lime",
        "sort_order": NSNumber(value: 1),
        "created_at": "2026-06-29T10:00:00Z",
        "updated_at": "2026-06-29T11:00:00Z",
    ]
    let v = migrateHouseholdRecord(.weekMealSide, row)!
    #expect(v.recordName == "S1")
    #expect(v.scalars["name"] == .string("Guacamole"))
    #expect(v.scalars["recipeName"] == .string("Guac"))
    #expect(v.scalars["notes"] == .string("extra lime"))
    #expect(v.scalars["sortOrder"] == .int(1))
    #expect(v.refs["weekMeal"] == "M1")   // cascadeParent
    #expect(v.refs["recipe"] == "R1")     // setNullInZone
    // Verify ref kinds round-trip through the codec.
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let rec = HouseholdRecordCodec.encode(v, zoneID: zoneID)
    #expect((rec["weekMeal"] as? CKRecord.Reference)?.action == .deleteSelf)             // CASCADE
    #expect((rec["recipe"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none) // SET-NULL
    // Dates parsed.
    #expect({ if case .date? = v.scalars["createdAt"] { return true }; return false }())
    #expect({ if case .date? = v.scalars["updatedAt"] { return true }; return false }())
}

@Test func migrateWeekMealSide_noRecipeIsAbsent() {
    let v = migrateHouseholdRecord(.weekMealSide, [
        "id": "S2", "week_meal_id": "M1", "name": "Rice", "sort_order": NSNumber(value: 0)])
    #expect(v?.refs["recipe"] == nil)
    #expect(v?.scalars["recipeName"] == nil)
}

// MARK: Task 4b — ManagedListItem household type (det key, scalars, no refs)

@Test func migrateManagedListItem_detKeyAndScalars() {
    let row: [String: Any] = [
        "id": "M1",                              // legacy PK (unused for recordName)
        "kind": "cuisine",
        "name": "Italian",
        "normalized_name": "italian",
        "created_at": "2026-06-18T10:00:00Z",
        "updated_at": "2026-06-18T10:00:00Z",
    ]
    let v = migrateHouseholdRecord(.managedListItem, row)
    // recordName is deterministic: mli:<kind>:<normalized_name_of_name>
    #expect(v?.recordName == "mli:cuisine:italian")
    #expect(v?.scalars["kind"] == .string("cuisine"))
    #expect(v?.scalars["name"] == .string("Italian"))
    #expect(v?.scalars["normalizedName"] == .string("italian"))
    #expect(v?.refs.isEmpty == true)
    // dates parsed
    #expect({ if case .date? = v?.scalars["createdAt"] { return true }; return false }())
    #expect({ if case .date? = v?.scalars["updatedAt"] { return true }; return false }())
    // missing identity (kind or name absent) → nil
    #expect(migrateHouseholdRecord(.managedListItem, ["kind": "cuisine"]) == nil)   // no name
    #expect(migrateHouseholdRecord(.managedListItem, ["name": "Italian"]) == nil)   // no kind
}

// MARK: full migrate → encode → decode round-trip (headless CloudKit)

@Test func migrate_roundTripsThroughCodec() {
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let row: [String: Any] = [
        "id": "EM1", "event_id": "EV1", "recipe_id": "R1", "assigned_guest_id": "G1",
        "role": "main", "recipe_name": "Roast", "servings": NSNumber(value: 8),
        "scale_multiplier": NSNumber(value: 1.5), "ai_generated": NSNumber(value: 1),
        "approved": NSNumber(value: 0), "sort_order": NSNumber(value: 3)]
    let value = migrateHouseholdRecord(.eventMeal, row)!
    let record = HouseholdRecordCodec.encode(value, zoneID: zoneID)
    let back = HouseholdRecordCodec.decode(record, as: .eventMeal)

    #expect(back.recordName == "EM1")
    #expect(back.scalars["role"] == .string("main"))
    #expect(back.scalars["recipeName"] == .string("Roast"))
    #expect(back.scalars["servings"] == .double(8))
    #expect(back.scalars["scaleMultiplier"] == .double(1.5))
    #expect(back.scalars["aiGenerated"] == .bool(true))
    #expect(back.scalars["approved"] == .bool(false))
    #expect(back.scalars["sortOrder"] == .int(3))
    // event = cascade parent (.deleteSelf), recipe + assignedGuest = SET-NULL refs.
    #expect(back.refs["event"] == "EV1")
    #expect(back.refs["recipe"] == "R1")
    #expect(back.refs["assignedGuest"] == "G1")
    #expect(record["event"] is CKRecord.Reference)
    #expect((record["event"] as? CKRecord.Reference)?.action == .deleteSelf)
    #expect((record["recipe"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none)
}
