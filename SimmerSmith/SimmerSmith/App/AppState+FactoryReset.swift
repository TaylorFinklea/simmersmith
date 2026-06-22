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
            recipesImported: Bool = false,
            weeksImported: Bool = false,
            eventsImported: Bool = false,
            pantryProfileImported: Bool = false,
            warnings: [String] = []
        ) {
            self.deletedHouseholdIDs = deletedHouseholdIDs
            self.newHouseholdID = newHouseholdID
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
    ///  5. RE-IMPORT (with the JWT'd client, into the fresh session): recipes → weeks → events →
    ///     pantry-profile. The fresh household has no receipts, so each loader runs. Per-feature
    ///     receipts are confirmed to report what landed.
    ///  6. DISCARD the JWT — the everyday client returns to unauthenticated (no flow reads Fly).
    ///  7. RELOAD all repositories + publish the result summary.
    ///
    /// Idempotent / re-runnable: re-running re-wipes then re-imports; the receipts make every
    /// loader a safe retry and the wipe makes the whole thing safe to repeat.
    func startFreshFromFly(appleIdentityToken: String) async {
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
        startFreshState = .running(progress: "Erasing CloudKit households…")
        let privateStore = householdSession?.privateStore

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
        // warning rather than aborting.
        if let privateStore {
            do {
                try privateStore.clearPrivatePlane()
            } catch {
                result.warnings.append("Private data wasn't fully cleared: \(error.localizedDescription)")
            }
        } else {
            result.warnings.append("Private data plane wasn't available to clear.")
        }

        // 3. WIPE LOCAL — engine token file + repos, then the SwiftData cache + in-memory props.
        startFreshState = .running(progress: "Clearing local data…")
        teardownHouseholdSession()
        clearLocalCache()

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

        // 5. RE-IMPORT under the JWT'd client, into the fresh session, in order. The fresh
        //    household has no receipts, so each loader runs. The recipe loader is run EXPLICITLY
        //    here because its first-launch auto-path (inside ensureHouseholdSession) can't carry
        //    a Fly JWT post-identity — only this one-shot flow provides one (spec §1 GAP).
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
        result.pantryProfileImported =
            session.privateStore?.hasMigrationReceipt(scope: "pantry-profile") ?? false

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

    /// Drop the temporary one-shot Fly JWT (clears it from `settingsStore` so the everyday
    /// `apiClient` returns to unauthenticated). Mirrors the post-import cleanup in
    /// `importWeeksFromFly`.
    private func discardOneShotJWT() {
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
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
