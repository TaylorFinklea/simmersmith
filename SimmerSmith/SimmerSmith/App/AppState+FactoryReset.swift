import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import HouseholdSync
#endif

extension AppState {
    // MARK: - SP-C factory reset: Start Fresh from Fly (spec §3)

    #if canImport(CloudKit)

    /// State surfaced to the Settings UI for the destructive "Start Fresh from Fly"
    /// trigger. The `.running` case carries the current step as a user-readable
    /// progress string; `.done` carries the per-feature result summary.
    enum StartFreshState: Equatable {
        /// Idle: ready to start (no reset has run yet this session).
        case idle
        /// In-progress; `progress` is the current step (auth / wipe / mint / import).
        case running(progress: String)
        /// Completed successfully; `result` summarises the re-import (per-feature counts).
        case done(StartFreshResult)
        /// Failed; `reason` is a user-readable message. The auth-first ordering means a
        /// failure BEFORE the wipe leaves CloudKit untouched (nothing was deleted yet).
        case failed(String)
    }

    /// Per-feature outcome of the re-import phase, shown in the Settings summary after a
    /// successful reset. Each loader is receipt-gated against the FRESH household (which
    /// has no receipts), so each runs; a loader that hit a network error leaves its receipt
    /// unstamped and is reported as not-imported here.
    struct StartFreshResult: Equatable {
        /// Zone ids deleted by the CloudKit wipe (every prior `household-*` zone).
        var deletedHouseholdIDs: [String]
        /// The fresh household id minted after the wipe.
        var newHouseholdID: String?
        /// True when the `migrated:ingredients` receipt is present after the import.
        var ingredientsImported: Bool
        /// True when the `migrated:recipes` receipt is present after the import (recipes ran).
        var recipesImported: Bool
        /// True when the `migrated:weeks` receipt is present after the import.
        var weeksImported: Bool
        /// True when the `migrated:events` receipt is present after the import.
        var eventsImported: Bool
        /// True when the private-plane `pantry-profile` receipt is present after the import.
        var pantryProfileImported: Bool
        /// Non-fatal warnings collected during the run (e.g. private-plane wipe degraded).
        var warnings: [String]

        init(
            deletedHouseholdIDs: [String] = [],
            newHouseholdID: String? = nil,
            ingredientsImported: Bool = false,
            recipesImported: Bool = false,
            weeksImported: Bool = false,
            eventsImported: Bool = false,
            pantryProfileImported: Bool = false,
            warnings: [String] = []
        ) {
            self.deletedHouseholdIDs = deletedHouseholdIDs
            self.newHouseholdID = newHouseholdID
            self.ingredientsImported = ingredientsImported
            self.recipesImported = recipesImported
            self.weeksImported = weeksImported
            self.eventsImported = eventsImported
            self.pantryProfileImported = pantryProfileImported
            self.warnings = warnings
        }
    }

