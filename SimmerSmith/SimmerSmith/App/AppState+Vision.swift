import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import AIProviderKit
#endif

extension AppState {
    /// Send an image to the vision-AI seam and decode an `IngredientIdentification`
    /// response. The caller (typically `IngredientScannerView`) is responsible for
    /// converting the source (camera capture or PhotosPicker) to JPEG `Data` before
    /// calling.
    ///
    /// SP-D vision port: on-device multimodal LLM call via `VisionPrompt`. Requires
    /// a key for a vision-capable provider (OpenAI/Anthropic/open-models).
    func identifyIngredient(imageData: Data) async throws -> IngredientIdentification {
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let request = AIRequest(
            feature: .vision,
            systemPrompt: VisionPrompt.identifyIngredientSystemPrompt,
            prompt: VisionPrompt.identifyIngredientPrompt(),
            wantsStructuredJSON: true
        )
        let response = try await aiSvc.generateVision(request, imageData: imageData, mimeType: "image/jpeg")
        let wire = try VisionAIParser.parseIdentification(response.text)
        return IngredientIdentification(
            name: wire.name,
            confidence: wire.confidence,
            commonNames: wire.commonNames,
            cuisineUses: wire.cuisineUses.map { CuisineUse(country: $0.country, dish: $0.dish) },
            recipeMatchTerms: wire.recipeMatchTerms,
            notes: wire.notes
        )
        #else
        return try await apiClient.identifyIngredient(imageData: imageData, mimeType: "image/jpeg")
        #endif
    }

    /// Check whether a mid-cook photo looks on track for a given recipe step.
    /// `stepNumber` is the index into `recipe.steps` (sorted by `sortOrder`, mirrors
    /// the server route's `recipe.steps[payload.step_number]` lookup).
    ///
    /// SP-D vision port: on-device multimodal LLM call via `VisionPrompt`.
    func cookCheck(
        recipeID: String,
        stepNumber: Int,
        imageData: Data
    ) async throws -> CookCheckResult {
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let recipe = recipes.first(where: { $0.recipeId == recipeID })
        let sortedSteps = recipe?.steps.sorted { $0.sortOrder < $1.sortOrder } ?? []
        let stepText = (stepNumber >= 0 && stepNumber < sortedSteps.count) ? sortedSteps[stepNumber].instruction : ""
        let request = AIRequest(
            feature: .vision,
            systemPrompt: VisionPrompt.cookCheckSystemPrompt,
            prompt: VisionPrompt.cookCheckPrompt(
                recipeTitle: recipe?.name ?? "",
                stepText: stepText,
                recipeContext: recipe?.cuisine ?? ""
            ),
            wantsStructuredJSON: true
        )
        let response = try await aiSvc.generateVision(request, imageData: imageData, mimeType: "image/jpeg")
        let wire = try VisionAIParser.parseCookCheck(response.text)
        return CookCheckResult(
            verdict: wire.verdict,
            tip: wire.tip,
            suggestedMinutesRemaining: wire.suggestedMinutesRemaining
        )
        #else
        return try await apiClient.cookCheck(
            recipeID: recipeID,
            stepNumber: stepNumber,
            imageData: imageData,
            mimeType: "image/jpeg"
        )
        #endif
    }

}
