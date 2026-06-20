import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
#endif

extension AppState {
    // MARK: - SP-C Task 5: CloudKit lifecycle + mirroring

    #if canImport(CloudKit)
    /// Construct the CloudKit household session + repositories once the household
    /// ID is known (from the Fly household snapshot). Idempotent — no-op if a
    /// session already exists. Called from `refreshAll()` after `refreshHousehold()`.
    ///
    /// Re-entrancy: two concurrent `refreshAll()` callers would both pass the
    /// `householdSession == nil` guard and start duplicate setups (two migrations,
    /// two competing sync engines). Guard with a task-dedup: assign the setup
    /// `Task` synchronously BEFORE the first `await` so a second caller arriving
    /// while setup is in-flight awaits the same task instead of starting another.
    func ensureHouseholdSession() async {
        // Fast path — already set up.
        if householdSession != nil {
            // Ensure the launch phase is .ready even if called again after setup.
            householdLaunchPhase = .ready
            return
        }

        // Second concurrent caller: setup in-flight — await it instead of duplicating.
        if let existing = householdSessionSetupTask {
            await existing.value
            return
        }

        // SP-C identity slice (spec §1.2): the household id no longer comes from Fly
        // (`currentHousehold?.householdId`) — it is DISCOVERED from CloudKit, or minted
        // if the user has no household zone yet. Resolution is async (it lists the
        // private DB's zones), so it happens inside the dedup task below rather than as
        // a pre-task guard. The discover-before-create ordering is load-bearing
        // (spec §7): minting a new zone when `household-<existingId>` already exists
        // would orphan the migrated recipes.

        // Assign the task SYNCHRONOUSLY (no await between here and the assignment)
        // so any concurrent caller on MainActor that runs next sees it.
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }

            // 1. Resolve the household id: discover first, mint only if none exists.
            guard let householdID = await self.resolveHouseholdID() else {
                // Discovery failed. The specific phase (.iCloudUnavailable vs .resolving)
                // was already set inside resolveHouseholdID() before returning nil. Leave
                // the session unset so a later retry can call ensureHouseholdSession()
                // again; clear the dedup task so the retry isn't short-circuited.
                self.householdSessionSetupTask = nil
                return
            }

            let session = HouseholdSession(householdID: householdID)
            await session.start()

            // SP-C Task 6: one-time first-launch recipe migration Fly→CloudKit.
            // Receipt-gated (idempotent) — safe to call every launch. Runs after
            // session.start() (zone provisioned + first fetch done) and before
            // recipeRepo.reload() so a new install hydrates CloudKit before the
            // first read. The migration is a no-op once the "recipes" receipt is
            // present in the local store.
            await migrateRecipesIfNeeded(session: session, apiClient: apiClient)

            let recipeRepo = RecipeRepository(session: session)
            let metadataRepo = MetadataRepository(session: session)

            householdSession = session
            recipeRepository = recipeRepo
            metadataRepository = metadataRepo

            // Initial kick — the repos auto-reload on session.storeRevision, but need a
            // first read after construction.
            recipeRepo.startObserving()
            metadataRepo.startObserving()
            recipeRepo.reload()
            metadataRepo.reloadMetadata()

            // Mirror the repo's projections onto AppState's @Observable stored vars so the
            // existing views (which bind to `recipes` / `recipeMetadata`) update without change.
            observeRecipeRepository()
            observeMetadataRepository()
            mirrorRecipesFromRepository()
            mirrorMetadataFromRepository()

