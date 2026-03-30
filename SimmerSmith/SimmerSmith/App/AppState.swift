import Foundation
import Observation
import SwiftData
import SimmerSmithKit

@MainActor
@Observable
final class AppState {
    enum MainTab: Hashable {
        case week
        case grocery
        case recipes
        case assistant
        case settings
    }

    enum SyncPhase: Equatable {
        case idle
        case loading
        case synced(Date)
        case offline
        case failed(String)
    }

    struct AssistantLaunchContext: Equatable {
        let threadID: String
        let initialText: String
        let attachedRecipeID: String?
        let attachedRecipeDraft: RecipeDraft?
        let intent: String
    }

    private struct AssistantDeltaEvent: Decodable {
        let messageId: String
        let delta: String
    }

    private struct AssistantRecipeDraftEvent: Decodable {
        let messageId: String
        let draft: RecipeDraft
    }

    private struct AssistantErrorEvent: Decodable {
        let messageId: String
        let detail: String
    }

    private let settingsStore: ConnectionSettingsStore
    private let cacheStore: SimmerSmithCacheStore
    private let apiClient: SimmerSmithAPIClient

    var serverURLDraft: String
    var authTokenDraft: String
    var aiProviderModeDraft: String = "auto"
    var aiDirectProviderDraft: String = ""
    var aiDirectAPIKeyDraft: String = ""
    var aiOpenAIModelDraft: String = ""
    var aiAnthropicModelDraft: String = ""

    var profile: ProfileSnapshot?
    var currentWeek: WeekSnapshot?
    var recipes: [RecipeSummary] = []
    var recipeMetadata: RecipeMetadata?
    var aiCapabilities: AICapabilities?
    var exports: [ExportRun] = []
    var assistantThreads: [AssistantThreadSummary] = []
    var assistantThreadDetails: [String: AssistantThread] = [:]
    var ingredientPreferences: [IngredientPreference] = []
    var checkedGroceryItemIDs: Set<String> = []
    var availableAIModelsByProvider: [String: [AIModelOption]] = [:]
    var aiModelErrorByProvider: [String: String] = [:]

    var syncPhase: SyncPhase = .idle
    var lastErrorMessage: String?
    var selectedTab: MainTab = .week
    var assistantLaunchContext: AssistantLaunchContext?
    var assistantSendingThreadIDs: Set<String> = []
    var assistantErrorByThreadID: [String: String] = [:]

    init(
        modelContainer: ModelContainer,
        settingsStore: ConnectionSettingsStore = .shared,
        apiClient: SimmerSmithAPIClient? = nil
    ) {
        self.settingsStore = settingsStore
        let connection = settingsStore.load()
        self.serverURLDraft = connection.serverURLString
        self.authTokenDraft = connection.authToken
        self.cacheStore = SimmerSmithCacheStore(modelContainer: modelContainer)
        self.apiClient = apiClient ?? SimmerSmithAPIClient(settingsStore: settingsStore)
    }

    var hasSavedConnection: Bool {
        !ConnectionSettingsStore.normalizeServerURL(settingsStore.load().serverURLString).isEmpty
    }

    var syncStatusText: String {
        switch syncPhase {
        case .idle:
            return hasSavedConnection ? "Ready to sync." : "Configure a server to begin."
        case .loading:
            return "Refreshing from server…"
        case .synced(let date):
            return "Synced \(date.formatted(date: .abbreviated, time: .shortened))."
        case .offline:
            return "Showing cached content while offline."
        case .failed(let message):
            return message
        }
    }

    var recipeTemplateCount: Int {
        recipeMetadata?.templates.count ?? 0
    }

    var assistantExecutionAvailable: Bool {
        if let aiCapabilities {
            return aiCapabilities.defaultTarget != nil
        }
        return hasSavedConnection
    }

    var aiDirectAPIKeyConfigured: Bool {
        profile?.secretFlags["ai_direct_api_key_present"] ?? false
    }

    var selectedDirectProviderModelDraft: String {
        get {
            switch aiDirectProviderDraft {
            case "openai":
                return aiOpenAIModelDraft
            case "anthropic":
                return aiAnthropicModelDraft
            default:
                return ""
            }
        }
        set {
            switch aiDirectProviderDraft {
            case "openai":
                aiOpenAIModelDraft = newValue
            case "anthropic":
                aiAnthropicModelDraft = newValue
            default:
                break
            }
        }
    }

    var selectedDirectProviderModels: [AIModelOption] {
        availableAIModelsByProvider[aiDirectProviderDraft] ?? []
    }

