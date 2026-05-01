import Foundation
import GoogleSignIn
import Observation
import SwiftData
import UserNotifications
import SimmerSmithKit

@MainActor
@Observable
final class AppState {
    enum MainTab: Hashable {
        case week
        case grocery
        case recipes
        case events
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

    struct AssistantDeltaEvent: Decodable {
        let messageId: String
        let delta: String
    }

    struct AssistantRecipeDraftEvent: Decodable {
        let messageId: String
        let draft: RecipeDraft
    }

    struct AssistantErrorEvent: Decodable {
        let messageId: String
        let detail: String
    }

    struct AssistantWeekUpdatedEvent: Decodable {
        let week: WeekSnapshot
    }

    let settingsStore: ConnectionSettingsStore
    let cacheStore: SimmerSmithCacheStore
    let apiClient: SimmerSmithAPIClient
    let subscriptionStore = SubscriptionStore()
    @ObservationIgnored private lazy var _assistantCoordinator: AIAssistantCoordinator = AIAssistantCoordinator(appState: self)
    var assistantCoordinator: AIAssistantCoordinator { _assistantCoordinator }
    var pendingPaywall: PaywallReason?

    // Tracks the refresh task started by clearLocalCache() so that a
    // follow-up resetConnection() can cancel it before it races with the
    // cleared connection state.
    var postClearRefreshTask: Task<Void, Never>?
    var showOnboardingInterview = false

    var serverURLDraft: String
    var authTokenDraft: String
    var aiProviderModeDraft: String = "auto"
    /// User-typed region used for in-season produce (M12 Phase 3).
    /// Free text — the AI infers state/country. Empty = generic US.
    var userRegionDraft: String = ""
    /// Per-user image-gen provider (M17). `"openai"` (default) or
    /// `"gemini"`. Hydrated from `profile.settings["image_provider"]`.
    var imageProviderDraft: String = "openai"
    /// Current iOS notification authorization status (M18). Hydrated by
    /// `ensurePushBootstrap()` on `refreshAll()` and refreshed after the
    /// user toggles a push preference. Drives the "Open iOS Settings"
    /// hint in `SettingsView` when iOS has a denial on record.
    var pushAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Current household snapshot (M21). Loaded by `refreshHousehold()`
    /// during `refreshAll()`. Drives the Settings → Household section.
    var currentHousehold: HouseholdSnapshot?
    var aiDirectProviderDraft: String = ""
    var aiDirectAPIKeyDraft: String = ""
    var aiOpenAIModelDraft: String = ""
    var aiAnthropicModelDraft: String = ""

    var profile: ProfileSnapshot?
    var currentWeek: WeekSnapshot?
    var recipes: [RecipeSummary] = []
    var recipeMetadata: RecipeMetadata?
    /// Memory-log entries keyed by recipeID. Refreshed lazily when
    /// the recipe-detail view appears; survives detail dismissal.
    var recipeMemories: [String: [RecipeMemory]] = [:]
    var aiCapabilities: AICapabilities?
    var exports: [ExportRun] = []
    var assistantThreads: [AssistantThreadSummary] = []
    var assistantThreadDetails: [String: AssistantThread] = [:]
    var ingredientPreferences: [IngredientPreference] = []
    var guests: [Guest] = []
    var eventSummaries: [EventSummary] = []
    var eventDetails: [String: Event] = [:]
    var checkedGroceryItemIDs: Set<String> = []
    var seasonalProduce: [InSeasonItem] = []
    var seasonalProduceFetchedAt: Date?
    /// One-shot search term that other tabs can plant when they want to
    /// hand off to the Recipes view. Consumed (cleared) by RecipesView in
    /// onChange/onAppear so it never re-applies on a back-navigation.
    var recipesPrefilledSearch: String?
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
        !ConnectionSettingsStore.normalizeServerURL(serverURLDraft).isEmpty
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
        if !aiDirectProviderDraft.isEmpty {
            return providerAPIKeyConfigured(providerID: aiDirectProviderDraft)
        }
        return ["openai", "anthropic"].contains { providerAPIKeyConfigured(providerID: $0) }
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
            syncRegionDraft(from: profile)
            syncImageProviderDraft(from: profile)
            // Push drafts are derived from profile.settings — no extra sync needed;
            // ensurePushBootstrap() is called in refreshAll() after network hydration.
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

    static let productionServerURL = "https://simmersmith.fly.dev"

    func signInWithApple(identityToken: String) async {
        lastErrorMessage = nil
        // Point at production server for the auth call
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL

        do {
            let response = try await apiClient.signInWithApple(identityToken: identityToken)
            // Store the session JWT as the auth token
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
            await refreshAll()
            if response.isNewUser {
                showOnboardingInterview = true
            }
        } catch {
            lastErrorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func signInWithGoogle(identityToken: String) async {
        lastErrorMessage = nil
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL

        do {
            let response = try await apiClient.signInWithGoogle(identityToken: identityToken)
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
            await refreshAll()
            if response.isNewUser {
                showOnboardingInterview = true
            }
        } catch {
            lastErrorMessage = "Google sign in failed: \(error.localizedDescription)"
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
            let serverWeek = try await apiClient.fetchCurrentWeek()
            // Route through the same auto-advance helper used by
            // `refreshWeek` so cold launch shows today's week even
            // when the server's most-recently-started record is
            // ahead of or behind today's calendar week.
            let fetchedWeek = try await advanceCurrentWeekToTodayIfStaleOrNil(serverWeek)

            profile = fetchedProfile
            syncAIDrafts(from: fetchedProfile)
            syncRegionDraft(from: fetchedProfile)
            syncImageProviderDraft(from: fetchedProfile)
            currentWeek = fetchedWeek
            // Best-effort: fire the APNs permission prompt once on first launch after sign-in.
            // A failure here must never crash bootstrap.
            await ensurePushBootstrap()
            // Best-effort household snapshot for the Settings UI (M21).
            await refreshHousehold()
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

    func clearLocalCache() {
        // Cancel any in-flight refresh started by a previous clearLocalCache
        // call so we do not race a fresh sync against the reset we are about
        // to perform.
        postClearRefreshTask?.cancel()
        postClearRefreshTask = nil
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
        if hasSavedConnection {
            syncPhase = .loading
            postClearRefreshTask = Task { [weak self] in
                await self?.refreshAll()
            }
        }
    }

    func resetConnection() {
        // Cancel any in-flight refresh so it does not try to use the
        // connection we are about to clear.
        postClearRefreshTask?.cancel()
        postClearRefreshTask = nil
        settingsStore.clear()
        serverURLDraft = ""
        authTokenDraft = ""
        clearHouseholdContext()
        // Also clear the Google Sign-In cache so the next sign-in presents
        // the account picker instead of silently reusing the previous user.
        GIDSignIn.sharedInstance.signOut()
        clearLocalCache()
    }

    var hasCachedContent: Bool {
        profile != nil || currentWeek != nil || !recipes.isEmpty || !exports.isEmpty
    }
}
