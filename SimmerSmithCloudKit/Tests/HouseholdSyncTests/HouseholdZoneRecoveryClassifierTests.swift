#if canImport(CloudKit)
import CloudKit
import Foundation
import HouseholdRecords
import Testing
@testable import HouseholdSync

private let classifierSourceZoneName = HouseholdZoneRecoveryManifest.reservedSourceZoneName
private let classifierTargetZoneName = "household-production"
private let classifierSourceOwner = CKCurrentUserDefaultName

private func classifierScope(zoneName: String, householdID: String) -> MirrorScope {
    MirrorScope(
        accountRecordName: "account-a",
        zoneOwnerName: classifierSourceOwner,
        zoneName: zoneName,
        householdID: householdID,
        role: .owner,
        databaseScope: .private)
}

private func classifier() -> HouseholdZoneRecoveryClassifier {
    HouseholdZoneRecoveryClassifier(
        sourceScope: classifierScope(zoneName: classifierSourceZoneName, householdID: "recovery-source"),
        targetScope: classifierScope(zoneName: classifierTargetZoneName, householdID: "household-a"))
}

private func record(
    _ type: String,
    _ name: String,
    zoneName: String = classifierSourceZoneName,
    ownerName: String = classifierSourceOwner
) -> CKRecord {
    CKRecord(
        recordType: type,
        recordID: CKRecord.ID(
            recordName: name,
            zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)))
}

private func reference(_ name: String, action: CKRecord.ReferenceAction = .none) -> CKRecord.Reference {
    CKRecord.Reference(
        recordID: CKRecord.ID(
            recordName: name,
            zoneID: CKRecordZone.ID(zoneName: classifierSourceZoneName, ownerName: classifierSourceOwner)),
        action: action)
}

private func edgeKey(_ edge: HouseholdZoneRecoveryDependencyEdge) -> String {
    "\(edge.dependent.source.recordType):\(edge.dependent.source.recordName)->\(edge.dependency.source.recordType):\(edge.dependency.source.recordName):\(edge.requirement.rawValue)"
}

private func selectionClosureNames(
    for group: HouseholdZoneRecoverySelectableGroup,
    in result: HouseholdZoneRecoveryClassification
) -> Set<String> {
    let includedGroupIDs = Set(group.dependencyGroupIDs).union([group.id])
    return Set(result.selectableGroups
        .filter { includedGroupIDs.contains($0.id) }
        .flatMap(\.members)
        .map(\.source.recordName))
}

@Test("supported production types are the canonical household manifest plus dedicated production codecs")
func classifierUsesCanonicalProductionTypes() {
    let manifestTypes = Set(HouseholdRecordType.allCases.map(\.recordTypeName))
    let dedicatedTypes: Set<String> = [
        "HouseholdProfile", "GroceryItem", "EventGroceryItem", "RecipeImage", "RecipeMemoryImage",
    ]

    #expect(HouseholdZoneRecoveryClassifier.supportedProductionRecordTypes == manifestTypes.union(dedicatedTypes))

    let snapshots = HouseholdZoneRecoveryClassifier.supportedProductionRecordTypes
        .sorted()
        .map { record($0, "user-\($0)") }
    let result = classifier().classify(snapshots)

    let classifiedTypes = Set(
        result.eligibleIdentities.map(\.source.recordType)
            + result.blockedEntries.map(\.identity.source.recordType))
    #expect(classifiedTypes == manifestTypes.union(dedicatedTypes))
    #expect(result.exclusions.isEmpty)
    #expect(result.provenanceCandidates.count == result.eligibleRecords.count)
    #expect(result.accountedRecordCount == snapshots.count)
}

