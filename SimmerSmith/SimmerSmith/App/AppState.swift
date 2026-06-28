import Foundation
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

    /// Server-emitted "still working" tick during long single-shot tool
    /// runs (e.g. `generate_week_plan`). Keeps the SSE connection alive
    /// against edge idle-timeouts and carries elapsed time so the UI can
    /// annotate the spinner instead of feeling like a hang.
    struct AssistantHeartbeatEvent: Decodable {
        let messageId: String
        let elapsedSeconds: Int
    }

    let settingsStore: ConnectionSettingsStore
    let cacheStore: SimmerSmithCacheStore
    let apiClient: SimmerSmithAPIClient
    let subscriptionStore = SubscriptionStore()

    // SP-C Task 5 — CloudKit data plane. Constructed after sign-in once the
    // household ID is known (from the Fly household snapshot), torn down on
    // sign-out. nil before sign-in. Guarded by canImport(CloudKit) so the
    // app target still compiles on platforms without CloudKit.
    #if canImport(CloudKit)
    @ObservationIgnored var householdSession: HouseholdSession?
    @ObservationIgnored var recipeRepository: RecipeRepository?
    @ObservationIgnored var metadataRepository: MetadataRepository?
    // SP-C slice 3: week + grocery CloudKit repos.
    @ObservationIgnored var weekRepository: WeekRepository?
    @ObservationIgnored var groceryRepository: GroceryRepository?
    // SP-C slice 4: event + guest CloudKit repos.
    @ObservationIgnored var eventRepository: EventRepository?
    @ObservationIgnored var guestRepository: GuestRepository?
    // SP-C slice 5: per-user PRIVATE-plane repos (NSPCKC, not the household zone).
    @ObservationIgnored var profileRepository: ProfileRepository?
    @ObservationIgnored var preferenceRepository: PreferenceRepository?
    // SP-C slice 5: household-zone pantry + alias repos.
    @ObservationIgnored var pantryRepository: PantryRepository?
    @ObservationIgnored var aliasRepository: AliasRepository?
    // SP-C AI-1: the single AI call seam. Constructed alongside profileRepository
    // once the CloudKit session is live. API keys live in Keychain; provider/model
    // config in the private plane. nil before the session is ready.
    @ObservationIgnored var aiService: AIService?
    // SP-C AI-5: private-plane assistant conversation storage. Constructed alongside
    // profileRepository once the CloudKit session is live. nil before the session is ready.
    @ObservationIgnored var assistantRepository: AssistantRepository?
    /// Dedup guard for `ensureHouseholdSession()`. Set synchronously (before
    /// any `await`) so a second concurrent caller on MainActor sees it and
    /// awaits the same task instead of starting a second setup. Cleared on
    /// sign-out so a fresh session can be established after re-sign-in.
    @ObservationIgnored var householdSessionSetupTask: Task<Void, Never>?
    #endif
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
    /// M27 — unit-system localization. `"us"` (default) or `"metric"`.
    /// Constrains AI-generated and AI-found recipes to use the right
    /// units. Hydrated from `profile.settings["unit_system"]`.
    var unitSystemDraft: String = "us"
    /// Current iOS notification authorization status (M18). Hydrated by
    /// `ensurePushBootstrap()` on `refreshAll()` and refreshed after the
    /// user toggles a push preference. Drives the "Open iOS Settings"
    /// hint in `SettingsView` when iOS has a denial on record.
    var pushAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Current household snapshot (M21). Loaded by `refreshHousehold()`
    /// during `refreshAll()`. Drives the Settings → Household section.
    var currentHousehold: HouseholdSnapshot?
    /// M22.5: Reminders bridge state must be @Observable stored
    /// properties — UserDefaults-backed computed properties don't
    /// trigger SwiftUI re-renders, which is why the Settings →
    /// Grocery section showed no feedback after Sync now in build 35.
    /// Hydrated in `loadCachedData()`; mutators persist to
    /// UserDefaults as a side effect for cross-launch persistence.
    var reminderListIdentifier: String?
    var lastReminderSyncAt: Date?
    var lastReminderSyncSummary: String?
    /// Token returned by `RemindersService.observeChanges`. Held so we
    /// can remove the observer on sign-out and avoid duplicate
    /// subscriptions when the user re-toggles Reminders sync.
    @ObservationIgnored
    var reminderObserver: NSObjectProtocol?
    /// Debounce handle for `EKEventStoreChanged` — iCloud emits a
    /// flurry of changes during sync, and we don't want to hit the
    /// server N times for one user-visible edit.
    @ObservationIgnored
    var reminderChangeDebounce: Task<Void, Never>?
    var aiDirectProviderDraft: String = ""
    var aiDirectAPIKeyDraft: String = ""
    var aiOpenAIModelDraft: String = ""
    var aiAnthropicModelDraft: String = ""
    /// SP-C "Open models" entry: the selected vendor (glm|kimi|minimax) and its model id.
    /// The single "Open models" provider row spans all three vendors; the chosen model
    /// determines which vendor key + base URL is used (the model dropdown sets both).
    var aiOpenModelsVendorDraft: String = ""
    var aiOpenModelsModelDraft: String = ""
    /// SP-C — CloudKit-path model dropdown state, keyed by provider
    /// ("openai"/"anthropic"). Populated by `refreshCKAIModels(for:)` from the
    /// provider's live `/v1/models` (curated) or the static fallback. The Settings
    /// "Model" Picker reads these; replaces the retired Fly `availableAIModelsByProvider`.
    var ckAIModelOptions: [String: [String]] = [:]
    var ckAIModelFetchError: [String: String] = [:]
    /// Keyed by provider so overlapping fetches (e.g. a fast provider flip) don't
    /// clear each other's spinner.
    var isFetchingAIModels: [String: Bool] = [:]
    /// SP-C — user overrides for the AI-assistant suggestion chips, keyed by pageType
    /// ("week"/"recipe_detail"/…). Empty for a screen = the built-in defaults. Hydrated
    /// from the private-plane `assistant_prompts` setting; edited in Settings → AI.
    var assistantPromptOverrides: [String: [String]] = [:]

    var profile: ProfileSnapshot?
    var currentWeek: WeekSnapshot?
    /// The non-current week the user has navigated to via the Week-tab
    /// picker (e.g. "next week"). Hoisted from WeekView's local @State
    /// in Build 104 so the assistant SSE handler can update it by
    /// week_id when AI tools mutate a week other than `currentWeek` —
    /// previously `case "week.updated"` overwrote `currentWeek` with
    /// whatever week the AI touched, corrupting the "this week" view
    /// and leaving the browsed week stale.
    var browsedWeek: WeekSnapshot?
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
    /// M26 Phase 3 — per-household shorthand aliases. Loaded lazily
    /// when the Settings → AI → Custom terms screen opens.
    var householdAliases: [HouseholdTermAlias] = []
    /// M28 — pantry items (extends staples with typical-purchase
    /// quantity and recurring auto-add to weekly grocery). Loaded
    /// lazily when the Grocery → Pantry screen opens.
    var pantryItems: [PantryItem] = []
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

    // MARK: - SP-C slice 3: weeks import trigger state

    /// Tracks the one-shot Fly→CloudKit weeks+grocery import for the Settings trigger.
    /// `WeekImportState` enum is declared in `AppState+Recipes` (same extension).
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var weekImportState: WeekImportState = .idle
    #endif

    // MARK: - SP-C slice 4: events import trigger state

    /// Tracks the one-shot Fly→CloudKit events+guests+event-grocery import for the
    /// Settings trigger. `EventImportState` enum is declared in `AppState+Recipes`.
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var eventImportState: EventImportState = .idle
    #endif

    // MARK: - SP-C slice 5: pantry + profile import trigger state

    /// Tracks the one-shot Fly→CloudKit pantry+profile+prefs+aliases import for the
    /// Settings trigger. `PantryProfileImportState` enum is declared in `AppState+Recipes`.
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var pantryProfileImportState: PantryProfileImportState = .idle
    #endif

    // MARK: - SP-C factory reset: Start Fresh from Fly trigger state

    /// Tracks the destructive "Start Fresh from Fly" flow (wipe all CloudKit +
    /// re-import) for the Settings trigger. `StartFreshState` enum and the
    /// `StartFreshResult` summary are declared in `AppState+FactoryReset`.
    /// Needs to live here (main class body) to be tracked by `@Observable`.
    #if canImport(CloudKit)
    var startFreshState: StartFreshState = .idle
    #endif

    // MARK: - SP-C identity slice: CloudKit-only launch gate

    /// SP-C identity slice (spec §1.3): phases of the iCloud-native launch.
    /// RootView gates on this — shows a loading state while `.resolving`,
    /// `MainTabView` once `.ready`, and a friendly "Sign in to iCloud" prompt
    /// when `.iCloudUnavailable`. The Fly sign-in screen is no longer shown.
    enum HouseholdLaunchPhase: Equatable {
        /// CloudKit household resolution in progress (initial state).
        case resolving
        /// Household resolved — ready to show `MainTabView`.
        case ready
        /// iCloud account not signed in or CKAccountStatus is not `.available`.
        case iCloudUnavailable
    }

    /// Current phase of the iCloud-native launch gate.
    var householdLaunchPhase: HouseholdLaunchPhase = .resolving

    /// Single source of truth: this build is CloudKit-only. Features not yet
    /// migrated to CloudKit (Weeks / Grocery / Events / Profile / AI) render
    /// `ComingSoonView` at their tab entry points so no Fly call is made and
    /// no 401 banners appear. Recipes is the first (and currently only) fully
    /// cut-over feature; subsequent slices will flip their gating off.
    let isCloudKitOnly: Bool = AppState.cloudKitOnlyBuild

    var syncPhase: SyncPhase = .idle
    var lastErrorMessage: String?
    /// SP-C identity slice (review finding C): in CloudKit-only mode the `.week` tab
    /// renders `ComingSoonView`, so landing there opens the app on an hourglass. Default
    /// to the cut-over Recipes (Forge) tab instead. `defaultLandingTab` is the single
    /// source of truth for both the initial value and the post-clear reset.
    var selectedTab: MainTab = AppState.defaultLandingTab
    /// The tab the app should open to. `.week` now that Weeks + Grocery are cut over;
    /// the Recipes fallback is retained here only for historical reference.
    static var defaultLandingTab: MainTab { .week }
    /// Compile-time mirror of `isCloudKitOnly` so the static `defaultLandingTab` can read
    /// it without an instance. Keep in lockstep with `isCloudKitOnly`.
    private static let cloudKitOnlyBuild = true
    /// Build 68 — bumped whenever the user changes a per-tab top-bar
    /// primary action in Settings. Views that build toolbars read this
    /// (via @Observable) so the SwiftUI graph re-renders without
    /// needing each consumer to subscribe to UserDefaults directly.
    var topBarConfigRevision: UInt32 = 0
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

    /// SP-C AI-5: true iff a BYO key exists for the configured provider (KeychainKeyStore).
    /// Replaces the Fly aiCapabilities/hasSavedConnection check — the assistant runs
    /// on-device via AssistantEngine; no Fly connection is required.
    var assistantExecutionAvailable: Bool {
        #if canImport(CloudKit)
        // aiService being non-nil means the CloudKit session is live; aiDirectAPIKeyConfigured
        // checks the Keychain via providerAPIKeyConfigured → aiService.hasKey.
        if aiService != nil { return aiDirectAPIKeyConfigured }
        #endif
        return false
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

    /// SP-C AI-5: status text for the assistant setup state shown when
    /// `assistantExecutionAvailable == false`. References the BYO-key path.
    var assistantExecutionStatusText: String {
        #if canImport(CloudKit)
        if aiService != nil {
            // CloudKit session is live but no key is configured.
            return "Add your OpenAI or Anthropic API key in Settings → AI to use the Assistant."
        }
        return "Sign in with iCloud to use the Assistant."
        #else
        return "The Assistant requires iCloud."
        #endif
    }

    func loadCachedData() {
        profile = cacheStore.loadProfile()
        if let profile {
            syncAIDrafts(from: profile)
            syncRegionDraft(from: profile)
            syncImageProviderDraft(from: profile)
            syncUnitSystemDraft(from: profile)
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
            // M22: server is the source of truth. Local cache load
            // (cold launch) trusts whatever was last persisted.
            checkedGroceryItemIDs = Set(
                groceryItems.filter(\.isChecked).map(\.groceryItemId)
            )
        } else {
            checkedGroceryItemIDs = []
        }
        // M22.5: hydrate the @Observable Reminders state so the
        // Settings sheet renders the right toggle / "Last synced"
        // values on first open.
        loadReminderState()
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
            syncUnitSystemDraft(from: fetchedProfile)
            currentWeek = fetchedWeek
            // Best-effort: fire the APNs permission prompt once on first launch after sign-in.
            // A failure here must never crash bootstrap.
            await ensurePushBootstrap()
            // Best-effort household snapshot for the Settings UI (M21).
            await refreshHousehold()
            #if canImport(CloudKit)
            // SP-C Task 5 — now that the household ID is known (from the Fly snapshot),
            // construct + boot the CloudKit household session and its repositories. The
            // recipe data plane reads/writes CloudKit from here on; the CloudKit-aware
            // overloads in AppState+Recipes route through the repos once this is set.
            await ensureHouseholdSession()
            #endif
            checkedGroceryItemIDs = Set(
                (fetchedWeek?.groceryItems ?? [])
                    .filter(\.isChecked)
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

            #if canImport(CloudKit)
            // When CloudKit session is active, metadata comes from MetadataRepository
            // via the mirror set up in ensureHouseholdSession(). Fetching from Fly here
            // would clobber those mirrored values until the next storeRevision tick.
            if recipeRepository == nil {
                if let metadata = try? await apiClient.fetchRecipeMetadata() {
                    recipeMetadata = metadata
                    try? cacheStore.saveRecipeMetadata(metadata)
                }
            }
            #else
            if let metadata = try? await apiClient.fetchRecipeMetadata() {
                recipeMetadata = metadata
                try? cacheStore.saveRecipeMetadata(metadata)
            }
            #endif

            // SP-C AI-5: assistant threads now live in the private plane (AssistantRepository).
            // refreshAssistantThreads() is called after ensureHouseholdSession() wires the
            // repository; the Fly fetchAssistantThreads() call is retired.
            await refreshAssistantThreads()
            // SP-C slice 5: ingredient preferences come from PreferenceRepository (private
            // plane) when the CloudKit session is active; fall back to Fly pre-session.
            #if canImport(CloudKit)
            if let prefRepo = preferenceRepository {
                prefRepo.reload()
                ingredientPreferences = prefRepo.preferences
            } else if let preferences = try? await apiClient.fetchIngredientPreferences() {
                ingredientPreferences = preferences
            }
            #else
            if let preferences = try? await apiClient.fetchIngredientPreferences() {
                ingredientPreferences = preferences
            }
            #endif
            await refreshAIModels(for: aiDirectProviderDraft)

            syncPhase = .synced(.now)
        } catch {
            lastErrorMessage = error.localizedDescription
            syncPhase = hasCachedContent ? .offline : .failed(error.localizedDescription)
        }
    }

    /// True if the error is a benign cancellation (Task or URLSession)
    /// that happens during normal view lifecycle — sheet dismissal,
    /// rapid navigation, app backgrounding. Surfacing these as red
    /// banners ("cancelled") is noise; callers should treat them as
    /// "stop without complaint". Build 104.
    func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
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
        // User/household-scoped collections that must NOT survive a cache
        // clear or sign-out (otherwise the previous user's data bleeds into
        // the next account on the same device). currentHousehold is also
        // cleared via resetConnection()->clearHouseholdContext(), but the
        // standalone "Clear Local Cache" button bypasses that path.
        browsedWeek = nil
        recipeMemories = [:]
        ingredientPreferences = []
        householdAliases = []
        pantryItems = []
        guests = []
        eventSummaries = []
        eventDetails = [:]
        seasonalProduce = []
        seasonalProduceFetchedAt = nil
        currentHousehold = nil
        syncPhase = .idle
        lastErrorMessage = nil
        // Review finding C: reset to the cut-over landing tab, not `.week` (which renders
        // ComingSoonView in CloudKit-only mode).
        selectedTab = AppState.defaultLandingTab
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
        // F29: best-effort unregister this device for the signing-out user
        // and drop the push dedup key BEFORE clearing the connection — the
        // DELETE needs the server URL + bearer token that settingsStore.clear()
        // is about to wipe. Without this, the next user on a shared device
        // keeps the old device row and never re-registers (same APNs token).
        PushService.shared.reset(apiClient: apiClient)
        settingsStore.clear()
        serverURLDraft = ""
        authTokenDraft = ""
        clearHouseholdContext()
        // M22: drop the per-device Reminders mapping. The next user
        // who signs in on this device gets a clean mapping for their
        // chosen Reminders list.
        clearReminderMappings()
        clearLocalCache()
    }

    var hasCachedContent: Bool {
        profile != nil || currentWeek != nil || !recipes.isEmpty || !exports.isEmpty
    }
}
