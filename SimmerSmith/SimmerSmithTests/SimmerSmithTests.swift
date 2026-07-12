import Foundation
import Testing
import SimmerSmithKit

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
#endif
