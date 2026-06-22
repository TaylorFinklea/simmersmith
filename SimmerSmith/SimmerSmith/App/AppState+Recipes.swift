import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import HouseholdSync
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
            // SP-C slice 3: week + grocery repos.
            let weekRepo = WeekRepository(session: session)
            let groceryRepo = GroceryRepository(session: session)
            // SP-C slice 4: event + guest repos.
            let guestRepo = GuestRepository(session: session)
            let eventRepo = EventRepository(session: session, guests: guestRepo)
            // SP-C slice 5: per-user PRIVATE-plane repos (profile + preferences). These
            // ride NSPCKC (auto-sync) off `session.privateStore`, NOT the household engine.
            let profileRepo = ProfileRepository(session: session)
            let preferenceRepo = PreferenceRepository(session: session)
            // SP-C slice 5: household-zone pantry + alias repos.
            let pantryRepo = PantryRepository(session: session)
            let aliasRepo = AliasRepository(session: session)
            // SP-C AI-1: AIService — the single seam for all AI calls. Keychain key
            // store; reads provider/model config from private-plane store directly.
            let aiSvc = AIService(session: session)

            householdSession = session
            recipeRepository = recipeRepo
            metadataRepository = metadataRepo
            weekRepository = weekRepo
            groceryRepository = groceryRepo
            guestRepository = guestRepo
            eventRepository = eventRepo
            profileRepository = profileRepo
            preferenceRepository = preferenceRepo
            pantryRepository = pantryRepo
            aliasRepository = aliasRepo
            aiService = aiSvc

            // Initial kick — the repos auto-reload on session.storeRevision, but need a
            // first read after construction.
            recipeRepo.startObserving()
            metadataRepo.startObserving()
            weekRepo.startObserving()
            guestRepo.startObserving()
            eventRepo.startObserving()
            pantryRepo.startObserving()
            aliasRepo.startObserving()
            recipeRepo.reload()
            metadataRepo.reloadMetadata()
            weekRepo.reload()
            guestRepo.reload()
            eventRepo.reload()
            pantryRepo.reload()
            aliasRepo.reload()
            // Private-plane repos fetch-on-demand (no storeRevision observer — NSPCKC has
            // no equivalent change signal here); a first read after construction.
            profileRepo.reload()
            preferenceRepo.reload()

            // Mirror the repo's projections onto AppState's @Observable stored vars so the
            // existing views (which bind to `recipes` / `recipeMetadata`) update without change.
            observeRecipeRepository()
            observeMetadataRepository()
            observeWeekRepository()
            observeEventRepository()
            observePantryRepository()
            observeAliasRepository()
            // Private-plane repos publish their own projection (no storeRevision); observe it.
            observeProfileRepository()
            observePreferenceRepository()
            mirrorRecipesFromRepository()
            mirrorMetadataFromRepository()
            mirrorWeekFromRepository()
            mirrorEventsFromRepository()
            mirrorGuestsFromRepository()
            mirrorPantryFromRepository()
            mirrorAliasesFromRepository()
            // Mirror the private-plane repos so DietaryGoalView pre-fills + the Settings
            // pickers (imageProvider/unitSystem/userRegion) reflect the CloudKit data.
            mirrorProfileFromRepository()
            mirrorPreferencesFromRepository()
            // SP-C AI-1: hydrate AI provider/model drafts from the private plane.
            syncAIDraftsFromRepo()

            // SP-C identity slice (spec §1.3): signal RootView that the household is
            // resolved and the app is ready to show MainTabView.
            self.householdLaunchPhase = .ready
            // Symmetry with the failure path: clear the dedup task now that setup is
            // done. The fast-path guard (`householdSession != nil`) short-circuits future
            // callers, so the task no longer needs to be held for dedup.
            self.householdSessionSetupTask = nil
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

        // 0. PREFLIGHT the iCloud account status (review finding B/F). This is the
        //    deterministic gate — an unavailable account (signed out, restricted, no
        //    account) must NOT fall through to discovery (which on a fresh device can
        //    return zero zones WITHOUT throwing) and then mint a second household,
        //    orphaning the existing one. Only `.available` proceeds.
        let accountStatus: CKAccountStatus
        do {
            accountStatus = try await provisioner.container.accountStatus()
        } catch {
            // Couldn't read account status — treat as transient; stay resolving + retry.
            lastErrorMessage = "Couldn't check your iCloud account. Will retry."
            return nil
        }
        guard accountStatus == .available else {
            householdLaunchPhase = .iCloudUnavailable
            lastErrorMessage = "Sign in to iCloud in Settings to use SimmerSmith."
            return nil
        }

        // 1. DISCOVER before create (spec §7 landmine). A throw here means we could not
        //    determine whether a household zone exists — so we must NOT mint (that path
        //    only runs on a definitive "zero zones" → nil household id). The zero-zone
        //    result is RETRIED a few times below before we conclude "truly zero", because
        //    a fresh/reinstalled device's private-DB zone list can lag a few seconds
        //    (finding B) and an empty-but-not-throwing list would otherwise orphan-mint.
        let result: HouseholdZoneProvisioner.DiscoveryResult
        do {
            result = try await discoverWithZeroZoneRetry()
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

        // Ambiguous: multiple household zones, none provably populated (finding A). Do NOT
        // alphabetical-guess into an unproven zone — surface an error and stay resolving so
        // a later retry (foreground) can re-probe once propagation/repair settles.
        if result.isAmbiguous {
            lastErrorMessage = "Found \(result.ignoredHouseholdIDs.count) CloudKit households "
                + "but couldn't confirm which holds your data. Will retry."
            return nil
        }

        // Multiple household zones — discovery picked the data-RICHEST (the zone holding your
        // recipes/data); the rest are stale empty mints from earlier builds. Informational,
        // not data loss. (If data ever looks wrong, Settings → Start Fresh from Fly re-imports clean.)
        if !result.ignoredHouseholdIDs.isEmpty {
            lastErrorMessage = "Your kitchen loaded fine. Found "
                + "\(result.ignoredHouseholdIDs.count) leftover empty household(s) from earlier "
                + "builds — harmless."
        }

        if let discovered = result.householdID, !discovered.isEmpty {
            // Finding G: a prior mint may have created the zone but failed the profile
            // write, leaving a profile-less household. Repair it idempotently so the user
            // isn't locked into a household whose HouseholdProfile root record is missing.
            try? await provisioner.ensureHouseholdProfile(householdID: discovered, name: "My Household")
            return discovered
        }

        // 2. No household zone exists (confirmed after retries) → MINT a new one: fresh
        //    UUID, ensure the zone, and write a default HouseholdProfile so the zone is
        //    non-empty (and future discovery's HouseholdProfile signal finds it).
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

    /// Discover the household, RETRYING the "zero zones" outcome a few times with backoff
    /// (review finding B). A fresh/reinstalled device's private-DB zone list can return
    /// empty WITHOUT throwing while it propagates — concluding "truly zero" too eagerly
    /// would mint a second household and orphan the existing one. A non-empty result (or a
    /// throw, which the caller handles) returns immediately; only the empty case waits.
    private func discoverWithZeroZoneRetry() async throws -> HouseholdZoneProvisioner.DiscoveryResult {
        // Build a fresh provisioner here rather than receiving one — `HouseholdZoneProvisioner`
        // wraps a non-Sendable `CKContainer`, so passing it across the actor boundary into
        // this helper trips Swift 6 region isolation. Construction is cheap + idempotent.
        let provisioner = HouseholdZoneProvisioner()
        let backoffsNanos: [UInt64] = [1_500_000_000, 3_000_000_000] // ~1.5s, ~3s
        var attempt = 0
        while true {
            let result = try await provisioner.discoverHouseholdResult()
            // A resolved or ambiguous result means the zone list had content — done.
            if result.householdID != nil || result.isAmbiguous { return result }
            // Empty list. If we still have backoff budget, wait and re-probe.
            guard attempt < backoffsNanos.count else { return result }
            try? await Task.sleep(nanoseconds: backoffsNanos[attempt])
            attempt += 1
        }
    }

    /// Returns true when the error indicates the iCloud account is not signed in or
    /// is temporarily unavailable — as opposed to a transient network hiccup. Used by
    /// `resolveHouseholdID()` to set `householdLaunchPhase = .iCloudUnavailable` so
    /// `RootView` shows the "Sign in to iCloud in Settings" prompt.
    ///
    /// `.permissionFailure` is deliberately NOT treated as an auth error (review finding
    /// F): it's a container/ACL issue, not "not signed in" — routing a signed-in user to
    /// "sign into iCloud" would be wrong. The deterministic `accountStatus()` preflight in
    /// `resolveHouseholdID()` is the authority for the not-signed-in case.
    private func isICloudAuthError(_ error: Error) -> Bool {
        // CKError is available because this function lives inside #if canImport(CloudKit).
        if let ckError = error as? CKError {
            switch ckError.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
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
        weekRepository = nil
        groceryRepository = nil
        eventRepository = nil
        guestRepository = nil
        profileRepository = nil
        preferenceRepository = nil
        pantryRepository = nil
        aliasRepository = nil
        aiService = nil
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

    // MARK: - SP-C slice 3: Week repository mirroring

    /// Re-arm the week-repo observation and mirror the week list onto AppState's
    /// currentWeek / browsedWeek / checkedGroceryItemIDs slots.
    func observeWeekRepository() {
        guard let repo = weekRepository else { return }
        withObservationTracking {
            _ = repo.weeks
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorWeekFromRepository()
                self?.observeWeekRepository()
            }
        }
    }

    /// Push the week-repo's current week list into AppState. Resolves
    /// `currentWeek` as the week whose start is today (UTC day match),
    /// or the newest available week when today has no week. Preserves
    /// `browsedWeek` pointer if still present in the updated list.
    func mirrorWeekFromRepository() {
        guard let repo = weekRepository else { return }
        let all = repo.weeks

        // Resolve currentWeek: the week whose weekStart matches today (UTC).
        let todayKey = Self.utcDayKey(Date())
        if let todayWeek = all.first(where: { Self.utcDayKey($0.weekStart) == todayKey }) {
            currentWeek = todayWeek
        } else if currentWeek == nil {
            // No week for today yet — default to the newest (weeks sorted newest-first).
            currentWeek = all.first
        } else if let cw = currentWeek, let refreshed = all.first(where: { $0.weekId == cw.weekId }) {
            // Refreshed version of the same week.
            currentWeek = refreshed
        }

        // Keep browsedWeek fresh if it's still in the list.
        if let bw = browsedWeek, let refreshed = all.first(where: { $0.weekId == bw.weekId }) {
            browsedWeek = refreshed
        }

        // Hydrate checkedGroceryItemIDs from the current week's grocery items (mirrors
        // the Fly refreshWeek path: "M22: server is now the source of truth for check state").
        if let week = currentWeek {
            checkedGroceryItemIDs = Set(week.groceryItems.filter(\.isChecked).map(\.groceryItemId))
        }
    }

    private static func utcDayKey(_ date: Date) -> String {
        utcDayFormatter.string(from: date)
    }

    private static let utcDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - SP-C slice 4: Event + Guest repository mirroring

    /// Re-arm the event-repo observation and mirror events/summaries onto AppState.
    func observeEventRepository() {
        guard let repo = eventRepository else { return }
        withObservationTracking {
            _ = repo.events
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorEventsFromRepository()
                self?.observeEventRepository()
            }
        }
    }

    /// Push the event-repo's event list into AppState's eventSummaries + eventDetails.
    func mirrorEventsFromRepository() {
        guard let repo = eventRepository else { return }
        let all = repo.events
        eventSummaries = all.map { event in
            EventSummary(
                eventId: event.eventId,
                name: event.name,
                eventDate: event.eventDate,
                occasion: event.occasion,
                attendeeCount: event.attendeeCount,
                status: event.status,
                linkedWeekId: event.linkedWeekId,
                mealCount: event.meals.count,
                createdAt: event.createdAt,
                updatedAt: event.updatedAt
            )
        }
        for event in all {
            eventDetails[event.eventId] = event
        }
    }

    /// Push the guest-repo's guest list into AppState's guests array.
    func mirrorGuestsFromRepository() {
        guard let repo = guestRepository else { return }
        guests = repo.guests
    }

    // MARK: - SP-C slice 5: Pantry + Alias repository mirroring

    /// Re-arm the pantry-repo observation and mirror `pantryItems` onto AppState.
    func observePantryRepository() {
        guard let repo = pantryRepository else { return }
        withObservationTracking {
            _ = repo.pantryItems
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorPantryFromRepository()
                self?.observePantryRepository()
            }
        }
    }

    /// Push the pantry-repo's item list into AppState's `pantryItems`.
    func mirrorPantryFromRepository() {
        guard let repo = pantryRepository else { return }
        pantryItems = repo.pantryItems
    }

    /// Re-arm the alias-repo observation and mirror `householdAliases` onto AppState.
    func observeAliasRepository() {
        guard let repo = aliasRepository else { return }
        withObservationTracking {
            _ = repo.aliases
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorAliasesFromRepository()
                self?.observeAliasRepository()
            }
        }
    }

    /// Push the alias-repo's alias list into AppState's `householdAliases`.
    func mirrorAliasesFromRepository() {
        guard let repo = aliasRepository else { return }
        householdAliases = repo.aliases
    }

    // MARK: - SP-C slice 5: Profile + Preference (private-plane) repository mirroring

    /// Re-arm the profile-repo observation and mirror its projection onto AppState.
    ///
    /// Unlike the household repos (which observe `session.storeRevision`), the private-plane
    /// repos publish their OWN @Observable projections (`settings` / `dietaryGoal`) and have
    /// no storeRevision signal (NSPCKC has no equivalent here). So we observe the repo's
    /// published projection directly — when a write calls `reload()`, the projection changes
    /// and this fires, re-mirroring + re-arming (the recipe observe/mirror pattern, but keyed
    /// on the repo's own state rather than storeRevision).
    func observeProfileRepository() {
        guard let repo = profileRepository else { return }
        withObservationTracking {
            _ = repo.settings
            _ = repo.dietaryGoal
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorProfileFromRepository()
                self?.observeProfileRepository()
            }
        }
    }

    /// Project the profile repo's `settings` + `dietaryGoal` onto the `profile` snapshot the
    /// Settings views read (`profile?.dietaryGoal` gates DietaryGoalView's pre-fill + Clear
    /// button; `profile?.settings["user_region"]` backs the region "unchanged" check) and
    /// seed the Settings picker drafts (imageProvider / unitSystem / userRegion) so a
    /// CloudKit boot shows the saved values instead of defaults.
    ///
    /// Merges over any existing Fly `profile` so non-private-plane fields the subscription
    /// rows still read (`isPro` / `isTrial` / `usage` / `staples` / `secretFlags`) survive.
    /// `autoGroceryFromMeals` needs no seeding — it is a computed property that reads
    /// `repo.settings` directly.
    func mirrorProfileFromRepository() {
        guard let repo = profileRepository else { return }

        // Build the merged settings dict: repo's owned non-AI keys override, the rest of any
        // existing profile settings (e.g. AI keys still on Fly) are preserved.
        var mergedSettings = profile?.settings ?? [:]
        for (key, value) in repo.settings {
            mergedSettings[key] = value
        }

        let existing = profile
        profile = ProfileSnapshot(
            updatedAt: repo.dietaryGoal?.updatedAt ?? existing?.updatedAt,
            settings: mergedSettings,
            secretFlags: existing?.secretFlags ?? [:],
            staples: existing?.staples ?? [],
            dietaryGoal: repo.dietaryGoal,
            isPro: existing?.isPro ?? false,
            isTrial: existing?.isTrial ?? false,
            usage: existing?.usage ?? []
        )

        // Seed the Settings picker drafts from the repo settings so first render reflects
        // the saved values (the sync* helpers default sensibly when a key is absent).
        if let snapshot = profile {
            syncImageProviderDraft(from: snapshot)
            syncUnitSystemDraft(from: snapshot)
            syncRegionDraft(from: snapshot)
        }
    }

    /// Re-arm the preference-repo observation and mirror its `preferences` onto AppState.
    /// Mirrors the recipe pattern but keyed on the repo's own @Observable projection
    /// (the private plane has no storeRevision signal).
    func observePreferenceRepository() {
        guard let repo = preferenceRepository else { return }
        withObservationTracking {
            _ = repo.preferences
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.mirrorPreferencesFromRepository()
                self?.observePreferenceRepository()
            }
        }
    }

    /// Push the preference-repo's list into AppState's `ingredientPreferences`.
    func mirrorPreferencesFromRepository() {
        guard let repo = preferenceRepository else { return }
        ingredientPreferences = repo.preferences
    }

    // MARK: - SP-C slice 3: one-shot weeks + grocery Fly→CloudKit import

    /// State surfaced to the Settings UI for the "Import my weeks" trigger button.
    enum WeekImportState: Equatable {
        /// Receipt already present in the local store — migration previously completed.
        case alreadyImported
        /// Idle: ready to start (no import has run yet this session).
        case idle
        /// Import is in-progress (button shows a spinner).
        case running
        /// Import completed successfully during this session.
        case done
        /// Import failed; `reason` is a user-readable message.
        case failed(String)
    }

    /// Check the receipt gate against the local store and set `weekImportState`
    /// accordingly. Called when the Settings section first appears.
    func refreshWeekImportState() {
        guard let session = householdSession else {
            weekImportState = .idle
            return
        }
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: "weeks"),
            zoneID: session.zoneID
        )
        weekImportState = session.store.record(for: receiptID) != nil ? .alreadyImported : .idle
    }

    /// One-shot weeks + grocery import triggered by the user from Settings.
    ///
    /// Receives the Apple identity token from the Settings view's
    /// `SignInWithAppleButton` result, exchanges it for a Fly JWT, then runs
    /// `migrateWeeksIfNeeded`. The Fly JWT is written to `settingsStore` so that
    /// `apiClient` picks it up transparently — the same path that everyday sign-in
    /// used before the Identity slice. The token stays in `settingsStore` after the
    /// import; that is harmless because no everyday flow reads from Fly (all data
    /// paths are CloudKit-gated). The token is NOT used for any CloudKit operation.
    func importWeeksFromFly(appleIdentityToken: String) async {
        guard let session = householdSession else {
            weekImportState = .failed("CloudKit session not ready — try again after launch completes.")
            return
        }
        weekImportState = .running

        // 1. Exchange the Apple identity token for a Fly JWT. Point the client at
        //    the production server so the token exchange hits the right endpoint.
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL

        do {
            let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
        } catch {
            weekImportState = .failed("Sign-in failed: \(error.localizedDescription)")
            return
        }

        // 2. Run the migration. Receipt-gated — idempotent if already done.
        await migrateWeeksIfNeeded(session: session, apiClient: apiClient)

        // 3. Confirm the receipt landed so we know the import actually completed.
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: "weeks"),
            zoneID: session.zoneID
        )
        if session.store.record(for: receiptID) != nil {
            weekImportState = .done
            // Clear the one-shot Fly JWT — no everyday flow reads from Fly
            // (all paths are CloudKit-gated), so the token should not linger.
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
            authTokenDraft = ""
            // Trigger a repo reload so the imported weeks appear immediately.
            weekRepository?.reload()
            mirrorWeekFromRepository()
        } else {
            // Drain failed or network error — receipt was not stamped.
            weekImportState = .failed("Import failed — please try again.")
        }
    }

    // MARK: - SP-C slice 4: one-shot events + guests Fly→CloudKit import

    /// State surfaced to the Settings UI for the "Import my events" trigger button.
    enum EventImportState: Equatable {
        /// Receipt already present in the local store — migration previously completed.
        case alreadyImported
        /// Idle: ready to start (no import has run yet this session).
        case idle
        /// Import is in-progress.
        case running
        /// Import completed successfully during this session.
        case done
        /// Import failed; `reason` is a user-readable message.
        case failed(String)
    }

    /// Check the events receipt gate against the local store and set `eventImportState`
    /// accordingly. Called when the Settings section first appears.
    func refreshEventImportState() {
        guard let session = householdSession else {
            eventImportState = .idle
            return
        }
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: "events"),
            zoneID: session.zoneID
        )
        eventImportState = session.store.record(for: receiptID) != nil ? .alreadyImported : .idle
    }

    /// True once the `migrated:weeks` receipt is present in the local store. Gates the events
    /// import: migrated EventGroceryItem rows carry `mergedIntoWeekID`/`mergedIntoGroceryItemID`
    /// pointing at week GroceryItem records the WEEKS migration creates, so events must not be
    /// imported until weeks is done (the two imports are independent one-shots).
    var weeksImportComplete: Bool {
        guard let session = householdSession else { return false }
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: "weeks"),
            zoneID: session.zoneID
        )
        return session.store.record(for: receiptID) != nil
    }

    /// One-shot events + guests + event-grocery import triggered by the user from Settings.
    ///
    /// Receives the Apple identity token from the Settings view's SignInWithAppleButton
    /// result, exchanges it for a Fly JWT, then runs `migrateEventsIfNeeded`. The Fly JWT
    /// is written to `settingsStore` so that `apiClient` picks it up transparently — the
    /// same one-shot auth path the weeks import uses. The token is cleared after the import
    /// completes (success or failure) because no everyday flow reads from Fly.
    func importEventsFromFly(appleIdentityToken: String) async {
        guard let session = householdSession else {
            eventImportState = .failed("CloudKit session not ready — try again after launch completes.")
            return
        }
        eventImportState = .running

        // 1. Exchange the Apple identity token for a Fly JWT.
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL

        do {
            let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
        } catch {
            eventImportState = .failed("Sign-in failed: \(error.localizedDescription)")
            return
        }

        // 2. Run the migration. Receipt-gated — idempotent if already done.
        await migrateEventsIfNeeded(session: session, apiClient: apiClient)

        // 3. Confirm the receipt landed so we know the import actually completed.
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: "events"),
            zoneID: session.zoneID
        )
        if session.store.record(for: receiptID) != nil {
            eventImportState = .done
            // Clear the one-shot Fly JWT — no everyday flow reads from Fly.
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
            authTokenDraft = ""
            // Trigger repo reloads so imported events + guests appear immediately.
            guestRepository?.reload()
            eventRepository?.reload()
            mirrorGuestsFromRepository()
            mirrorEventsFromRepository()
        } else {
            // Drain failed or network error — receipt was not stamped.
            eventImportState = .failed("Import failed — please try again.")
        }
    }

    // MARK: - SP-C slice 5: one-shot pantry + profile + prefs + aliases Fly→CloudKit import

    /// State surfaced to the Settings UI for the "Import my pantry + profile" trigger button.
    enum PantryProfileImportState: Equatable {
        /// Private-plane receipt already present — migration previously completed.
        case alreadyImported
        /// Idle: ready to start (no import has run yet this session).
        case idle
        /// Import is in-progress.
        case running
        /// Import completed successfully during this session.
        case done
        /// Import failed; `reason` is a user-readable message.
        case failed(String)
    }

    /// Check the private-plane receipt gate and set `pantryProfileImportState` accordingly.
    /// Called when the Settings section first appears. Reads from the private plane —
    /// a nil privateStore (pre-boot / iCloud unavailable) is treated as idle.
    func refreshPantryProfileImportState() {
        guard let store = householdSession?.privateStore else {
            pantryProfileImportState = .idle
            return
        }
        // Receipt gate: look for the "pantry-profile" receipt in the private plane.
        pantryProfileImportState = store.hasMigrationReceipt(scope: "pantry-profile")
            ? .alreadyImported : .idle
    }

    /// One-shot pantry + profile + prefs + aliases import triggered by the user from Settings.
    ///
    /// Receives the Apple identity token from the Settings view's SignInWithAppleButton
    /// result, exchanges it for a Fly JWT, then runs `migratePantryProfileIfNeeded`. The
    /// Fly JWT is cleared after the import completes (success or failure) because no
    /// everyday flow reads from Fly. Mirrors the pattern from `importWeeksFromFly`.
    func importPantryProfileFromFly(appleIdentityToken: String) async {
        guard let session = householdSession else {
            pantryProfileImportState = .failed("CloudKit session not ready — try again after launch completes.")
            return
        }
        pantryProfileImportState = .running

        // 1. Exchange the Apple identity token for a Fly JWT.
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL

        do {
            let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
        } catch {
            pantryProfileImportState = .failed("Sign-in failed: \(error.localizedDescription)")
            return
        }

        // 2. Run the migration. Receipt-gated — idempotent if already done.
        await migratePantryProfileIfNeeded(session: session, apiClient: apiClient)

        // 3. Confirm the private-plane receipt landed so we know the import actually completed.
        let receiptPresent = session.privateStore?.hasMigrationReceipt(scope: "pantry-profile") ?? false

        if receiptPresent {
            pantryProfileImportState = .done
        } else {
            pantryProfileImportState = .failed("Import failed — please try again.")
        }

        // 4. Clear the one-shot Fly JWT regardless of outcome — no everyday flow reads Fly.
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        authTokenDraft = ""

        // 5. Trigger repo reloads so imported items appear immediately (success path only).
        if case .done = pantryProfileImportState {
            pantryRepository?.reload()
            aliasRepository?.reload()
            profileRepository?.reload()
            preferenceRepository?.reload()
            mirrorPantryFromRepository()
            mirrorAliasesFromRepository()
        }
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
