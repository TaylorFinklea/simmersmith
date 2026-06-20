import Foundation
import Testing
import HouseholdRecords
@testable import SimmerSmithKit

// SP-C Task 1 — Headless unit tests for RecipeRecordMapper.
// RecipeSummary has no public memberwise init; instances are built via JSON round-trip
// using makeRecipe(_:) helpers below.

// MARK: - Test helpers

/// JSON decoder matching the app's decoding strategy for RecipeSummary.
/// RecipeSummary's `init(from:)` decodes Date fields as ISO 8601 strings via the
/// default JSONDecoder date strategy (.deferredToDate) — which in Swift means numeric
/// seconds since reference date (2001-01-01). Use `.millisecondsSince1970` as a
/// convenient proxy since the struct uses decodeIfPresent for optional dates and
/// `decode` only for `updatedAt`.
/// Actually the server emits ISO8601 strings and the app's AppClient uses
/// `.iso8601` decoding. Mirror that here.
private let recipeSummaryDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

/// Build a RecipeSummary from a minimal dictionary (all optional fields may be omitted).
/// `updatedAt` is required and defaults to epoch if not supplied.
private func makeRecipe(_ overrides: [String: Any] = [:]) -> RecipeSummary {
    var base: [String: Any] = [
        "recipeId": "R-test",
        "name": "Test Recipe",
        "mealType": "",
        "cuisine": "",
        "instructionsSummary": "",
        "favorite": false,
        "archived": false,
        "source": "manual",
        "sourceLabel": "",
        "sourceUrl": "",
        "notes": "",
        "memories": "",
        "kidFriendly": false,
        "iconKey": "",
        "tags": [String](),
        "isVariant": false,
        "overrideFields": [String](),
        "variantCount": 0,
        "sourceRecipeCount": 1,
        "updatedAt": "1970-01-01T00:00:00Z",
        "ingredients": [[String: Any]](),
        "steps": [[String: Any]](),
    ]
    for (k, v) in overrides { base[k] = v }
    let data = try! JSONSerialization.data(withJSONObject: base)
    return try! recipeSummaryDecoder.decode(RecipeSummary.self, from: data)
}

/// Build a RecipeIngredient payload dict (for embedding in makeRecipe).
private func ingDict(
    id: String? = nil,
    name: String,
    qty: Double? = nil,
    unit: String = ""
) -> [String: Any] {
    var d: [String: Any] = ["ingredientName": name, "unit": unit, "prep": "", "category": "", "notes": "", "resolutionStatus": "unresolved"]
    if let i = id  { d["ingredientId"] = i }
    if let q = qty { d["quantity"] = q }
    return d
}

/// Build a RecipeStep payload dict (for embedding in makeRecipe).
private func stepDict(id: String? = nil, order: Int, instruction: String, substeps: [[String: Any]] = []) -> [String: Any] {
    var d: [String: Any] = ["sortOrder": order, "instruction": instruction]
    if let i = id { d["stepId"] = i }
    if !substeps.isEmpty { d["substeps"] = substeps }
    return d
}

// MARK: - Round-trip test (Step 3)

@Test func recipeRoundTripsThroughRecords() {
    let r = makeRecipe([
        "recipeId": "R1",
        "recipeTemplateId": "TPL",
        "baseRecipeId": "R0",
        "name": "Tacos",
        "mealType": "dinner",
        "cuisine": "mexican",
        "servings": 4.0,
        "prepMinutes": 15,
        "cookMinutes": 20,
        "tags": ["quick", "veg"],
        "instructionsSummary": "stuff",
        "favorite": true,
        "archived": false,
        "source": "manual",
        "sourceLabel": "",
        "sourceUrl": "",
        "notes": "n",
        "memories": "m",
        "lastUsed": "2023-11-14T22:13:20Z",
        "kidFriendly": true,
        "difficultyScore": 2,
        "iconKey": "taco",
        "ingredients": [
            ingDict(id: "I1", name: "Tomato", qty: 2.0, unit: "cup"),
            ingDict(id: "I2", name: "Onion"),
        ],
        "steps": [
            stepDict(id: "S1", order: 0, instruction: "chop"),
            stepDict(id: "S2", order: 1, instruction: "cook"),
        ],
    ])

    let recs = RecipeRecordMapper.records(from: r)
    let back = RecipeRecordMapper.recipe(
        from: recs.recipe,
        ingredients: recs.ingredients,
        steps: recs.steps,
        hasImage: false
    )

    // Category-A scalars survive.
    #expect(back.recipeId == "R1")
    #expect(back.name == "Tacos")
    #expect(back.cuisine == "mexican")
    #expect(back.servings == 4)
    #expect(back.prepMinutes == 15)
    #expect(back.cookMinutes == 20)
    #expect(back.favorite == true)
    #expect(back.kidFriendly == true)
    #expect(back.difficultyScore == 2)
    #expect(back.iconKey == "taco")
    #expect(back.mealType == "dinner")
    #expect(back.instructionsSummary == "stuff")
    #expect(back.notes == "n")
    #expect(back.memories == "m")

    // Category-B tags round-trip.
    #expect(back.tags == ["quick", "veg"])

    // Category-C references survive.
    #expect(back.baseRecipeId == "R0")
    #expect(back.recipeTemplateId == "TPL")

    // Category-D children survive (order preserved by sortOrder).
    #expect(back.ingredients.map(\.ingredientName) == ["Tomato", "Onion"])
    #expect(back.steps.map(\.instruction) == ["chop", "cook"])

    // Category-F derived fields are NOT fabricated.
    #expect(back.nutritionSummary == nil)
    #expect(back.variantCount == 0)
    #expect(back.sourceRecipeCount == 0)
    #expect(back.daysSinceLastUsed == nil)
    #expect(back.familyLastUsed == nil)
    #expect(back.isVariant == false)
    #expect(back.overrideFields.isEmpty)
}

