import Foundation
import Testing
import CloudKit
@testable import HouseholdRecords

// SP-A Phase 2b — pins the IRREVERSIBLE manifest classification + the codec round-trip.
// CloudKit is available headlessly on macOS (CKRecord/CKReference need no account), so the
// encode/decode round-trip runs in `swift test`.

// MARK: Reference-graph classification (the load-bearing, irreversible part)

@Test func recipeBaseRecipeIsSetNull_notCascade() {
    // Swapping this with RecipeStep.parentStep CASCADE would delete variants when a base
    // recipe is removed. Lock it.
    let baseRecipe = HouseholdRecordType.recipe.refs.first { $0.name == "baseRecipe" }
    #expect(baseRecipe?.kind == .setNullInZone)
    #expect(HouseholdRecordType.recipe.refs.contains { $0.name == "recipe" } == false) // no cascade parent
}

@Test func recipeStepHasTwoCascadeParents() {
    let refs = HouseholdRecordType.recipeStep.refs
    #expect(refs.first { $0.name == "recipe" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "parentStep" }?.kind == .cascadeParent) // self-ref CASCADE
}

@Test func ingredientVariationBaseIsCascade_mergedIsCrossDBString() {
    let refs = HouseholdRecordType.ingredientVariation.refs
    #expect(refs.first { $0.name == "baseIngredient" }?.kind == .cascadeParent) // catalog.py:137 CASCADE
    #expect(refs.first { $0.name == "mergedIntoID" }?.kind == .crossDBString)   // never a CKReference
}

@Test func baseIngredientMergedIsCrossDBString() {
    #expect(HouseholdRecordType.baseIngredient.refs.first { $0.name == "mergedIntoID" }?.kind == .crossDBString)
}

@Test func eventAttendeeEventCascades_guestSetNull() {
    // spec §6.3: EventAttendee→Guest is SET-NULL (overrides the Postgres guest_id CASCADE).
    let refs = HouseholdRecordType.eventAttendee.refs
    #expect(refs.first { $0.name == "event" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "guest" }?.kind == .setNullInZone)
}

@Test func eventMealRefsAreInZoneSetNull() {
    let refs = HouseholdRecordType.eventMeal.refs
    #expect(refs.first { $0.name == "event" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "recipe" }?.kind == .setNullInZone)
    #expect(refs.first { $0.name == "assignedGuest" }?.kind == .setNullInZone)
}

@Test func recipeMemoryCascadesFromRecipe() {
    // SP-D 990.4.1 — recipe is the CASCADE parent (mirrors the Fly ondelete=CASCADE); the
    // engine's local .deleteSelf sweep additionally cascades onward to RecipeMemoryImage.
    let refs = HouseholdRecordType.recipeMemory.refs
    #expect(refs.first { $0.name == "recipe" }?.kind == .cascadeParent)
    #expect(refs.first { $0.name == "recipe" }?.target == "Recipe")
    #expect(refs.count == 1)
}

@Test func recipeTemplateAndCatalogRefsAreCrossDBStrings() {
    #expect(HouseholdRecordType.recipe.refs.first { $0.name == "recipeTemplateID" }?.kind == .crossDBString)
    let ri = HouseholdRecordType.recipeIngredient.refs
    #expect(ri.first { $0.name == "baseIngredientID" }?.kind == .crossDBString)
    #expect(ri.first { $0.name == "ingredientVariationID" }?.kind == .crossDBString)
}

@Test func eventLinkedWeekIsCrossDBStringUntilPhase4() {
    #expect(HouseholdRecordType.event.refs.first { $0.name == "linkedWeekID" }?.kind == .crossDBString)
}

// MARK: recordName policy

@Test func detKeyedTypesAreDeterministic() {
    #expect(HouseholdRecordType.householdSetting.namePolicy == .det)
    #expect(HouseholdRecordType.householdTermAlias.namePolicy == .det)
    #expect(HouseholdRecordType.eventAttendee.namePolicy == .det)
}

@Test func pkTypesPassThroughLegacyID() {
    for t in [HouseholdRecordType.recipe, .guest, .event, .eventMeal, .baseIngredient,
              .ingredientVariation, .recipeMemory] {
        #expect(t.namePolicy == .pk)
    }
}

