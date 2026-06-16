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
    for t in [HouseholdRecordType.recipe, .guest, .event, .eventMeal, .baseIngredient, .ingredientVariation] {
        #expect(t.namePolicy == .pk)
    }
}

@Test func deferredTypesAreAbsent() {
    // WeekChangeBatch/WeekChangeEvent/FeedbackEntry are deferred to Phase 4.
    let names = HouseholdRecordType.allCases.map(\.recordTypeName)
    #expect(names.contains("WeekChangeBatch") == false)
    #expect(names.contains("FeedbackEntry") == false)
    #expect(names.count == 12)
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