@Test("share Core Data coexistence foreign unknown system and fixture records have distinct exclusions")
func classifierSeparatesEveryExclusionReason() {
    let share = record("cloudkit.share", CKRecordNameZoneWideShare)
    let coreData = record("CD_PrivateProfileSetting", "core-data", zoneName: "com.apple.coredata.cloudkit.zone")
    let coexistence = record("CoexistenceNote", "coexistence", zoneName: "coexistence-spike")
    let foreign = record("Recipe", "foreign", zoneName: "household-other")
    let unknown = record("NeverDeployedType", "unknown")
    let system = record("MigrationReceipt", "migrated:recipes")
    let fixture = record("HouseholdProfile", "phase0-test")

    let result = classifier().classify([foreign, fixture, system, unknown, coexistence, share, coreData])
    let reasons = Dictionary(uniqueKeysWithValues: result.exclusions.map { ($0.reason, $0.count) })

    #expect(reasons == [
        HouseholdZoneRecoveryExclusionReason.share.rawValue: 1,
        HouseholdZoneRecoveryExclusionReason.coreData.rawValue: 1,
        HouseholdZoneRecoveryExclusionReason.coexistence.rawValue: 1,
        HouseholdZoneRecoveryExclusionReason.foreignZone.rawValue: 1,
        HouseholdZoneRecoveryExclusionReason.unknownType.rawValue: 1,
        HouseholdZoneRecoveryExclusionReason.systemType.rawValue: 1,
        HouseholdZoneRecoveryExclusionReason.fixture.rawValue: 1,
    ])
    #expect(result.eligibleRecords.isEmpty)
    #expect(result.accountedRecordCount == 7)
}

@Test("fixture catalog is exact and unknown supported provenance remains unresolved")
func classifierKeepsUnknownProvenanceUnresolved() {
    let expectedFixtures: Set<String> = [
        "phase0-test", "phase2-test", "phase2b-test", "phase3-test", "phase4-test",
        "phase4b-test", "phase5b-test", "phase5c-test", "phase5d-test", "phase7-test",
        "phase4-repair", "phase2c-shared", "spc-recipe-test", "spc-weeks-test",
        "spc-events-test", "spc-pantry-test", "phase2c-share-handoff",
    ]
    #expect(HouseholdZoneRecoveryClassifier.knownDeterministicFixtureRecordNames == expectedFixtures)

    let fixtures = expectedFixtures.map { record("HouseholdProfile", $0) }
    let fixtureResult = classifier().classify(fixtures)
    #expect(fixtureResult.exclusions == [
        HouseholdZoneRecoveryExclusion(
            reason: HouseholdZoneRecoveryExclusionReason.fixture.rawValue,
            count: expectedFixtures.count),
    ])
    #expect(fixtureResult.accountedRecordCount == expectedFixtures.count)

    let unknownProvenance = record("Recipe", "rc-1234abcd")
    unknownProvenance["createdAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
    let result = classifier().classify([unknownProvenance])

    #expect(result.eligibleIdentities.map(\.source.recordName) == ["rc-1234abcd"])
    let candidates: [HouseholdZoneRecoveryProvenanceCandidate] = result.provenanceCandidates
    #expect(candidates.map(\.identity.source.recordName) == ["rc-1234abcd"])
    #expect(result.exclusions.isEmpty)
}

