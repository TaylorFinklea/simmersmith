import Foundation
import Testing
import SimmerSmithKit

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