            // SP-C identity slice (spec §1.3): signal RootView that the household is
            // resolved and the app is ready to show MainTabView.
            self.householdLaunchPhase = .ready
        }
        householdSessionSetupTask = task
        await task.value
    }

    /// SP-C identity slice (spec §1.2): resolve the CloudKit household id with NO Fly
    /// call. Discover first (zone listing); mint a fresh household only when none exists.
    ///
    /// Returns `nil` when resolution can't complete (discovery threw — e.g. iCloud
    /// unavailable / transient CloudKit error — OR minting threw). The caller leaves the
    /// session unset so a later refresh retries; it must NOT fall through to minting on a
    /// discovery error, which would orphan an existing `household-<id>` zone (spec §7).
    private func resolveHouseholdID() async -> String? {
        let provisioner = HouseholdZoneProvisioner()

        // 1. DISCOVER before create (spec §7 landmine). A throw here means we could not
        //    determine whether a household zone exists — so we must NOT mint (that path
        //    only runs on a definitive "zero zones" → nil household id).
        let result: HouseholdZoneProvisioner.DiscoveryResult
        do {
            result = try await provisioner.discoverHouseholdResult()
        } catch {
            // Check whether this is an iCloud-not-signed-in error vs. a transient
            // network hiccup. CKError.notAuthenticated / accountTemporarilyUnavailable
            // map to .iCloudUnavailable (user must open Settings); other errors are
            // transient — stay in .resolving so the user can retry by foregrounding.
            if isICloudAuthError(error) {
                householdLaunchPhase = .iCloudUnavailable
            }
            // If already .iCloudUnavailable, keep it; if it was .resolving, leave it
            // so the RootView loading spinner remains and a foreground retry can fire.
            lastErrorMessage = "Couldn't reach CloudKit to find your household. Will retry."
            return nil
        }

        // Multiple household zones (shouldn't happen for an owner). The winner
        // (most-populated) is used; log the rest for human reconciliation.
        if let firstIgnored = result.ignoredHouseholdIDs.first {
            lastErrorMessage = "Multiple CloudKit households found; using one and ignoring "
                + "\(result.ignoredHouseholdIDs.count) other(s) (e.g. household-\(firstIgnored))."
        }

        if let discovered = result.householdID, !discovered.isEmpty {
            return discovered
        }

        // 2. No household zone exists → MINT a new one: fresh UUID, ensure the zone, and
        //    write a default HouseholdProfile so the zone is non-empty (and future
        //    discovery's HouseholdProfile signal finds it).
        let newID = UUID().uuidString
        do {
            try await provisioner.ensureHouseholdZone(householdID: newID)
            _ = try await provisioner.ensureHouseholdProfile(householdID: newID, name: "My Household")
            return newID
        } catch {
            if isICloudAuthError(error) {
                householdLaunchPhase = .iCloudUnavailable
            }
            lastErrorMessage = "Couldn't create your CloudKit household. Will retry."
            return nil
        }
    }

    /// Returns true when the error indicates the iCloud account is not signed in or
    /// is temporarily unavailable — as opposed to a transient network hiccup. Used by
    /// `resolveHouseholdID()` to set `householdLaunchPhase = .iCloudUnavailable` so
    /// `RootView` shows the "Sign in to iCloud in Settings" prompt.
    private func isICloudAuthError(_ error: Error) -> Bool {
        // CKError is available because this function lives inside #if canImport(CloudKit).
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Tear down the CloudKit session + repositories and delete the durable engine
    /// state so a different household signed in on this device cannot inherit the
    /// prior sync token. Called from sign-out (`clearHouseholdContext`).
    func teardownHouseholdSession() {
        householdSession?.clearState()
        householdSession = nil
        recipeRepository = nil
        metadataRepository = nil
        // Clear the dedup task so a subsequent sign-in can start a fresh setup.
        householdSessionSetupTask = nil
        // Reset the launch phase so RootView shows the loading state on next launch.
        householdLaunchPhase = .resolving
    }

    /// Re-arm the recipe-repo observation and mirror its `recipes` onto AppState.
    private func observeRecipeRepository() {
        guard let repo = recipeRepository else { return }
        withObservationTracking {
            _ = repo.recipes
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorRecipesFromRepository()
                self?.observeRecipeRepository()
            }
        }
    }

    private func observeMetadataRepository() {
        guard let repo = metadataRepository else { return }
        withObservationTracking {
            _ = repo.metadata
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorMetadataFromRepository()
                self?.observeMetadataRepository()
            }
        }
    }

    private func mirrorRecipesFromRepository() {
        guard let repo = recipeRepository else { return }
        recipes = repo.recipes
        try? cacheStore.saveRecipes(recipes)
    }

    private func mirrorMetadataFromRepository() {
        guard let repo = metadataRepository, let metadata = repo.metadata else { return }
        recipeMetadata = metadata
        try? cacheStore.saveRecipeMetadata(metadata)
    }
    #endif

    func refreshRecipes() async {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            // CloudKit data plane: the store is already synced in the background by
            // HouseholdSession; reload is a local read off the store.
            syncPhase = .loading
            repo.reload()
            metadataRepository?.reloadMetadata()
            mirrorRecipesFromRepository()
            mirrorMetadataFromRepository()
            syncPhase = .synced(.now)
            return
        }
        #endif
        // Pre-sign-in / no CloudKit session: keep the existing Fly path so cached
        // content still hydrates (the session is constructed in refreshAll()).
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
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    func fetchRecipe(recipeID: String) async throws -> RecipeSummary {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            // Read from the local store (source of truth offline-first). reload() is a
            // no-op if nothing changed; the recipe is already in the in-memory set.
            repo.reload()
            mirrorRecipesFromRepository()
            if let summary = repo.recipes.first(where: { $0.recipeId == recipeID }) {
                return summary
            }
            throw NSError(
                domain: "SimmerSmith.RecipeRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Recipe not found in the local store."]
            )
        }
        #endif
        let recipe = try await apiClient.fetchRecipe(recipeID: recipeID)
        upsertRecipe(recipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
        return recipe
    }

    /// Fetch the raw bytes of the recipe's header image.
    func fetchRecipeImageBytes(recipeID: String) async throws -> Data {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            guard let data = await repo.imageBytes(recipeID) else {
                throw NSError(
                    domain: "SimmerSmith.RecipeRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Recipe image not available yet."]
                )
            }
            return data
        }
        #endif
        return try await apiClient.fetchRecipeImageBytes(recipeID: recipeID)
    }

    /// Re-roll the AI-generated header image for one recipe.
    func regenerateRecipeImage(recipeID: String) async throws {
        // AI TRACK: rewire to AIProviderKit before SP-D — image gen needs a model,
        // not the data plane. Stays on Fly during the transition.
        let updated = try await apiClient.regenerateRecipeImage(recipeID: recipeID)
        upsertRecipe(updated)
        try? cacheStore.saveRecipes(recipes)
    }

    /// Replace the recipe image with a user-uploaded photo.
    func uploadRecipeImage(recipeID: String, imageData: Data, mimeType: String = "image/jpeg") async throws {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            repo.setImage(recipeID, imageData, mime: mimeType)
            mirrorRecipesFromRepository()
            return
        }
        #endif
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
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            repo.removeImage(recipeID)
            mirrorRecipesFromRepository()
            return
        }
        #endif
        let updated = try await apiClient.deleteRecipeImage(recipeID: recipeID)
        upsertRecipe(updated)
        try? cacheStore.saveRecipes(recipes)
    }

    /// Run the server-side backfill that generates header images for
    /// every recipe missing one. Refreshes the local recipe cache on
    /// success so the new `imageURL` fields show up in lists/detail
    /// without a manual sync.
    func backfillRecipeImages() async throws -> SimmerSmithAPIClient.RecipeImageBackfillResult {
        // AI TRACK: rewire to AIProviderKit before SP-D — AI header-image generation.
        // Stays on Fly during the transition; an `async throws` failure surfaces via the
        // caller's UI error handling rather than crashing.
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
        #if canImport(CloudKit)
        if let repo = metadataRepository {
            repo.reloadMetadata()
            mirrorMetadataFromRepository()
            return
        }
        #endif
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
        #if canImport(CloudKit)
        if let repo = metadataRepository {
            let item = try repo.createManagedListItem(kind: kind, name: name)
            mirrorMetadataFromRepository()
            return item
        }
        #endif
        let item = try await apiClient.createManagedListItem(kind: kind, name: name)
        await refreshRecipeMetadata()
        return item
    }

    func estimateRecipeNutrition(_ draft: RecipeDraft) async throws -> NutritionSummary {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.estimateRecipeNutrition(draft)
    }

    func searchNutritionItems(query: String = "", limit: Int = 20) async throws -> [NutritionItem] {
        // AI TRACK: rewire to AIProviderKit before SP-D — nutrition catalog search backs
        // the AI nutrition flow. Stays on Fly during the transition.
        try await apiClient.searchNutritionItems(query: query, limit: limit)
    }

    func importRecipeDraft(fromURL url: String) async throws -> RecipeDraft {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.importRecipe(fromURL: url)
    }

    func importRecipeDraft(fromHTML html: String, sourceURL: String, sourceLabel: String = "") async throws -> RecipeDraft {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.importRecipe(fromHTML: html, sourceURL: sourceURL, sourceLabel: sourceLabel)
    }

    func importRecipeDraft(
        fromText text: String,
        title: String = "",
        source: String = "scan_import",
        sourceLabel: String = "",
        sourceURL: String = ""
    ) async throws -> RecipeDraft {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.importRecipe(
            fromText: text,
            title: title,
            source: source,
            sourceLabel: sourceLabel,
            sourceURL: sourceURL
        )
    }

    func generateRecipeVariationDraft(recipeID: String, goal: String) async throws -> RecipeAIDraft {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.generateRecipeVariationDraft(recipeID: recipeID, goal: goal)
    }

    /// Ask the backend for AI-generated pairing suggestions (M12 Phase 1).
    func suggestRecipePairings(recipeID: String) async throws -> [PairingOption] {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        let response = try await apiClient.suggestPairings(recipeID: recipeID)
        return response.suggestions
    }

    /// AI recipe web search (M12 Phase 4). Returns a draft for the user
    /// to review in the editor before saving — same flow URL/photo
    /// imports take.
    func searchRecipeOnWeb(query: String) async throws -> RecipeDraft {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.searchRecipeOnWeb(query: query)
    }

    func generateRecipeSuggestionDraft(goal: String) async throws -> RecipeAIDraft {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.generateRecipeSuggestionDraft(goal: goal)
    }

    func generateRecipeCompanionDrafts(recipeID: String) async throws -> RecipeAIOptions {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.generateRecipeCompanionDrafts(recipeID: recipeID)
    }

    /// AI ingredient-substitution suggestions for one recipe ingredient.
    /// Façade so `SubstitutionSheetView` no longer reaches into `apiClient` directly.
    func suggestIngredientSubstitutions(
        recipeID: String,
        ingredientID: String,
        hint: String = ""
    ) async throws -> IngredientSubstituteResponse {
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.suggestIngredientSubstitutions(
            recipeID: recipeID,
            ingredientID: ingredientID,
            hint: hint
        )
    }

    func saveRecipe(_ draft: RecipeDraft) async throws -> RecipeSummary {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            // Local write to the store (engine syncs in the background); reload + mirror.
            let saved = try repo.save(draft)
            mirrorRecipesFromRepository()
            syncPhase = .synced(.now)
            return saved
        }
        #endif
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
        // AI TRACK: rewire to AIProviderKit before SP-D — requires a model. Stays on Fly.
        try await apiClient.refineRecipeDraft(
            draft: currentDraft,
            prompt: prompt,
            contextHint: contextHint
        )
    }

    // MARK: - SP-C Task 5: ingredient catalog façade (§7 leak closure)

    /// Façade for the recipe editor's ingredient autocomplete. The view used to call
    /// `appState.apiClient.fetchBaseIngredients(...)` directly (§7 leak); it now calls
    /// this so AppState owns the resolution path.
    ///
    /// NOTE (signature divergence from the brief): the brief named the return type
    /// `[BaseIngredientSummary]`, but no such type exists — the editor binds the result
    /// of `fetchBaseIngredients` to `[BaseIngredient]`, so the façade returns that.
    ///
    /// NOTE (resolution path): `PublicCatalogReader` only exposes EXACT-`normalizedName`
    /// resolve + batch prefetch (§8.2) — it has no substring/prefix search, which is what
    /// the editor's live autocomplete needs. CloudKit-backed ingredient search is the
    /// Ingredient slice's concern (spec §10), not recipe slice 1. During the transition
    /// (Fly is up and holds the auth token) this delegates to Fly; SP-D / the Ingredient
    /// slice rewires it to `session.catalog`. Closing the view→apiClient leak here means
    /// that rewire happens in ONE place.
    func fetchBaseIngredients(query: String, limit: Int) async throws -> [BaseIngredient] {
        // CATALOG TRACK: rewire to session.catalog (PublicCatalogReader) when the
        // Ingredient slice lands; substring search is out of scope for recipe slice 1.
        try await apiClient.fetchBaseIngredients(query: query, limit: limit)
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
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            repo.archive(recipe.recipeId)
            mirrorRecipesFromRepository()
            syncPhase = .synced(.now)
            return
        }
        #endif
        let archivedRecipe = try await apiClient.archiveRecipe(recipeID: recipe.recipeId)
        upsertRecipe(archivedRecipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
    }

    func restoreRecipe(_ recipe: RecipeSummary) async throws {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            repo.restore(recipe.recipeId)
            mirrorRecipesFromRepository()
            syncPhase = .synced(.now)
            return
        }
        #endif
        let restoredRecipe = try await apiClient.restoreRecipe(recipeID: recipe.recipeId)
        upsertRecipe(restoredRecipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
    }

    func deleteRecipe(_ recipe: RecipeSummary) async throws {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            repo.delete(recipe.recipeId)
            mirrorRecipesFromRepository()
            syncPhase = .synced(.now)
            return
        }
        #endif
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