// MARK: - Edge cases (Step 7)

@Test func emptyTagsRoundTrip() {
    #expect(RecipeRecordMapper.encodeTags([]) == "[]")
    #expect(RecipeRecordMapper.decodeTags("[]") == [])
    #expect(RecipeRecordMapper.decodeTags("") == [])

    let r = makeRecipe(["recipeId": "R2", "name": "Empty Tags"])
    let recs = RecipeRecordMapper.records(from: r)
    let back = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: [], steps: [], hasImage: false)
    #expect(back.tags == [])
}

@Test func multiTagEncodeDecodeRoundTrips() {
    let tags = ["quick", "veg", "kid-friendly"]
    let encoded = RecipeRecordMapper.encodeTags(tags)
    // Must be a valid JSON array.
    #expect(encoded == "[\"quick\",\"veg\",\"kid-friendly\"]")
    #expect(RecipeRecordMapper.decodeTags(encoded) == tags)
}

@Test func recipeWithNoIngredientsOrSteps() {
    let r = makeRecipe(["recipeId": "R3", "name": "Minimal"])
    let recs = RecipeRecordMapper.records(from: r)
    #expect(recs.ingredients.isEmpty)
    #expect(recs.steps.isEmpty)

    let back = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: [], steps: [], hasImage: false)
    #expect(back.recipeId == "R3")
    #expect(back.name == "Minimal")
    #expect(back.ingredients.isEmpty)
    #expect(back.steps.isEmpty)
}

@Test func substepRoundTripsParentStepRef() {
    let r = makeRecipe([
        "recipeId": "R4",
        "name": "Substep Recipe",
        "steps": [
            stepDict(id: "S1", order: 0, instruction: "Main step", substeps: [
                stepDict(id: "SS1", order: 0, instruction: "Sub step A"),
            ]),
        ],
    ])

    let recs = RecipeRecordMapper.records(from: r)

    // Two step records: one top-level, one substep.
    #expect(recs.steps.count == 2)

    // The substep record must carry a parentStep ref pointing at the parent step's recordName.
    let substepRecord = recs.steps.first { $0.refs["parentStep"] != nil }
    #expect(substepRecord != nil)
    #expect(substepRecord?.refs["parentStep"] == "S1")
    #expect(substepRecord?.recordName == "SS1")

    // Round-trip: substep nests back under its parent.
    let back = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: [], steps: recs.steps, hasImage: false)
    #expect(back.steps.count == 1)
    #expect(back.steps[0].instruction == "Main step")
    #expect(back.steps[0].substeps.count == 1)
    #expect(back.steps[0].substeps[0].instruction == "Sub step A")
}

@Test func minimalRecipeOnlyRequiresIdAndName() {
    let r = makeRecipe(["recipeId": "R5", "name": "Bare Minimum"])
    let recs = RecipeRecordMapper.records(from: r)
    let back = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: [], steps: [], hasImage: false)
    #expect(back.recipeId == "R5")
    #expect(back.name == "Bare Minimum")
    #expect(back.tags == [])
    #expect(back.baseRecipeId == nil)
    #expect(back.recipeTemplateId == nil)
    #expect(back.nutritionSummary == nil)
    #expect(back.imageUrl == nil)
}

@Test func hasImageSetsImageUrl() {
    let r = makeRecipe(["recipeId": "R6", "name": "With Image"])
    let recs = RecipeRecordMapper.records(from: r)
    let withImage = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: [], steps: [], hasImage: true)
    let withoutImage = RecipeRecordMapper.recipe(from: recs.recipe, ingredients: [], steps: [], hasImage: false)
    #expect(withImage.imageUrl != nil)
    #expect(withoutImage.imageUrl == nil)
}

@Test func ingredientFallbackRecordNameWhenNoId() {
    let r = makeRecipe([
        "recipeId": "R7",
        "name": "No IDs",
        "ingredients": [ingDict(name: "Salt")],  // no ingredientId
    ])
    let recs = RecipeRecordMapper.records(from: r)
    #expect(recs.ingredients.count == 1)
    // recordName must be deterministic (not crash, not empty).
    #expect(!recs.ingredients[0].recordName.isEmpty)
    // The ingredient ref points back to the recipe.
    #expect(recs.ingredients[0].refs["recipe"] == "R7")
}