@Test("production relationships emit required and optional dependency edges")
func classifierBuildsProductionDependencyEdges() {
    let profile = record("HouseholdProfile", "recovery-source")
    let setting = record("HouseholdSetting", "setting-theme")
    let recipe = record("Recipe", "recipe")
    let ingredient = record("RecipeIngredient", "recipe-ingredient")
    ingredient["recipe"] = reference("recipe", action: .deleteSelf)
    ingredient["baseIngredientID"] = "base" as CKRecordValue
    ingredient["ingredientVariationID"] = "variation" as CKRecordValue
    let step = record("RecipeStep", "recipe-step")
    step["recipe"] = reference("recipe", action: .deleteSelf)
    let image = record("RecipeImage", "rimg:recipe")
    image["recipe"] = reference("recipe", action: .deleteSelf)
    let memory = record("RecipeMemory", "memory")
    memory["recipe"] = reference("recipe", action: .deleteSelf)
    let memoryImage = record("RecipeMemoryImage", "rmemimg:memory")
    memoryImage["recipeMemory"] = reference("memory", action: .deleteSelf)

    let base = record("BaseIngredient", "base")
    let variation = record("IngredientVariation", "variation")
    variation["baseIngredient"] = reference("base", action: .deleteSelf)

    let week = record("Week", "week")
    let meal = record("WeekMeal", "meal")
    meal["week"] = reference("week", action: .deleteSelf)
    meal["recipe"] = reference("recipe")
    let side = record("WeekMealSide", "side")
    side["weekMeal"] = reference("meal", action: .deleteSelf)
    side["recipe"] = reference("recipe")
    let grocery = record("GroceryItem", "grocery")
    grocery["weekID"] = "week" as CKRecordValue
    grocery["baseIngredientID"] = "base" as CKRecordValue
    grocery["ingredientVariationID"] = "variation" as CKRecordValue

    let event = record("Event", "event")
    event["linkedWeekID"] = "week" as CKRecordValue
    let eventMeal = record("EventMeal", "event-meal")
    eventMeal["event"] = reference("event", action: .deleteSelf)
    eventMeal["recipe"] = reference("recipe")
    let eventIngredient = record("EventMealIngredient", "event-ingredient")
    eventIngredient["eventMeal"] = reference("event-meal", action: .deleteSelf)
    eventIngredient["baseIngredientID"] = "base" as CKRecordValue
    eventIngredient["ingredientVariationID"] = "variation" as CKRecordValue
    let eventGrocery = record("EventGroceryItem", "event_eg_0")
    eventGrocery["eventID"] = "event" as CKRecordValue
    eventGrocery["mergedIntoWeekID"] = "week" as CKRecordValue
    eventGrocery["mergedIntoGroceryItemID"] = "grocery" as CKRecordValue
    eventGrocery["baseIngredientID"] = "base" as CKRecordValue
    eventGrocery["ingredientVariationID"] = "variation" as CKRecordValue

    let result = classifier().classify([
        eventGrocery, meal, recipe, setting, memoryImage, base, eventIngredient, side, ingredient,
        event, week, profile, image, variation, eventMeal, grocery, memory, step,
    ])
    let edges = Set(result.dependencyEdges.map(edgeKey))

    let expected: Set<String> = [
        "HouseholdSetting:setting-theme->HouseholdProfile:recovery-source:required",
        "RecipeIngredient:recipe-ingredient->Recipe:recipe:required",
        "RecipeIngredient:recipe-ingredient->BaseIngredient:base:optional",
        "RecipeIngredient:recipe-ingredient->IngredientVariation:variation:optional",
        "RecipeStep:recipe-step->Recipe:recipe:required",
        "RecipeImage:rimg:recipe->Recipe:recipe:required",
        "RecipeMemory:memory->Recipe:recipe:required",
        "RecipeMemoryImage:rmemimg:memory->RecipeMemory:memory:required",
        "IngredientVariation:variation->BaseIngredient:base:required",
        "WeekMeal:meal->Week:week:required",
        "WeekMeal:meal->Recipe:recipe:optional",
        "WeekMealSide:side->WeekMeal:meal:required",
        "WeekMealSide:side->Recipe:recipe:optional",
        "GroceryItem:grocery->Week:week:required",
        "GroceryItem:grocery->BaseIngredient:base:optional",
        "GroceryItem:grocery->IngredientVariation:variation:optional",
        "Event:event->Week:week:optional",
        "EventMeal:event-meal->Event:event:required",
        "EventMeal:event-meal->Recipe:recipe:optional",
        "EventMealIngredient:event-ingredient->EventMeal:event-meal:required",
        "EventMealIngredient:event-ingredient->BaseIngredient:base:optional",
        "EventMealIngredient:event-ingredient->IngredientVariation:variation:optional",
        "EventGroceryItem:event_eg_0->Event:event:required",
        "EventGroceryItem:event_eg_0->Week:week:optional",
        "EventGroceryItem:event_eg_0->GroceryItem:grocery:optional",
        "EventGroceryItem:event_eg_0->BaseIngredient:base:optional",
        "EventGroceryItem:event_eg_0->IngredientVariation:variation:optional",
    ]

    #expect(edges == expected)
    #expect(result.blockedEntries.isEmpty)
    #expect(result.eligibleRecords.count == 18)
}

@Test("missing required parents block records and their transitive dependents while optional references do not")
func classifierBlocksMissingRequiredDependenciesTransitively() {
    let parentStep = record("RecipeStep", "parent-step")
    parentStep["recipe"] = reference("missing-recipe", action: .deleteSelf)
    let childStep = record("RecipeStep", "child-step")
    childStep["recipe"] = reference("missing-recipe", action: .deleteSelf)
    childStep["parentStep"] = reference("parent-step", action: .deleteSelf)

    let week = record("Week", "week")
    let meal = record("WeekMeal", "meal")
    meal["week"] = reference("week", action: .deleteSelf)
    meal["recipe"] = reference("optional-missing-recipe")
    let grocery = record("GroceryItem", "grocery")
    grocery["weekID"] = "week" as CKRecordValue
    grocery["baseIngredientID"] = "optional-missing-base" as CKRecordValue

    let result = classifier().classify([childStep, grocery, meal, week, parentStep])
    let blocked = Dictionary(uniqueKeysWithValues: result.blockedEntries.map {
        ($0.identity.source.recordName, $0.missingDependencies.map(\.source.recordName))
    })

    #expect(blocked == [
        "child-step": ["missing-recipe"],
        "parent-step": ["missing-recipe"],
    ])
    #expect(Set(result.eligibleIdentities.map(\.source.recordName)) == ["week", "meal", "grocery"])
    #expect(result.dependencyEdges.contains { edgeKey($0) == "WeekMeal:meal->Recipe:optional-missing-recipe:optional" } == false)
    #expect(result.dependencyEdges.contains { edgeKey($0) == "GroceryItem:grocery->BaseIngredient:optional-missing-base:optional" } == false)
    #expect(result.accountedRecordCount == 5)
}

