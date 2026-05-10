import Foundation
import SimmerSmithKit

extension AppState {
    func refreshRecipes() async {
        guard hasSavedConnection else { return }
        syncPhase = .loading
        do {
            recipeMetadata = try await apiClient.fetchRecipeMetadata()
            recipes = try await apiClient.fetchRecipes(includeArchived: true)
            if let recipeMetadata {
                try? cacheStore.saveRecipeMetadata(recipeMetadata)
            }
            try? cacheStore.saveRecipes(recipes)
            syncPhase = .synced(.now)
            // Build 85: migrate any per-device picks taken on
            // builds 83/84 (UserDefaults) onto the server now that
            // we have authoritative `recipes` to scope by.
            Task { [weak self] in await self?.migrateLocalIconOverridesIfNeeded() }
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    /// One-time migration: takes everything in
    /// `RecipeIconOverrides.shared.overrides` and PATCHes the
    /// corresponding server recipe so household members see the
    /// same glyph. Each successful upload clears the local entry.
    /// Recipes whose server iconKey is already set are skipped (the
    /// server is canonical). Recipes that no longer exist locally
    /// are dropped from UserDefaults.
    private func migrateLocalIconOverridesIfNeeded() async {
        let overrides = RecipeIconOverrides.shared.overrides
        guard !overrides.isEmpty else { return }
        for (recipeId, iconKey) in overrides {
            guard let summary = recipes.first(where: { $0.recipeId == recipeId }) else {
                // Recipe gone — drop the stale entry.
                RecipeIconOverrides.shared.set(.auto, for: recipeId)
                continue
            }
            if !summary.iconKey.isEmpty {
                // Server already has a value — local is stale, drop it.
                RecipeIconOverrides.shared.set(.auto, for: recipeId)
                continue
            }
            var draft = summary.editingDraft()
            draft.iconKey = iconKey
            do {
                _ = try await apiClient.saveRecipe(draft)
                RecipeIconOverrides.shared.set(.auto, for: recipeId)
            } catch {
                // Leave local alone; we'll retry on the next launch.
            }
        }
        // Refresh once after the loop so the in-memory recipes carry
        // the new iconKeys without requiring another full reload.
        if let refreshed = try? await apiClient.fetchRecipes(includeArchived: true) {
            recipes = refreshed
            try? cacheStore.saveRecipes(refreshed)
        }
    }

    func fetchRecipe(recipeID: String) async throws -> RecipeSummary {
        let recipe = try await apiClient.fetchRecipe(recipeID: recipeID)
        upsertRecipe(recipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
        return recipe
    }

    /// Fetch the raw bytes of an AI-generated recipe header image. The
    /// image route requires bearer auth, so the iOS view layer can't
    /// just hand the URL to `AsyncImage` — this wrapper goes through
    /// the authenticated session and returns the body for `UIImage`.
    func fetchRecipeImageBytes(recipeID: String) async throws -> Data {
        try await apiClient.fetchRecipeImageBytes(recipeID: recipeID)
    }

    /// Re-roll the AI-generated header image for one recipe. The
    /// returned recipe replaces the local copy so observers fetch
    /// the new cache-busted `imageURL` automatically.
    func regenerateRecipeImage(recipeID: String) async throws {
        let updated = try await apiClient.regenerateRecipeImage(recipeID: recipeID)
        upsertRecipe(updated)
        try? cacheStore.saveRecipes(recipes)
    }

    /// Replace the AI image with a user-uploaded photo.
    func uploadRecipeImage(recipeID: String, imageData: Data, mimeType: String = "image/jpeg") async throws {
        let updated = try await apiClient.uploadRecipeImage(
            recipeID: recipeID,
            imageData: imageData,
            mimeType: mimeType
        )
        upsertRecipe(updated)
        try? cacheStore.saveRecipes(recipes)
    }

    /// Drop the recipe's image entirely (back to the gradient).
    func deleteRecipeImage(recipeID: String) async throws {
        let updated = try await apiClient.deleteRecipeImage(recipeID: recipeID)
        upsertRecipe(updated)
        try? cacheStore.saveRecipes(recipes)
    }

    /// Run the server-side backfill that generates header images for
    /// every recipe missing one. Refreshes the local recipe cache on
    /// success so the new `imageURL` fields show up in lists/detail
    /// without a manual sync.
    func backfillRecipeImages() async throws -> SimmerSmithAPIClient.RecipeImageBackfillResult {
        let result = try await apiClient.backfillRecipeImages()
        if result.generated > 0 {
            await refreshRecipes()
        }
        return result
    }

    // MARK: - Recipe memories log (M15)

    /// Refresh + cache the memory log for one recipe. Returns the
    /// fresh list so callers can use it directly. Caches by recipeID
    /// so navigating away/back doesn't refetch immediately.
    func refreshRecipeMemories(recipeID: String) async throws -> [RecipeMemory] {
        let memories = try await apiClient.fetchRecipeMemories(recipeID: recipeID)
        recipeMemories[recipeID] = memories
        return memories
    }

    func recipeMemoriesCached(recipeID: String) -> [RecipeMemory]? {
        recipeMemories[recipeID]
    }

    func createRecipeMemory(
        recipeID: String,
        body: String,
        imageData: Data? = nil,
        mimeType: String? = nil
    ) async throws -> RecipeMemory {
        let memory = try await apiClient.createRecipeMemory(
            recipeID: recipeID,
            body: body,
            imageData: imageData,
            mimeType: mimeType
        )
        var current = recipeMemories[recipeID] ?? []
        current.insert(memory, at: 0)
        recipeMemories[recipeID] = current
        return memory
    }

    func fetchRecipeMemoryPhotoBytes(
        recipeID: String,
        memoryID: String
    ) async throws -> Data {
        try await apiClient.fetchRecipeMemoryPhotoBytes(
            recipeID: recipeID,
            memoryID: memoryID
        )
    }

    func deleteRecipeMemory(recipeID: String, memoryID: String) async throws {
        try await apiClient.deleteRecipeMemory(recipeID: recipeID, memoryID: memoryID)
        recipeMemories[recipeID] = (recipeMemories[recipeID] ?? []).filter { $0.id != memoryID }
    }

    func refreshRecipeMetadata() async {
        guard hasSavedConnection else { return }
        do {
            let metadata = try await apiClient.fetchRecipeMetadata()
            recipeMetadata = metadata
            try? cacheStore.saveRecipeMetadata(metadata)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func createManagedListItem(kind: String, name: String) async throws -> ManagedListItem {
        let item = try await apiClient.createManagedListItem(kind: kind, name: name)
        await refreshRecipeMetadata()
        return item
    }

    func estimateRecipeNutrition(_ draft: RecipeDraft) async throws -> NutritionSummary {
        try await apiClient.estimateRecipeNutrition(draft)
    }

    func searchNutritionItems(query: String = "", limit: Int = 20) async throws -> [NutritionItem] {
        try await apiClient.searchNutritionItems(query: query, limit: limit)
    }

    func importRecipeDraft(fromURL url: String) async throws -> RecipeDraft {
        try await apiClient.importRecipe(fromURL: url)
    }

    func importRecipeDraft(fromHTML html: String, sourceURL: String, sourceLabel: String = "") async throws -> RecipeDraft {
        try await apiClient.importRecipe(fromHTML: html, sourceURL: sourceURL, sourceLabel: sourceLabel)
    }

    func importRecipeDraft(
        fromText text: String,
        title: String = "",
        source: String = "scan_import",
        sourceLabel: String = "",
        sourceURL: String = ""
    ) async throws -> RecipeDraft {
        try await apiClient.importRecipe(
            fromText: text,
            title: title,
            source: source,
            sourceLabel: sourceLabel,
            sourceURL: sourceURL
        )
    }

    func generateRecipeVariationDraft(recipeID: String, goal: String) async throws -> RecipeAIDraft {
        try await apiClient.generateRecipeVariationDraft(recipeID: recipeID, goal: goal)
    }

    /// Ask the backend for AI-generated pairing suggestions (M12 Phase 1).
    func suggestRecipePairings(recipeID: String) async throws -> [PairingOption] {
        let response = try await apiClient.suggestPairings(recipeID: recipeID)
        return response.suggestions
    }

    /// AI recipe web search (M12 Phase 4). Returns a draft for the user
    /// to review in the editor before saving — same flow URL/photo
    /// imports take.
    func searchRecipeOnWeb(query: String) async throws -> RecipeDraft {
        try await apiClient.searchRecipeOnWeb(query: query)
    }

    func generateRecipeSuggestionDraft(goal: String) async throws -> RecipeAIDraft {
        try await apiClient.generateRecipeSuggestionDraft(goal: goal)
    }

    func generateRecipeCompanionDrafts(recipeID: String) async throws -> RecipeAIOptions {
        try await apiClient.generateRecipeCompanionDrafts(recipeID: recipeID)
    }

    func saveRecipe(_ draft: RecipeDraft) async throws -> RecipeSummary {
        // Build 54 perf: only the actual save is on the blocking
        // path. Metadata refresh (cuisines / templates / tags) ran
        // serially after every save and dominated the perceived
        // latency on TestFlight 53. Fire it from a follow-up Task
        // so callers (review sheet → link-side / link-meal chains)
        // unblock as soon as the recipe row exists.
        let savedRecipe = try await apiClient.saveRecipe(draft)
        upsertRecipe(savedRecipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
        Task { [weak self] in
            guard let self else { return }
            if let metadata = try? await self.apiClient.fetchRecipeMetadata() {
                self.recipeMetadata = metadata
                try? self.cacheStore.saveRecipeMetadata(metadata)
            }
        }
        return savedRecipe
    }

    /// M29 build 53 — refine an in-flight draft via AI. Returns the
    /// new draft; caller replaces the visible draft. Never persists.
    func refineRecipeDraft(
        currentDraft: RecipeDraft,
        prompt: String,
        contextHint: String = ""
    ) async throws -> RecipeDraft {
        try await apiClient.refineRecipeDraft(
            draft: currentDraft,
            prompt: prompt,
            contextHint: contextHint
        )
    }

    /// How to apply an AI substitution: mutate the base recipe in place or
    /// fork a new variation that keeps the original intact.
    enum SubstitutionMode {
        case replace
        case saveAsVariation
    }

    /// Apply a picked AI substitution. `.replace` overwrites the original
    /// recipe; `.saveAsVariation` forks a new recipe that links back to
    /// the original via `baseRecipeId` (same mechanic the existing
    /// "Create Variation" menu uses) — that way the user can keep the
    /// original next to the substituted version in the library.
    @discardableResult
    func applySubstitution(
        recipe: RecipeSummary,
        ingredientID: String,
        suggestion: SubstitutionSuggestion,
        mode: SubstitutionMode = .replace
    ) async throws -> RecipeSummary {
        var draft: RecipeDraft
        switch mode {
        case .replace:
            draft = recipe.editingDraft()
        case .saveAsVariation:
            draft = recipe.variationDraft()
            // More informative title than the default "Recipe Variation" —
            // the user knows at a glance which ingredient was swapped.
            draft.name = "\(recipe.name) w/ \(suggestion.name)"
        }
        guard let index = draft.ingredients.firstIndex(where: { $0.id == ingredientID }) else {
            throw NSError(
                domain: "SimmerSmith.SubstitutionError",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Ingredient was not found in the recipe."]
            )
        }
        let existing = draft.ingredients[index]
        let newQuantity = Double(suggestion.quantity.trimmingCharacters(in: .whitespaces)) ?? existing.quantity
        let newUnit = suggestion.unit.isEmpty ? existing.unit : suggestion.unit
        draft.ingredients[index] = RecipeIngredient(
            // For a new variation we must strip the inherited ingredientId
            // so the server mints a fresh row — otherwise the replaced
            // ingredient shares an id with the original recipe's row.
            ingredientId: mode == .saveAsVariation ? nil : existing.ingredientId,
            ingredientName: suggestion.name,
            normalizedName: nil,
            baseIngredientId: nil,
            baseIngredientName: nil,
            ingredientVariationId: nil,
            ingredientVariationName: nil,
            resolutionStatus: "unresolved",
            quantity: newQuantity,
            unit: newUnit,
            prep: existing.prep,
            category: existing.category,
            notes: existing.notes
        )
        return try await saveRecipe(draft)
    }

    func archiveRecipe(_ recipe: RecipeSummary) async throws {
        let archivedRecipe = try await apiClient.archiveRecipe(recipeID: recipe.recipeId)
        upsertRecipe(archivedRecipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
    }

    func restoreRecipe(_ recipe: RecipeSummary) async throws {
        let restoredRecipe = try await apiClient.restoreRecipe(recipeID: recipe.recipeId)
        upsertRecipe(restoredRecipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
    }

    func deleteRecipe(_ recipe: RecipeSummary) async throws {
        // Build 54 hardening: pull a fresh server list right after the
        // 204 lands. Belt-and-suspenders against the dogfood case
        // where a delete *appeared* to succeed but the recipe came
        // back on next refresh — the server list is now the source
        // of truth, not the optimistic local mutation.
        try await apiClient.deleteRecipe(recipeID: recipe.recipeId)
        recipes.removeAll { $0.recipeId == recipe.recipeId }
        do {
            recipes = try await apiClient.fetchRecipes(includeArchived: false)
        } catch {
            // Server fetch is best-effort; the local removal is
            // already applied so the UI is consistent. Log the
            // error in lastErrorMessage so dogfooders can see it.
            lastErrorMessage = "Recipe deleted, but couldn't refresh list: \(error.localizedDescription)"
        }
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
    }

    private func upsertRecipe(_ recipe: RecipeSummary) {
        if let index = recipes.firstIndex(where: { $0.recipeId == recipe.recipeId }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        recipes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
