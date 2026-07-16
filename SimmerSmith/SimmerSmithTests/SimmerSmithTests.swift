import Foundation
import Testing
import SimmerSmithKit

#if canImport(CloudKit)
import CloudKit
import HouseholdRecords
#endif

@testable import SimmerSmith

struct SimmerSmithTests {
    @Test
    func feedbackRequestDefaultsToIOSSource() {
        let request = FeedbackEntryRequest(targetType: "meal", targetName: "Pasta", sentiment: 1)
        #expect(request.source == "ios")
        #expect(request.active == true)
    }

    @Test
    func assistantRespondRequestDefaultsToGeneralIntent() {
        let request = AssistantRespondRequestBody(text: "Help me plan next week")
        #expect(request.intent == "general")
        #expect(request.attachedRecipeId == nil)
        #expect(request.attachedRecipeDraft == nil)
    }

    @Test
    func mealUpdateRequestDefaultsToAnUnapprovedBaseScale() {
        let request = MealUpdateRequest(
            dayName: "Monday",
            mealDate: Date(timeIntervalSince1970: 0),
            slot: "dinner",
            recipeName: "Pasta"
        )

        #expect(request.scaleMultiplier == 1.0)
        #expect(request.notes == "")
        #expect(request.approved == false)
    }

    @Test
    func weekCreateRequestDefaultsNotesToEmptyString() {
        let request = WeekCreateRequest(weekStart: Date(timeIntervalSince1970: 0))
        #expect(request.notes == "")
    }

    @Test
    func recipeIngredientIDFallsBackToNormalizedNameThenIngredientName() {
        let normalizedFallback = RecipeIngredient(
            ingredientName: "Bread",
            normalizedName: "bread"
        )
        let rawNameFallback = RecipeIngredient(
            ingredientName: "Bread"
        )

        #expect(normalizedFallback.id == "bread")
        #expect(rawNameFallback.id == "Bread")
    }
}

@MainActor
struct VoicePlanningBallastFlagTests {
    @Test("Ballast voice parsing remains disabled by default")
    func ballastParseDefaultsOff() {
        #expect(VoicePlanningCoordinator.useBallastParse == false)
    }
}

@Suite
struct RecipeEditorIngredientPolicyTests {
    @Test
    func autocompleteSelectionStoresCompleteBaseIdentityAndClearsVariation() {
        let ingredient = RecipeIngredient(
            ingredientId: "ingredient-1",
            ingredientName: "pep",
            normalizedName: "old pepper",
            baseIngredientId: "old-base",
            baseIngredientName: "Old Pepper",
            ingredientVariationId: "old-variation",
            ingredientVariationName: "Old Brand",
            resolutionStatus: "locked",
            quantity: 2,
            unit: "cup"
        )
        let base = BaseIngredient(
            baseIngredientId: "base-pepper",
            name: "Bell Pepper",
            normalizedName: "bell pepper",
            updatedAt: .distantPast
        )

        let selected = RecipeEditorIngredientPolicy.selecting(base, for: ingredient)

        #expect(selected.ingredientId == "ingredient-1")
        #expect(selected.ingredientName == "Bell Pepper")
        #expect(selected.normalizedName == "bell pepper")
        #expect(selected.baseIngredientId == "base-pepper")
        #expect(selected.baseIngredientName == "Bell Pepper")
        #expect(selected.ingredientVariationId == nil)
        #expect(selected.ingredientVariationName == nil)
        #expect(selected.resolutionStatus == "resolved")
        #expect(selected.quantity == 2)
        #expect(selected.unit == "cup")
    }

    @Test
    func manualNameChangeInvalidatesCanonicalMapping() {
        let selected = RecipeIngredient(
            ingredientId: "ingredient-1",
            ingredientName: "Bell Pepper",
            normalizedName: "bell pepper",
            baseIngredientId: "base-pepper",
            baseIngredientName: "Bell Pepper",
            ingredientVariationId: "variation-pepper",
            ingredientVariationName: "Market Pepper",
            resolutionStatus: "locked"
        )

        let renamed = RecipeEditorIngredientPolicy.updatingName(selected, to: "Red Pepper")

        #expect(renamed.ingredientId == "ingredient-1")
        #expect(renamed.ingredientName == "Red Pepper")
        #expect(renamed.normalizedName == nil)
        #expect(renamed.baseIngredientId == nil)
        #expect(renamed.baseIngredientName == nil)
        #expect(renamed.ingredientVariationId == nil)
        #expect(renamed.ingredientVariationName == nil)
        #expect(renamed.resolutionStatus == "unresolved")
    }