@Test("invalid required relationships and their transitive dependents are blocked")
func classifierBlocksInvalidRequiredRelationships() {
    let recipe = record("Recipe", "recipe")
    let setting = record("HouseholdSetting", "setting")
    let malformedParent = record("RecipeStep", "malformed-parent")
    let child = record("RecipeStep", "child")
    child["recipe"] = reference("recipe", action: .deleteSelf)
    child["parentStep"] = reference("malformed-parent", action: .deleteSelf)
    let foreignImage = record("RecipeImage", "rimg:recipe")
    foreignImage["recipe"] = CKRecord.Reference(
        recordID: CKRecord.ID(
            recordName: "recipe",
            zoneID: CKRecordZone.ID(zoneName: "household-other", ownerName: classifierSourceOwner)),
        action: .deleteSelf)
    let grocery = record("GroceryItem", "grocery")
    let eventGrocery = record("EventGroceryItem", "unattributed")

    let result = classifier().classify([
        eventGrocery, child, setting, recipe, foreignImage, grocery, malformedParent,
    ])
    let reasons = Dictionary(uniqueKeysWithValues: result.blockedEntries.map {
        ($0.identity.source.recordName, $0.reason)
    })

    #expect(reasons == [
        "setting": HouseholdZoneRecoveryBlockedEntry.missingDependencyReason,
        "malformed-parent": HouseholdZoneRecoveryClassifier.invalidRequiredDependencyReason,
        "child": HouseholdZoneRecoveryClassifier.invalidRequiredDependencyReason,
        "rimg:recipe": HouseholdZoneRecoveryClassifier.invalidRequiredDependencyReason,
        "grocery": HouseholdZoneRecoveryClassifier.invalidRequiredDependencyReason,
        "unattributed": HouseholdZoneRecoveryClassifier.invalidRequiredDependencyReason,
    ])
    #expect(result.eligibleIdentities.map(\.source.recordName) == ["recipe"])
    #expect(result.accountedRecordCount == 7)
}

@Test("duplicate roots block their dependents with identity tracking and deterministic accounting")
func classifierBlocksDuplicateRootsTransitively() {
    let firstRoot = record("Recipe", "duplicate-root")
    let secondRoot = record("Recipe", "duplicate-root")
    let child = record("RecipeIngredient", "child")
    child["recipe"] = reference("duplicate-root", action: .deleteSelf)

    let forward = classifier().classify([firstRoot, child, secondRoot])
    let reverse = classifier().classify([secondRoot, child, firstRoot])
    let reasons = Dictionary(uniqueKeysWithValues: forward.blockedEntries.map {
        ($0.identity.source.recordName, $0.reason)
    })

    #expect(reasons == [
        "duplicate-root": HouseholdZoneRecoveryClassifier.duplicateRecordReason,
        "child": HouseholdZoneRecoveryClassifier.invalidRequiredDependencyReason,
    ])
    #expect(forward.exclusions.isEmpty)
    #expect(forward.eligibleRecords.isEmpty)
    #expect(forward.blockedRecordCount == 3)
    #expect(forward.accountedRecordCount == forward.inputRecordCount)
    #expect(forward.blockedEntries == reverse.blockedEntries)
    #expect(forward.dependencyEdges == reverse.dependencyEdges)
    #expect(forward.selectableGroups == reverse.selectableGroups)
    #expect(forward.blockedRecordCount == reverse.blockedRecordCount)
}