@Test func weekTypesLandedFeedbackStillDeferred() {
    // Phase 4-remainder added Week/WeekMeal/WeekChangeBatch/WeekChangeEvent (16 types).
    // Task 4b added ManagedListItem (17 types total).
    // SP-C Task 2 added WeekMealSide (18 types total).
    // SP-C Task 1 added PantryItem (19 types total).
    // SP-D 990.4.1 added RecipeMemory (20 types total).
    // FeedbackEntry is the sole remaining deferred type (independent; no repair machinery).
    let names = HouseholdRecordType.allCases.map(\.recordTypeName)
    #expect(names.contains("Week") && names.contains("WeekMeal"))
    #expect(names.contains("WeekMealSide"))
    #expect(names.contains("WeekChangeBatch") && names.contains("WeekChangeEvent"))
    #expect(names.contains("ManagedListItem"))
    #expect(names.contains("PantryItem"))
    #expect(names.contains("RecipeMemory"))
    #expect(names.contains("FeedbackEntry") == false)
    #expect(names.count == 20)
}

// MARK: Field typing

@Test func boolFieldsAreClassifiedBool() {
    let recipeFields = Dictionary(uniqueKeysWithValues: HouseholdRecordType.recipe.fields.map { ($0.name, $0.type) })
    #expect(recipeFields["favorite"] == .bool)
    #expect(recipeFields["kidFriendly"] == .bool)
    #expect(recipeFields["servings"] == .double)
    #expect(recipeFields["prepMinutes"] == .int)
    #expect(recipeFields["createdAt"] == .date)
}

@Test func queryableSortableMatchSpecB() {
    let recipe = Dictionary(uniqueKeysWithValues: HouseholdRecordType.recipe.fields.map { ($0.name, $0) })
    #expect(recipe["cuisine"]?.queryable == true)
    #expect(recipe["createdAt"]?.sortable == true)
    #expect(HouseholdRecordType.baseIngredient.fields.first { $0.name == "normalizedName" }?.queryable == true)
    #expect(HouseholdRecordType.householdSetting.fields.first { $0.name == "key" }?.queryable == true)
}

@Test func recipeMemoryFieldsMatchSignedSchema() {
    // SP-D 990.4.1 signed schema: body:STRING, createdAt:TIMESTAMP SORTABLE. mimeType is
    // deliberately absent — it lives on RecipeMemoryImage (manifest-EXTERNAL), not here.
    let fields = Dictionary(uniqueKeysWithValues: HouseholdRecordType.recipeMemory.fields.map { ($0.name, $0) })
    #expect(fields["body"]?.type == .string)
    #expect(fields["body"]?.queryable == false)
    #expect(fields["createdAt"]?.type == .date)
    #expect(fields["createdAt"]?.sortable == true)
    #expect(fields.count == 2)
}

// MARK: Codec round-trip (headless CloudKit)

private let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

@Test func recipeRoundTripPreservesBoolAndDate() {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let value = HouseholdRecordValue(
        type: .recipe, recordName: "recipe-1",
        scalars: ["name": .string("Pad Thai"), "cuisine": .string("thai"),
                  "favorite": .bool(true), "kidFriendly": .bool(false),
                  "prepMinutes": .int(20), "servings": .double(4), "createdAt": .date(created)],
        refs: ["baseRecipe": "recipe-0", "recipeTemplateID": "tmpl-9"])
    let record = HouseholdRecordCodec.encode(value, zoneID: zoneID)

    // Bool encodes as INT64, ref kinds applied.
    #expect(record["favorite"] as? Int == 1)
    #expect(record["kidFriendly"] as? Int == 0)
    #expect((record["baseRecipe"] as? CKRecord.Reference)?.action == CKRecord.ReferenceAction.none)
    #expect(record["recipeTemplateID"] as? String == "tmpl-9")  // cross-DB string, not a reference

    let decoded = HouseholdRecordCodec.decode(record, as: .recipe)
    #expect(decoded == value)
}

@Test func recipeIngredientCascadeRefIsDeleteSelf() {
    let value = HouseholdRecordValue(
        type: .recipeIngredient, recordName: "ri-1",
        scalars: ["ingredientName": .string("garlic"), "normalizedName": .string("garlic")],
        refs: ["recipe": "recipe-1", "baseIngredientID": "base-7"])
    let record = HouseholdRecordCodec.encode(value, zoneID: zoneID)
    #expect((record["recipe"] as? CKRecord.Reference)?.action == .deleteSelf)
    #expect(record["baseIngredientID"] as? String == "base-7")
    #expect(HouseholdRecordCodec.decode(record, as: .recipeIngredient) == value)
}