    @Test
    func draftSeedsOnlyMissingIngredientIDsAndReplacementPreservesIdentity() {
        let draft = RecipeDraft(
            name: "Peppers",
            ingredients: [
                RecipeIngredient(ingredientName: "Red Pepper"),
                RecipeIngredient(ingredientId: "existing-id", ingredientName: "Salt"),
                RecipeIngredient(ingredientName: "Oil"),
            ]
        )
        var generatedIDs = ["generated-1", "generated-2"]

        let seeded = RecipeEditorIngredientPolicy.seedingMissingIngredientIDs(in: draft) {
            generatedIDs.removeFirst()
        }
        let replacement = RecipeIngredient(
            ingredientId: "replacement-id",
            ingredientName: "Sweet Pepper"
        )
        let replaced = RecipeEditorIngredientPolicy.preservingIdentity(
            of: seeded.ingredients[0],
            whenReplacingWith: replacement
        )

        #expect(seeded.ingredients.map(\.ingredientId) == ["generated-1", "existing-id", "generated-2"])
        #expect(seeded.ingredients.map(\.ingredientName) == ["Red Pepper", "Salt", "Oil"])
        #expect(replaced.ingredientId == "generated-1")
        #expect(replaced.ingredientName == "Sweet Pepper")
    }
}

#if canImport(CloudKit)
/// Bead simmersmith-990.4.2 — AppState.memoryDTOs maps repository RecipeMemoryEntry
/// values (oldest→newest) onto the RecipeMemory DTO contract the memories UI expects
/// (newest-first, `ckmem:<id>` photo sentinel).
@MainActor
struct RecipeMemoryMappingTests {
    @Test
    func reversesRepositoryOrderToNewestFirst() {
        let entries = [
            RecipeMemoryEntry(id: "a", body: "first", createdAt: Date(timeIntervalSince1970: 100), hasPhoto: false),
            RecipeMemoryEntry(id: "b", body: "second", createdAt: Date(timeIntervalSince1970: 200), hasPhoto: false),
            RecipeMemoryEntry(id: "c", body: "third", createdAt: Date(timeIntervalSince1970: 300), hasPhoto: false),
        ]

        let mapped = AppState.memoryDTOs(from: entries)

        #expect(mapped.map(\.id) == ["c", "b", "a"])
    }

    @Test
    func photoUrlSentinelPresentExactlyWhenEntryHasPhoto() {
        let entries = [
            RecipeMemoryEntry(id: "no-photo", body: "plain", createdAt: Date(timeIntervalSince1970: 0), hasPhoto: false),
            RecipeMemoryEntry(id: "with-photo", body: "snap", createdAt: Date(timeIntervalSince1970: 1), hasPhoto: true),
        ]

        let mapped = AppState.memoryDTOs(from: entries)

        #expect(mapped.first { $0.id == "with-photo" }?.photoUrl == "ckmem:with-photo")
        #expect(mapped.first { $0.id == "no-photo" }?.photoUrl == nil)
    }

    @Test
    func passesThroughIdBodyAndCreatedAt() {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let entries = [
            RecipeMemoryEntry(id: "m1", body: "Grandma's trick", createdAt: createdAt, hasPhoto: false)
        ]

        let mapped = AppState.memoryDTOs(from: entries)

        #expect(mapped.count == 1)
        #expect(mapped.first?.id == "m1")
        #expect(mapped.first?.body == "Grandma's trick")
        #expect(mapped.first?.createdAt == createdAt)
    }
}

/// Bead simmersmith-990.4.3 — recipeMemoryMigrationRow pins the row shape the
/// Fly→CloudKit memories migration writes (mirrors RecipeRepository.addMemory:
/// legacy Fly UUID verbatim as recordName, body/createdAt scalars, recipe ref).
struct RecipeMemoryMigrationRowTests {
    @Test
    func rowCarriesManifestShape() {
        let fixed = Date(timeIntervalSince1970: 1_750_000_000)
        let memory = RecipeMemory(id: "m1", body: "note", createdAt: fixed, photoUrl: nil)

        let row = recipeMemoryMigrationRow(recipeID: "r1", memory: memory)

        #expect(row.type == .recipeMemory)
        #expect(row.recordName == "m1")
        #expect(row.scalars["body"] == .string("note"))
        #expect(row.scalars["createdAt"] == .date(fixed))
        #expect(row.refs == ["recipe": "r1"])
    }