@Test("duplicate dependent snapshots are blocked once by identity while every snapshot is accounted")
func classifierBlocksDuplicateDependents() {
    let recipe = record("Recipe", "recipe")
    let first = record("RecipeIngredient", "duplicate-child")
    first["recipe"] = reference("recipe", action: .deleteSelf)
    let second = record("RecipeIngredient", "duplicate-child")
    second["recipe"] = reference("recipe", action: .deleteSelf)

    let result = classifier().classify([first, recipe, second])

    #expect(result.blockedEntries.map(\.identity.source.recordName) == ["duplicate-child"])
    #expect(result.blockedEntries.map(\.reason) == [
        HouseholdZoneRecoveryClassifier.duplicateRecordReason,
    ])
    #expect(result.eligibleIdentities.map(\.source.recordName) == ["recipe"])
    #expect(result.blockedRecordCount == 2)
    #expect(result.accountedRecordCount == result.inputRecordCount)
}

@Test("selecting aggregate roots closes over required children and referenced dependencies")
func classifierBuildsAggregateSelectionClosure() throws {
    let recipe = record("Recipe", "recipe")
    let ingredient = record("RecipeIngredient", "ingredient")
    ingredient["recipe"] = reference("recipe", action: .deleteSelf)
    let step = record("RecipeStep", "step")
    step["recipe"] = reference("recipe", action: .deleteSelf)
    let image = record("RecipeImage", "rimg:recipe")
    image["recipe"] = reference("recipe", action: .deleteSelf)
    let memory = record("RecipeMemory", "memory")
    memory["recipe"] = reference("recipe", action: .deleteSelf)
    let memoryImage = record("RecipeMemoryImage", "rmemimg:memory")
    memoryImage["recipeMemory"] = reference("memory", action: .deleteSelf)

    let week = record("Week", "week")
    let meal = record("WeekMeal", "meal")
    meal["week"] = reference("week", action: .deleteSelf)
    meal["recipe"] = reference("recipe")
    let side = record("WeekMealSide", "side")
    side["weekMeal"] = reference("meal", action: .deleteSelf)
    let grocery = record("GroceryItem", "grocery")
    grocery["weekID"] = "week" as CKRecordValue
    let batch = record("WeekChangeBatch", "batch")
    batch["week"] = reference("week", action: .deleteSelf)
    let change = record("WeekChangeEvent", "change")
    change["batch"] = reference("batch", action: .deleteSelf)

    let result = classifier().classify([
        change, meal, ingredient, week, recipe, memoryImage, side, image, batch, grocery, memory, step,
    ])
    let recipeGroup = try #require(result.selectableGroups.first {
        $0.members.map(\.source.recordName) == ["recipe"]
    })
    let weekGroup = try #require(result.selectableGroups.first {
        $0.members.map(\.source.recordName) == ["week"]
    })

    #expect(selectionClosureNames(for: recipeGroup, in: result) == [
        "recipe", "ingredient", "step", "rimg:recipe", "memory", "rmemimg:memory",
    ])
    #expect(selectionClosureNames(for: weekGroup, in: result) == [
        "week", "meal", "side", "grocery", "batch", "change",
        "recipe", "ingredient", "step", "rimg:recipe", "memory", "rmemimg:memory",
    ])
}

@Test("cycles form deterministic strongly connected selectable groups with dependency closure")
func classifierBuildsDeterministicStronglyConnectedGroups() {
    let recipe = record("Recipe", "recipe")
    let first = record("RecipeStep", "step-a")
    first["recipe"] = reference("recipe", action: .deleteSelf)
    first["parentStep"] = reference("step-b", action: .deleteSelf)
    let second = record("RecipeStep", "step-b")
    second["recipe"] = reference("recipe", action: .deleteSelf)
    second["parentStep"] = reference("step-a", action: .deleteSelf)

    let forward = classifier().classify([recipe, first, second])
    let reverse = classifier().classify([second, first, recipe])

    #expect(forward.selectableGroups == reverse.selectableGroups)
    let cycle = forward.selectableGroups.first {
        Set($0.members.map(\.source.recordName)) == ["step-a", "step-b"]
    }
    #expect(cycle != nil)
    #expect(cycle?.members.map(\.source.recordName) == ["step-a", "step-b"])
    #expect(cycle?.dependencyGroupIDs.count == 1)
    let recipeGroup = forward.selectableGroups.first { $0.members.map(\.source.recordName) == ["recipe"] }
    #expect(cycle?.dependencyGroupIDs == recipeGroup.map { [$0.id] })
}
#endif