    var selectedDirectProviderModelError: String? {
        aiModelErrorByProvider[aiDirectProviderDraft]
    }

    var assistantExecutionStatusText: String {
        guard let aiCapabilities else {
            return "AI capability details appear after the server is reachable."
        }
        if aiCapabilities.defaultTarget != nil {
            return "Assistant is ready."
        }
        if let mcpProvider = aiCapabilities.availableProviders.first(where: { $0.providerKind == "mcp" }), !mcpProvider.available {
            switch mcpProvider.source {
            case "unconfigured":
                return "Configure an MCP server or save an API key to use the Assistant."
            case "unreachable":
                return "The MCP server is configured but not reachable right now."
            case "misconfigured":
                return "The MCP server is reachable, but it does not expose the expected Codex tools."
            default:
                return "No AI execution backend is currently available."
            }
        }
        return "No AI execution backend is currently available."
    }

    func loadCachedData() {
        profile = cacheStore.loadProfile()
        if let profile {
            syncAIDrafts(from: profile)
        }
        currentWeek = cacheStore.loadCurrentWeek()
        recipes = cacheStore.loadRecipes()
        recipeMetadata = cacheStore.loadRecipeMetadata()
        if let weekID = currentWeek?.weekId {
            exports = cacheStore.loadExports(for: weekID)
        }
        if let groceryItems = currentWeek?.groceryItems {
            checkedGroceryItemIDs = Set(
                groceryItems
                    .filter { cacheStore.isChecked(groceryItemID: $0.groceryItemId) }
                    .map(\.groceryItemId)
            )
        } else {
            checkedGroceryItemIDs = []
        }
    }

    func saveConnectionDetails() async {
        let normalizedURL = ConnectionSettingsStore.normalizeServerURL(serverURLDraft)
        settingsStore.save(serverURLString: normalizedURL, authToken: authTokenDraft)
        serverURLDraft = normalizedURL
        lastErrorMessage = nil
        await refreshAll()
    }