    @Test
    func rowRoundTripsThroughHouseholdRecordCodec() {
        let fixed = Date(timeIntervalSince1970: 1_750_000_001)
        let memory = RecipeMemory(id: "mig-rt-m2", body: "roundtrip body", createdAt: fixed, photoUrl: nil)
        let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: "o")

        let row = recipeMemoryMigrationRow(recipeID: "mig-rt-r2", memory: memory)
        let record = HouseholdRecordCodec.encode(row, zoneID: zoneID)
        let decoded = HouseholdRecordCodec.decode(record, as: .recipeMemory)

        #expect(decoded.recordName == "mig-rt-m2")
        #expect(decoded.scalars["body"] == .string("roundtrip body"))
        #expect(decoded.scalars["createdAt"] == .date(fixed))
        #expect(decoded.refs == ["recipe": "mig-rt-r2"])
    }

    @Test
    func photoUrlDoesNotLeakIntoRow() {
        let fixed = Date(timeIntervalSince1970: 1_750_000_002)
        let memory = RecipeMemory(
            id: "mig-photo-m3",
            body: "with photo",
            createdAt: fixed,
            photoUrl: "/api/recipes/mig-photo-r3/memories/mig-photo-m3/photo?v=1"
        )

        let row = recipeMemoryMigrationRow(recipeID: "mig-photo-r3", memory: memory)

        // The photo travels as a RecipeMemoryImage record, never a scalar.
        #expect(Set(row.scalars.keys) == ["body", "createdAt"])
        #expect(row.refs == ["recipe": "mig-photo-r3"])
    }
}

/// Milestone 990.4 product-flow test — the memories feature end-to-end on the
/// REAL assembled stack: AppState (the methods the UI calls) → RecipeRepository
/// → a real HouseholdSession (real local store, real sync engine, real CKAsset
/// staging on disk). No iCloud account is needed: `engine.save` writes the
/// local store synchronously before enqueueing, which is exactly the
/// offline-first behavior the shipping app relies on. Only the network push is
/// absent — everything the UI observes is exercised for real.
@MainActor
struct RecipeMemoriesProductFlowTests {
    @Test
    func memoriesAddListPhotoDeleteOnTheRealStack() async throws {
        let container = try makeSimmerSmithModelContainer(inMemory: true)
        let suite = "ProductFlow-\(UUID().uuidString)"
        let settings = ConnectionSettingsStore(
            defaults: UserDefaults(suiteName: suite)!,
            keychain: KeychainStore(service: suite)
        )
        let appState = AppState(modelContainer: container, settingsStore: settings)
        let session = HouseholdSession(householdID: "prodflow-\(UUID().uuidString)")
        appState.recipeRepository = RecipeRepository(session: session)

        let recipeID = "prodflow-recipe-1"
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array("prodflow-taco-night".utf8))

        // ADD with a photo — what MemoryComposeSheet.save() calls.
        let created = try await appState.createRecipeMemory(
            recipeID: recipeID,
            body: "Taco night — kids approved",
            imageData: jpeg,
            mimeType: "image/jpeg"
        )
        #expect(created.photoUrl == "ckmem:\(created.id)")

        // LIST — what RecipeMemoriesSection.load() calls.
        let listed = try await appState.refreshRecipeMemories(recipeID: recipeID)
        #expect(listed.map(\.id) == [created.id])
        #expect(listed.first?.body == "Taco night — kids approved")

        // PHOTO — what MemoryPhotoView.load() calls; round-trips the staged CKAsset.
        let bytes = try await appState.fetchRecipeMemoryPhotoBytes(
            recipeID: recipeID, memoryID: created.id
        )
        #expect(bytes == jpeg)

        // DELETE — what the section's confirm dialog calls; cascades the photo record.
        try await appState.deleteRecipeMemory(recipeID: recipeID, memoryID: created.id)
        let afterDelete = try await appState.refreshRecipeMemories(recipeID: recipeID)
        #expect(afterDelete.isEmpty)

        // The cascade also removed the photo: a re-fetch must now throw not-found.
        await #expect(throws: (any Error).self) {
            _ = try await appState.fetchRecipeMemoryPhotoBytes(
                recipeID: recipeID, memoryID: created.id
            )
        }
    }
}
#endif