    /// THE factory-reset orchestration (spec §3): wipe EVERYTHING CloudKit-side, mint ONE
    /// fresh household, and re-import recipes + weeks + events + pantry/profile from Fly under
    /// a single one-shot Apple→Fly auth.
    ///
    /// Ordering is load-bearing:
    ///  1. AUTH FIRST — exchange the Apple identity token for a Fly JWT BEFORE any wipe. If
    ///     the exchange throws, STOP: nothing has been deleted, so a bad token can never leave
    ///     a half-wiped state. The JWT is written to `settingsStore` so `apiClient` picks it up
    ///     transparently (the same one-shot pattern `importWeeksFromFly` uses — there is no
    ///     separate authed client object; the everyday client reads its token from the store).
    ///  2. WIPE CLOUDKIT — `deleteAllHouseholdZones()` (every `household-*` zone) +
    ///     `clearPrivatePlane()` (every private-plane @Model). The private-plane wipe runs off
    ///     the CURRENT session's `privateStore`, captured BEFORE teardown nils the session.
    ///  3. WIPE LOCAL — `teardownHouseholdSession()` (engine token file + repos) + `clearLocalCache()`.
    ///  4. MINT FRESH — `ensureHouseholdSession()`; discovery finds zero zones → mints one clean
    ///     household. Aborts if it doesn't reach `.ready`.
    ///  5. RE-IMPORT (with the JWT'd client, into the fresh session): ingredients → recipes → weeks → events →
    ///     pantry-profile. The fresh household has no receipts, so each loader runs. Per-feature
    ///     receipts are confirmed to report what landed.
    ///  6. DISCARD the JWT — the everyday client returns to unauthenticated (no flow reads Fly).
    ///  7. RELOAD all repositories + publish the result summary.
    ///
    /// Idempotent / re-runnable: re-running re-wipes then re-imports; the receipts make every
    /// loader a safe retry and the wipe makes the whole thing safe to repeat.
    func startFreshFromFly(appleIdentityToken: String) async {
        guard CachedHouseholdSystemOperationPolicy.allows(
            .factoryReset,
            isCachedBootstrap: householdSession?.isCachedBootstrap == true) else {
            startFreshState = .failed("Finish household reconciliation before resetting.")
            return
        }
        // 1. AUTH FIRST — fail before wiping if the token is bad.
        startFreshState = .running(progress: "Signing in to your account…")

        // Point the client at production for the token exchange, mirroring importWeeksFromFly.
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL
        do {
            let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
            // Set the JWT on the everyday client (transparently, via settingsStore). This is
            // the "temporary authed client": it is cleared again in step 6.
            settingsStore.save(serverURLString: Self.productionServerURL, authToken: response.token)
            authTokenDraft = response.token
        } catch {
            // Nothing has been wiped yet — a sign-in failure is fully recoverable.
            startFreshState = .failed("Sign-in failed: \(error.localizedDescription)")
            return
        }

        var result = StartFreshResult()

        // 2. WIPE CLOUDKIT. Capture the private store from the CURRENT session BEFORE teardown
        //    nils it — `teardownHouseholdSession()` releases `householdSession`, and with it the
        //    `privateStore` accessor, so the private-plane wipe must run first.
        //
        //    I1: the `PrivatePlaneStore` we capture wraps a `ModelContext`, which holds a STRONG
        //    reference to its `ModelContainer`. `HouseholdSession.privateContainer` is otherwise the
        //    ONLY strong ref, so `teardownHouseholdSession()` would normally release the container
        //    immediately — before NSPCKC's async background export pushes the local deletes to the
        //    user's PRIVATE DB. The private plane is PER-USER (not household-keyed), so the next
        //    session re-mirrors that DB and would RESURRECT any un-exported rows (assistant
        //    threads/messages, dietary goal, preference signals — none of which this flow re-imports).
        //    Holding `privateStore` in scope across teardown + mint keeps the container alive so the
        //    export has the best chance to run before the new container mirrors the DB.
        startFreshState = .running(progress: "Erasing CloudKit households…")
        guard let resetSession = householdSession else {
            discardOneShotJWT()
            startFreshState = .failed("Couldn't access the active household session.")
            return
        }
        let privateStore = resetSession.privateStore

        // simmersmith-glw: quiesce the repair scheduler BEFORE the zone wipe. Unlike the
        // sync `deactivate()` used by sign-out/adopt teardown (`HouseholdSession.clearState()`
        // /`detach()`), this flow IS async and can afford to actually wait — `quiesce()`
        // deactivates AND awaits any in-flight pass stopping at its next sub-pass boundary.
        // Without this, a repair pass's mid-flight save can hit `.zoneNotFound` right after
        // `deleteAllHouseholdZones()` below, and `HouseholdSyncEngine.handleFailedSave`'s
        // owner-path zone RE-CREATION resurrects the zone this step is about to delete.
        await resetSession.repairScheduler.quiesce()
        guard householdSession === resetSession else {
            discardOneShotJWT()
            startFreshState = .failed("The household session changed during reset.")
            return
        }
        // Retire the cache root before deleting server zones. A crash after the remote wipe must
        // never leave the pre-reset household selectable on next launch.
        let shadowCacheRetired = resetSession.invalidateShadowCacheForDestructiveReset()
        guard shadowCacheRetired else {
            discardOneShotJWT()
            startFreshState = .failed("Couldn't safely retire the local household cache.")
            return
        }

        let provisioner = HouseholdZoneProvisioner()
        do {
            result.deletedHouseholdIDs = try await provisioner.deleteAllHouseholdZones()
        } catch {
            // The zone wipe failed — abort with a clear error. The JWT is discarded so the
            // everyday client stays unauthenticated; re-running retries the whole flow.
            discardOneShotJWT()
            startFreshState = .failed("Couldn't erase CloudKit households: \(error.localizedDescription)")
            return
        }

        // Private-plane wipe is non-fatal: the receipts gate re-import locally, and a degraded
        // private plane (iCloud hiccup) shouldn't block the household wipe + re-import. Record a
        // warning rather than aborting. Track whether it SUCCEEDED, though: a FAILED wipe leaves the
        // old `pantry-profile` receipt in the mirror, which makes `migratePantryProfileIfNeeded`
        // SKIP — so we must NOT later report `pantryProfileImported == true` off a surviving receipt
        // (C2). `nil` private store counts as a failure (nothing was cleared).
        var privatePlaneWiped = false
        if let privateStore {
            do {
                try privateStore.clearPrivatePlane()
                privatePlaneWiped = true
            } catch {
                result.warnings.append("Private data wasn't fully cleared: \(error.localizedDescription)")
            }
        } else {
            result.warnings.append("Private data plane wasn't available to clear.")
        }

        // 3. WIPE LOCAL — engine token file + repos, then the SwiftData cache + in-memory props.
        startFreshState = .running(progress: "Clearing local data…")
        teardownHouseholdSession()
        // I2: drop the per-device Reminders mapping too (as `resetConnection` does). After the
        // re-import, grocery items get NEW ids; a stale `GroceryReminderMapping` (old id → reminder)
        // would dangle and produce duplicate / mis-targeted Reminders. The fresh import re-maps clean.
        clearReminderMappings()
        clearLocalCache()

        // C1: `clearLocalCache()` spawns `postClearRefreshTask = Task { await refreshAll() }` whenever
        //     `hasSavedConnection` is true — which it IS here, because step 1 wrote the production URL +
        //     JWT to `settingsStore`. That detached refresh would call `ensureHouseholdSession()` again
        //     AND write Fly `profile`/`currentWeek`, racing this flow's own mint (step 4) + re-import
        //     (step 5) + reload (step 7) — a network-timing coin flip that can clobber the
        //     CloudKit-imported state with Fly data. The factory-reset flow OWNS the reload, so kill the
        //     rogue refresh outright; the final in-memory state must come from the CloudKit re-import.
        //     (`clearLocalCache` also cancels any PRE-EXISTING task at its top, covering that case too.)
        postClearRefreshTask?.cancel()
        postClearRefreshTask = nil
        // The post-clear refresh set `.loading`; restore the in-progress reset status.
        syncPhase = .idle

        // 4. MINT FRESH — discovery now finds zero zones and mints exactly one clean household.
        startFreshState = .running(progress: "Creating a fresh household…")
        await ensureHouseholdSession()

        // Abort if the fresh session didn't reach a ready state — a mint failure (iCloud
        // unavailable, transient CloudKit error) would otherwise re-import into nothing.
        guard householdLaunchPhase == .ready, let session = householdSession else {
            discardOneShotJWT()
            startFreshState = .failed(
                "Couldn't create a fresh household. " +
                (lastErrorMessage ?? "Please try again once iCloud is reachable.")
            )
            return
        }
        result.newHouseholdID = HouseholdZoneProvisioner.householdID(fromZoneName: session.zoneID.zoneName)

        // I1: now that the fresh session is ready, give the OLD private container's NSPCKC export a
        //     brief settle before we let it go, so the `clearPrivatePlane()` deletes have the best
        //     chance to reach the user's private DB ahead of the new container mirroring it. The
        //     captured `privateStore` holds a `ModelContext`, which holds a STRONG ref to the old
        //     `ModelContainer`; keeping `privateStore` alive across this await (it is referenced again
        //     just below) pins that container so the export can run. Residual limitation: NSPCKC export
        //     timing is opaque — there is no API to confirm the push completed, so this is best-effort;
        //     if iCloud is slow, a re-run (idempotent) re-wipes.
        if privatePlaneWiped {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        // Keep the old private container alive until AFTER the settle above (and the new session is
        // ready), so its NSPCKC export isn't cut short by an early release. No-op at runtime.
        _ = privateStore

        // 5. RE-IMPORT under the JWT'd client, into the fresh session, in order. The fresh
        //    household has no receipts, so each loader runs. The ingredient and recipe loaders are run EXPLICITLY
        //    here for parity / belt-and-suspenders: `ensureHouseholdSession` (step 4) ALSO calls
        //    `migrateRecipesIfNeeded` with this JWT (the apiClient reads its token from settingsStore
        //    per-request, and step 1 wrote it there), so by here the recipes receipt is usually
        //    already stamped and this call is a receipt-gated no-op. Keeping it explicit guards against
        //    a future refactor that drops the recipe migration from the launch path.
        startFreshState = .running(progress: "Importing ingredients…")
        await migrateIngredientsIfNeeded(session: session, apiClient: apiClient)
        result.ingredientsImported = hasReceipt(scope: "ingredients", session: session)

        startFreshState = .running(progress: "Importing recipes…")
        await migrateRecipesIfNeeded(session: session, apiClient: apiClient)
        result.recipesImported = hasReceipt(scope: "recipes", session: session)

        startFreshState = .running(progress: "Importing weeks…")
        await migrateWeeksIfNeeded(session: session, apiClient: apiClient)
        result.weeksImported = hasReceipt(scope: "weeks", session: session)

        startFreshState = .running(progress: "Importing events…")
        await migrateEventsIfNeeded(session: session, apiClient: apiClient)
        result.eventsImported = hasReceipt(scope: "events", session: session)

        startFreshState = .running(progress: "Importing pantry & profile…")
        await migratePantryProfileIfNeeded(session: session, apiClient: apiClient)
        // C2: only trust the receipt as proof of a real re-import if the old private plane was
        //     actually wiped. If `clearPrivatePlane()` FAILED (or was unavailable), the stale
        //     `pantry-profile` receipt may survive in the fresh session's NSPCKC mirror, which makes
        //     `migratePantryProfileIfNeeded` SKIP — so a present receipt here would NOT mean fresh data
        //     landed. Don't report success for a step that was skipped because the wipe failed; report
        //     not-imported and warn the user the old data may remain.
        if privatePlaneWiped {
            result.pantryProfileImported =
                session.privateStore?.hasMigrationReceipt(scope: "pantry-profile") ?? false
        } else {
            result.pantryProfileImported = false
            result.warnings.append(
                "Pantry/Profile was NOT re-imported — old private data may remain. Please run Start Fresh again."
            )
        }

        // 6. DISCARD the one-shot JWT — no everyday flow reads from Fly.
        discardOneShotJWT()

        // 7. RELOAD all repositories so the re-imported data appears immediately, then publish
        //    the summary the Settings UI shows.
        startFreshState = .running(progress: "Refreshing your kitchen…")
        await reloadAllRepositoriesAfterImport()
        startFreshState = .done(result)
    }

    // MARK: - Helpers

    /// True when the household-zone migration receipt for `scope` is present in the local
    /// store. Mirrors the receipt gate used by the loaders + `importWeeksFromFly`.
    private func hasReceipt(scope: String, session: HouseholdSession) -> Bool {
        let receiptID = CKRecord.ID(
            recordName: HouseholdMigrationRunner.receiptRecordName(scope: scope),
            zoneID: session.zoneID
        )
        return session.store.record(for: receiptID) != nil
    }

    /// Drop the temporary one-shot Fly JWT AND the stored server URL, returning the app to its
    /// everyday post-identity no-Fly state. I4: clearing only the token but keeping
    /// `serverURLString = productionServerURL` leaves `hasSavedConnection == true`, so a later
    /// everyday `clearLocalCache()` (e.g. the standalone Settings "Clear Local Cache" button) would
    /// spawn a `refreshAll()` that 401s against Fly with no token. Factory-reset's contract is a
    /// clean slate, so wipe the URL too (`hasSavedConnection == false`) — matching how the app
    /// normally sits post-identity (no server URL set; all data paths are CloudKit-gated).
    private func discardOneShotJWT() {
        settingsStore.clear()
        serverURLDraft = ""
        authTokenDraft = ""
    }

    /// Reload + re-mirror every repository after the re-import so the freshly imported data
    /// shows in the UI without waiting for the next storeRevision tick. Mirrors the per-feature
    /// reload+mirror calls the individual import methods do, gathered in one place.
    ///
    /// Recipes + metadata go through `refreshRecipes()` (its CloudKit path does the
    /// reload + mirror for both) so this file doesn't reach the two file-private recipe
    /// mirror helpers; the remaining repos reload + mirror directly via the internal helpers.
    private func reloadAllRepositoriesAfterImport() async {
        await refreshRecipes()

        weekRepository?.reload()
        ingredientRepository?.reload()
        guestRepository?.reload()
        eventRepository?.reload()
        pantryRepository?.reload()
        aliasRepository?.reload()
        profileRepository?.reload()
        preferenceRepository?.reload()

        mirrorWeekFromRepository()
        mirrorGuestsFromRepository()
        mirrorEventsFromRepository()
        mirrorPantryFromRepository()
        mirrorAliasesFromRepository()
        mirrorProfileFromRepository()
        mirrorPreferencesFromRepository()
    }

    #endif
}