@Test func ingredientVariationCascadeParentEncodesDeleteSelf() {
    let value = HouseholdRecordValue(
        type: .ingredientVariation, recordName: "iv-1",
        scalars: ["name": .string("Acme Garlic"), "normalizedName": .string("acme garlic"), "active": .bool(true)],
        refs: ["baseIngredient": "base-7", "mergedIntoID": "iv-merged"])
    let record = HouseholdRecordCodec.encode(value, zoneID: zoneID)
    #expect((record["baseIngredient"] as? CKRecord.Reference)?.action == .deleteSelf)
    #expect(record["mergedIntoID"] as? String == "iv-merged")  // String, never a CKReference
    #expect(HouseholdRecordCodec.decode(record, as: .ingredientVariation) == value)
}

@Test func recipeMemoryRoundTripPreservesBodyAndCreatedAtWithCascadeRef() {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let value = HouseholdRecordValue(
        type: .recipeMemory, recordName: "mem-1",
        scalars: ["body": .string("First time making this — kids loved it!"), "createdAt": .date(created)],
        refs: ["recipe": "recipe-1"])
    let record = HouseholdRecordCodec.encode(value, zoneID: zoneID)

    #expect(record.recordType == "RecipeMemory")
    #expect((record["recipe"] as? CKRecord.Reference)?.action == .deleteSelf)
    #expect((record["recipe"] as? CKRecord.Reference)?.recordID.recordName == "recipe-1")
    #expect(HouseholdRecordCodec.decode(record, as: .recipeMemory) == value)
}

@Test func decode_dropsPresentWrongTypeFieldButKeepsSiblings() {
    // "name" is a .string field — store it as an Int CKRecordValue to simulate CloudKit
    // drift/corruption (a present field/key with the wrong type, never a normal write path).
    let record = CKRecord(recordType: HouseholdRecordType.recipe.recordTypeName,
                           recordID: CKRecord.ID(recordName: "recipe-bad", zoneID: zoneID))
    record["name"] = 42 as CKRecordValue
    record["cuisine"] = "thai" as CKRecordValue
    record["favorite"] = 1 as CKRecordValue

    let decoded = HouseholdRecordCodec.decode(record, as: .recipe)

    #expect(decoded.scalars["name"] == nil)                  // wrong-typed field dropped, not crashed
    #expect(decoded.scalars["cuisine"] == .string("thai"))   // correctly-typed sibling still decodes
    #expect(decoded.scalars["favorite"] == .bool(true))      // correctly-typed sibling still decodes
}

@Test func decode_dropsPresentWrongTypeCrossDBStringRef() {
    // "recipeTemplateID" is a .crossDBString ref (plain String key) — store it as an Int to
    // simulate drift/corruption.
    let record = CKRecord(recordType: HouseholdRecordType.recipe.recordTypeName,
                           recordID: CKRecord.ID(recordName: "recipe-bad-ref", zoneID: zoneID))
    record["recipeTemplateID"] = 7 as CKRecordValue
    record["baseRecipe"] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: "recipe-0", zoneID: zoneID), action: .none)

    let decoded = HouseholdRecordCodec.decode(record, as: .recipe)

    #expect(decoded.refs["recipeTemplateID"] == nil)   // wrong-typed ref dropped, not crashed
    #expect(decoded.refs["baseRecipe"] == "recipe-0")  // correctly-typed sibling ref still decodes
}

// MARK: CKDSL generation

@Test func ckdslEmitsBoolAsInt64AndCrossDBAsString() {
    let dsl = HouseholdRecordType.recipe.ckdsl()
    #expect(dsl.contains("RECORD TYPE Recipe ("))
    #expect(dsl.contains("favorite INT64"))         // Bool → INT64
    #expect(dsl.contains("cuisine STRING QUERYABLE"))
    #expect(dsl.contains("createdAt TIMESTAMP SORTABLE"))
    #expect(dsl.contains("baseRecipe REFERENCE"))   // in-zone ref
    #expect(dsl.contains("recipeTemplateID STRING")) // cross-DB string key
    #expect(dsl.contains("GRANT WRITE TO \"_creator\""))
}

@Test func recipeMemoryCkdslMatchesPhase0SchemaCkdb() {
    // Pins the generated block against what's hand-appended to phase0-schema.ckdb — a drift
    // here means the deployed-schema copy is stale relative to the manifest.
    let dsl = HouseholdRecordType.recipeMemory.ckdsl()
    #expect(dsl.contains("RECORD TYPE RecipeMemory ("))
    #expect(dsl.contains("body STRING"))
    #expect(dsl.contains("createdAt TIMESTAMP SORTABLE"))
    #expect(dsl.contains("recipe REFERENCE"))
    #expect(dsl.contains("GRANT WRITE TO \"_creator\""))
    #expect(dsl.contains("GRANT READ, CREATE TO \"_icloud\""))
}