    func refreshAll() async {
        guard hasSavedConnection else {
            syncPhase = .idle
            return
        }

        syncPhase = .loading
        lastErrorMessage = nil

        do {
            let health = try await apiClient.fetchHealth()
            aiCapabilities = health.aiCapabilities

            let fetchedProfile = try await apiClient.fetchProfile()
            let fetchedWeek = try await apiClient.fetchCurrentWeek()

            profile = fetchedProfile
            syncAIDrafts(from: fetchedProfile)
            currentWeek = fetchedWeek
            checkedGroceryItemIDs = Set(
                (fetchedWeek?.groceryItems ?? [])
                    .filter { cacheStore.isChecked(groceryItemID: $0.groceryItemId) }
                    .map(\.groceryItemId)
            )

            try? cacheStore.saveProfile(fetchedProfile)

            if let fetchedWeek {
                try? cacheStore.saveCurrentWeek(fetchedWeek)
                let fetchedExports = try await apiClient.fetchWeekExports(weekID: fetchedWeek.weekId)
                exports = fetchedExports
                try? cacheStore.saveExports(fetchedExports, for: fetchedWeek.weekId)
            } else {
                exports = []
            }

            if let metadata = try? await apiClient.fetchRecipeMetadata() {
                recipeMetadata = metadata
                try? cacheStore.saveRecipeMetadata(metadata)
            }

            if let threads = try? await apiClient.fetchAssistantThreads() {
                assistantThreads = threads
            }
            if let preferences = try? await apiClient.fetchIngredientPreferences() {
                ingredientPreferences = preferences
            }
            await refreshAIModels(for: aiDirectProviderDraft)

            syncPhase = .synced(.now)
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    func refreshWeek() async {
        guard hasSavedConnection else { return }
        syncPhase = .loading
        do {
            currentWeek = try await apiClient.fetchCurrentWeek()
            if let currentWeek {
                try? cacheStore.saveCurrentWeek(currentWeek)
                exports = try await apiClient.fetchWeekExports(weekID: currentWeek.weekId)
                try? cacheStore.saveExports(exports, for: currentWeek.weekId)
                checkedGroceryItemIDs = Set(
                    currentWeek.groceryItems
                        .filter { cacheStore.isChecked(groceryItemID: $0.groceryItemId) }
                        .map(\.groceryItemId)
                )
            } else {
                exports = []
                checkedGroceryItemIDs = []
            }
            syncPhase = .synced(.now)
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

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
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    func fetchRecipe(recipeID: String) async throws -> RecipeSummary {
        let recipe = try await apiClient.fetchRecipe(recipeID: recipeID)
        upsertRecipe(recipe)
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
        return recipe
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

    func refreshAIModels(for providerID: String) async {
        let normalizedProvider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSavedConnection, !normalizedProvider.isEmpty else { return }
        do {
            let payload = try await apiClient.fetchProviderModels(providerID: normalizedProvider)
            availableAIModelsByProvider[normalizedProvider] = payload.models
            aiModelErrorByProvider[normalizedProvider] = nil
            switch normalizedProvider {
            case "openai":
                aiOpenAIModelDraft = payload.selectedModelId ?? payload.models.first?.modelId ?? aiOpenAIModelDraft
            case "anthropic":
                aiAnthropicModelDraft = payload.selectedModelId ?? payload.models.first?.modelId ?? aiAnthropicModelDraft
            default:
                break
            }
        } catch {
            aiModelErrorByProvider[normalizedProvider] = error.localizedDescription
            availableAIModelsByProvider[normalizedProvider] = []
        }
    }

    func saveAISettings(clearStoredAPIKey: Bool = false) async {
        guard hasSavedConnection else { return }
        do {
            var settings: [String: String] = [
                "ai_provider_mode": aiProviderModeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                "ai_direct_provider": aiDirectProviderDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                "ai_openai_model": aiOpenAIModelDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                "ai_anthropic_model": aiAnthropicModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let trimmedKey = aiDirectAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if clearStoredAPIKey {
                settings["ai_direct_api_key"] = ""
            } else if !trimmedKey.isEmpty {
                settings["ai_direct_api_key"] = trimmedKey
            }

            let fetchedProfile = try await apiClient.updateProfile(settings: settings)
            profile = fetchedProfile
            syncAIDrafts(from: fetchedProfile)
            try? cacheStore.saveProfile(fetchedProfile)
            await refreshAIModels(for: aiDirectProviderDraft)
            if let health = try? await apiClient.fetchHealth() {
                aiCapabilities = health.aiCapabilities
            }
            syncPhase = .synced(.now)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func searchNutritionItems(query: String = "", limit: Int = 20) async throws -> [NutritionItem] {
        try await apiClient.searchNutritionItems(query: query, limit: limit)
    }

    func searchBaseIngredients(query: String = "", limit: Int = 20) async throws -> [BaseIngredient] {
        try await apiClient.fetchBaseIngredients(query: query, limit: limit)
    }

    func fetchIngredientVariations(baseIngredientID: String) async throws -> [IngredientVariation] {
        try await apiClient.fetchIngredientVariations(baseIngredientID: baseIngredientID)
    }

    func resolveIngredient(_ ingredient: RecipeIngredient) async throws -> IngredientResolution {
        try await apiClient.resolveIngredient(ingredient)
    }

    func refreshIngredientPreferences() async {
        guard hasSavedConnection else { return }
        do {
            ingredientPreferences = try await apiClient.fetchIngredientPreferences()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func upsertIngredientPreference(
        preferenceID: String? = nil,
        baseIngredientID: String,
        preferredVariationID: String? = nil,
        preferredBrand: String = "",
        choiceMode: String = "preferred",
        active: Bool = true,
        notes: String = ""
    ) async throws -> IngredientPreference {
        let preference = try await apiClient.upsertIngredientPreference(
            preferenceID: preferenceID,
            baseIngredientID: baseIngredientID,
            preferredVariationID: preferredVariationID,
            preferredBrand: preferredBrand,
            choiceMode: choiceMode,
            active: active,
            notes: notes
        )
        if let index = ingredientPreferences.firstIndex(where: { $0.preferenceId == preference.preferenceId }) {
            ingredientPreferences[index] = preference
        } else {
            ingredientPreferences.append(preference)
            ingredientPreferences.sort { $0.baseIngredientName.localizedCaseInsensitiveCompare($1.baseIngredientName) == .orderedAscending }
        }
        return preference
    }

    func saveIngredientNutritionMatch(
        ingredientName: String,
        normalizedName: String?,
        nutritionItemID: String
    ) async throws -> IngredientNutritionMatch {
        try await apiClient.saveIngredientNutritionMatch(
            ingredientName: ingredientName,
            normalizedName: normalizedName,
            nutritionItemID: nutritionItemID
        )
    }

    func importRecipeDraft(fromURL url: String) async throws -> RecipeDraft {
        try await apiClient.importRecipe(fromURL: url)
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

    func generateRecipeSuggestionDraft(goal: String) async throws -> RecipeAIDraft {
        try await apiClient.generateRecipeSuggestionDraft(goal: goal)
    }

    func generateRecipeCompanionDrafts(recipeID: String) async throws -> RecipeAIOptions {
        try await apiClient.generateRecipeCompanionDrafts(recipeID: recipeID)
    }

    func refreshAssistantThreads() async {
        guard hasSavedConnection else { return }
        do {
            assistantThreads = try await apiClient.fetchAssistantThreads()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func fetchAssistantThread(threadID: String) async throws -> AssistantThread {
        let thread = try await apiClient.fetchAssistantThread(threadID: threadID)
        assistantThreadDetails[threadID] = thread
        upsertAssistantThreadSummary(
            AssistantThreadSummary(
                threadId: thread.threadId,
                title: thread.title,
                preview: thread.preview,
                createdAt: thread.createdAt,
                updatedAt: thread.updatedAt
            )
        )
        return thread
    }

    func createAssistantThread(title: String = "") async throws -> AssistantThreadSummary {
        let thread = try await apiClient.createAssistantThread(title: title)
        upsertAssistantThreadSummary(thread)
        return thread
    }

    func deleteAssistantThread(threadID: String) async throws {
        try await apiClient.deleteAssistantThread(threadID: threadID)
        assistantThreads.removeAll { $0.threadId == threadID }
        assistantThreadDetails.removeValue(forKey: threadID)
        assistantErrorByThreadID.removeValue(forKey: threadID)
    }

    func beginAssistantLaunch(
        initialText: String = "",
        title: String = "",
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general"
    ) async throws {
        let thread = try await createAssistantThread(title: title)
        assistantLaunchContext = AssistantLaunchContext(
            threadID: thread.threadId,
            initialText: initialText,
            attachedRecipeID: attachedRecipeID,
            attachedRecipeDraft: attachedRecipeDraft,
            intent: intent
        )
        selectedTab = .assistant
        _ = try? await fetchAssistantThread(threadID: thread.threadId)
    }

    func consumeAssistantLaunchContext() -> AssistantLaunchContext? {
        defer { assistantLaunchContext = nil }
        return assistantLaunchContext
    }

    func sendAssistantMessage(
        threadID: String,
        text: String,
        attachedRecipeID: String? = nil,
        attachedRecipeDraft: RecipeDraft? = nil,
        intent: String = "general"
    ) async throws {
        assistantSendingThreadIDs.insert(threadID)
        assistantErrorByThreadID[threadID] = nil
        defer { assistantSendingThreadIDs.remove(threadID) }

        let initialMessageCount = assistantThreadDetails[threadID]?.messages.count ?? 0
        let stream = try await apiClient.streamAssistantResponse(
            threadID: threadID,
            text: text,
            attachedRecipeID: attachedRecipeID,
            attachedRecipeDraft: attachedRecipeDraft,
            intent: intent
        )
        var streamFailure: Error?
        do {
            for try await event in stream {
                try applyAssistantStreamEvent(threadID: threadID, event: event)
            }
        } catch {
            streamFailure = error
        }
        let refreshedThread = try? await fetchAssistantThread(threadID: threadID)
        if let streamFailure {
            let refreshedCount = refreshedThread?.messages.count ?? 0
            if refreshedCount > initialMessageCount {
                assistantErrorByThreadID[threadID] = nil
                return
            }
            throw streamFailure
        }
    }

    func saveRecipe(_ draft: RecipeDraft) async throws -> RecipeSummary {
        let savedRecipe = try await apiClient.saveRecipe(draft)
        upsertRecipe(savedRecipe)
        if let metadata = try? await apiClient.fetchRecipeMetadata() {
            recipeMetadata = metadata
            try? cacheStore.saveRecipeMetadata(metadata)
        }
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
        return savedRecipe
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
        try await apiClient.deleteRecipe(recipeID: recipe.recipeId)
        recipes.removeAll { $0.recipeId == recipe.recipeId }
        try? cacheStore.saveRecipes(recipes)
        syncPhase = .synced(.now)
    }

    func fetchWeeks(limit: Int = 12) async throws -> [WeekSummary] {
        try await apiClient.fetchWeeks(limit: limit)
    }

    func fetchWeekByStart(_ weekStart: Date) async throws -> WeekSnapshot? {
        try await apiClient.fetchWeekByStart(weekStart)
    }

    func createWeek(weekStart: Date, notes: String = "") async throws -> WeekSnapshot {
        let week = try await apiClient.createWeek(weekStart: weekStart, notes: notes)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        return week
    }

    func saveWeekMeals(weekID: String, meals: [MealUpdateRequest]) async throws -> WeekSnapshot {
        let week = try await apiClient.updateWeekMeals(weekID: weekID, meals: meals)
        if currentWeek?.weekId == week.weekId {
            currentWeek = week
            try? cacheStore.saveCurrentWeek(week)
        }
        syncPhase = .synced(.now)
        return week
    }

    func submitMealFeedback(for meal: WeekMeal, sentiment: Int, notes: String) async throws {
        guard let weekID = currentWeek?.weekId else { return }
        _ = try await apiClient.submitFeedback(
            weekID: weekID,
            entries: [
                FeedbackEntryRequest(
                    mealId: meal.mealId,
                    targetType: "meal",
                    targetName: meal.recipeName,
                    sentiment: sentiment,
                    notes: notes
                )
            ]
        )
        await refreshWeek()
    }

    func submitGroceryFeedback(for item: GroceryItem, sentiment: Int, notes: String) async throws {
        guard let weekID = currentWeek?.weekId else { return }
        _ = try await apiClient.submitFeedback(
            weekID: weekID,
            entries: [
                FeedbackEntryRequest(
                    groceryItemId: item.groceryItemId,
                    targetType: "shopping_item",
                    targetName: item.ingredientName,
                    normalizedName: item.normalizedName,
                    sentiment: sentiment,
                    notes: notes
                )
            ]
        )
        await refreshWeek()
    }

    func isGroceryChecked(_ groceryItemID: String) -> Bool {
        checkedGroceryItemIDs.contains(groceryItemID)
    }

    func toggleGroceryChecked(_ groceryItemID: String) {
        let checked = !checkedGroceryItemIDs.contains(groceryItemID)
        if checked {
            checkedGroceryItemIDs.insert(groceryItemID)
        } else {
            checkedGroceryItemIDs.remove(groceryItemID)
        }
        try? cacheStore.setChecked(checked, groceryItemID: groceryItemID)
    }

    func clearLocalCache() {
        try? cacheStore.clearAll()
        profile = nil
        currentWeek = nil
        recipes = []
        recipeMetadata = nil
        exports = []
        assistantThreads = []
        assistantThreadDetails = [:]
        checkedGroceryItemIDs = []
        syncPhase = .idle
        lastErrorMessage = nil
        selectedTab = .week
        assistantLaunchContext = nil
        assistantSendingThreadIDs = []
        assistantErrorByThreadID = [:]
        aiProviderModeDraft = "auto"
        aiDirectProviderDraft = ""
        aiDirectAPIKeyDraft = ""
        aiOpenAIModelDraft = ""
        aiAnthropicModelDraft = ""
        availableAIModelsByProvider = [:]
        aiModelErrorByProvider = [:]
    }

    func resetConnection() {
        settingsStore.clear()
        serverURLDraft = ""
        authTokenDraft = ""
        clearLocalCache()
    }

    private var hasCachedContent: Bool {
        profile != nil || currentWeek != nil || !recipes.isEmpty || !exports.isEmpty
    }

    private func upsertRecipe(_ recipe: RecipeSummary) {
        if let index = recipes.firstIndex(where: { $0.recipeId == recipe.recipeId }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        recipes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func applyAssistantStreamEvent(threadID: String, event: AssistantStreamEnvelope) throws {
        switch event.event {
        case "thread.updated":
            let summary = try event.decode(AssistantThreadSummary.self)
            upsertAssistantThreadSummary(summary)
            if var detail = assistantThreadDetails[threadID] {
                detail = AssistantThread(
                    threadId: detail.threadId,
                    title: summary.title,
                    preview: summary.preview,
                    createdAt: detail.createdAt,
                    updatedAt: summary.updatedAt,
                    messages: detail.messages
                )
                assistantThreadDetails[threadID] = detail
            }
        case "user_message.created":
            let message = try event.decode(AssistantMessage.self)
            appendAssistantMessage(message, to: threadID)
        case "assistant.delta":
            let delta = try event.decode(AssistantDeltaEvent.self)
            applyAssistantDelta(threadID: threadID, delta: delta)
        case "assistant.recipe_draft":
            let draftEvent = try event.decode(AssistantRecipeDraftEvent.self)
            attachAssistantDraft(threadID: threadID, event: draftEvent)
        case "assistant.completed":
            let message = try event.decode(AssistantMessage.self)
            replaceAssistantMessage(message, in: threadID)
        case "assistant.error":
            let errorEvent = try event.decode(AssistantErrorEvent.self)
            assistantErrorByThreadID[threadID] = errorEvent.detail
        default:
            break
        }
    }

    private func upsertAssistantThreadSummary(_ thread: AssistantThreadSummary) {
        if let index = assistantThreads.firstIndex(where: { $0.threadId == thread.threadId }) {
            assistantThreads[index] = thread
        } else {
            assistantThreads.append(thread)
        }
        assistantThreads.sort { $0.updatedAt > $1.updatedAt }
    }

    private func syncAIDrafts(from profile: ProfileSnapshot) {
        let savedMode = profile.settings["ai_provider_mode"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiProviderModeDraft = savedMode.isEmpty ? "auto" : savedMode
        aiDirectProviderDraft = profile.settings["ai_direct_provider"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiOpenAIModelDraft = profile.settings["ai_openai_model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiAnthropicModelDraft = profile.settings["ai_anthropic_model"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        aiDirectAPIKeyDraft = ""
    }

    private func appendAssistantMessage(_ message: AssistantMessage, to threadID: String) {
        let existing = assistantThreadDetails[threadID]
        let createdAt = existing?.createdAt ?? assistantThreads.first(where: { $0.threadId == threadID })?.createdAt ?? .now
        var messages = existing?.messages ?? []
        if messages.contains(where: { $0.messageId == message.messageId }) {
            replaceAssistantMessage(message, in: threadID)
            return
        }
        messages.append(message)
        messages.sort { $0.createdAt < $1.createdAt }
        assistantThreadDetails[threadID] = AssistantThread(
            threadId: threadID,
            title: existing?.title ?? assistantThreads.first(where: { $0.threadId == threadID })?.title ?? "New Assistant Chat",
            preview: existing?.preview ?? assistantThreads.first(where: { $0.threadId == threadID })?.preview ?? "",
            createdAt: createdAt,
            updatedAt: existing?.updatedAt ?? .now,
            messages: messages
        )
    }

    private func replaceAssistantMessage(_ message: AssistantMessage, in threadID: String) {
        guard var detail = assistantThreadDetails[threadID] else {
            appendAssistantMessage(message, to: threadID)
            return
        }
        if let index = detail.messages.firstIndex(where: { $0.messageId == message.messageId }) {
            var messages = detail.messages
            messages[index] = message
            detail = AssistantThread(
                threadId: detail.threadId,
                title: detail.title,
                preview: detail.preview,
                createdAt: detail.createdAt,
                updatedAt: detail.updatedAt,
                messages: messages
            )
            assistantThreadDetails[threadID] = detail
        } else {
            appendAssistantMessage(message, to: threadID)
        }
    }

    private func applyAssistantDelta(threadID: String, delta: AssistantDeltaEvent) {
        if let existing = assistantThreadDetails[threadID]?.messages.first(where: { $0.messageId == delta.messageId }) {
            replaceAssistantMessage(
                AssistantMessage(
                    messageId: existing.messageId,
                    threadId: existing.threadId,
                    role: existing.role,
                    status: "streaming",
                    contentMarkdown: existing.contentMarkdown + delta.delta,
                    recipeDraft: existing.recipeDraft,
                    attachedRecipeId: existing.attachedRecipeId,
                    createdAt: existing.createdAt,
                    completedAt: existing.completedAt,
                    error: existing.error
                ),
                in: threadID
            )
            return
        }
        appendAssistantMessage(
            AssistantMessage(
                messageId: delta.messageId,
                threadId: threadID,
                role: "assistant",
                status: "streaming",
                contentMarkdown: delta.delta,
                recipeDraft: nil,
                attachedRecipeId: nil,
                createdAt: .now,
                completedAt: nil,
                error: ""
            ),
            to: threadID
        )
    }

    private func attachAssistantDraft(threadID: String, event: AssistantRecipeDraftEvent) {
        guard let existing = assistantThreadDetails[threadID]?.messages.first(where: { $0.messageId == event.messageId }) else {
            return
        }
        replaceAssistantMessage(
            AssistantMessage(
                messageId: existing.messageId,
                threadId: existing.threadId,
                role: existing.role,
                status: existing.status,
                contentMarkdown: existing.contentMarkdown,
                recipeDraft: event.draft,
                attachedRecipeId: existing.attachedRecipeId,
                createdAt: existing.createdAt,
                completedAt: existing.completedAt,
                error: existing.error
            ),
            in: threadID
        )
    }
}
