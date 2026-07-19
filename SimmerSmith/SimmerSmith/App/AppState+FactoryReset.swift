import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import HouseholdSync
#endif

#if canImport(CloudKit)
@MainActor
struct HouseholdFactoryResetBoundaryRunner {
    enum Outcome: Equatable {
        case ready(deletedHouseholdIDs: [String])
        case failed(String)
    }

    let beginLocalInvalidation: () throws -> Void
    let completeLocalInvalidation: () async throws -> Void
    let deleteServerZones: () async throws -> [String]
    let completeTransaction: () throws -> Void
    let mintReplacement: () async -> Bool

    func run() async -> Outcome {
        do {
            // This call is deliberately before the runner's first await.
            try beginLocalInvalidation()
            try await completeLocalInvalidation()
            let deleted = try await deleteServerZones()
            try completeTransaction()
            guard await mintReplacement() else {
                return .failed("Couldn't create a fresh household.")
            }
            return .ready(deletedHouseholdIDs: deleted)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
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
            isAuthoritative: householdSession?.hasCurrentAuthority == true
        ), householdLifecycleGateState() == .absent else {
            startFreshState = .failed("Finish household reconciliation before resetting.")
            return
        }

        // Resolve the CloudKit identity before Fly auth. After auth returns, the epoch-first
        // boundary below must run synchronously before another identity/server await.
        let preflightEpoch = sessionBootEpoch
        guard let resetSession = householdSession else {
            startFreshState = .failed("Couldn't access the active household session.")
            return
        }
        let accountRecordName = try? await householdLifecycleExecutor.currentAccountRecordName()
        guard sessionBootEpoch == preflightEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === resetSession,
              let accountRecordName,
              !accountRecordName.isEmpty,
              resetSession.engine.activeMirrorScopeSnapshot?.accountRecordName == accountRecordName
        else {
            startFreshState = .failed("Couldn't verify the current iCloud account.")
            return
        }

        startFreshState = .running(progress: "Signing in to your account…")
        settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
        serverURLDraft = Self.productionServerURL
        do {
            let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
            guard sessionBootEpoch == preflightEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === resetSession else {
                discardOneShotJWT()
                startFreshState = .failed("The household session changed during sign-in.")
                return
            }
            settingsStore.save(
                serverURLString: Self.productionServerURL,
                authToken: response.token)
            authTokenDraft = response.token
        } catch {
            discardOneShotJWT()
            startFreshState = .failed("Sign-in failed: \(error.localizedDescription)")
            return
        }

        let authenticatedEpoch = sessionBootEpoch
        await sessionBootQueue.enqueue { [weak self] in
            guard let self,
                  self.sessionBootEpoch == authenticatedEpoch,
                  self.householdLifecycleGateState() == .absent else {
                self?.discardOneShotJWT()
                self?.startFreshState = .failed(
                    "A household security transition interrupted reset.")
                return
            }
            await self.performAuthenticatedFactoryReset(
                accountRecordName: accountRecordName)
        }.value
    }

    private func performAuthenticatedFactoryReset(accountRecordName: String) async {
        var result = StartFreshResult()
        var transaction: HouseholdLifecycleTransaction?
        var resetEpoch: Int?
        var resetRepairScheduler: RepairScheduler?
        var privateStore: PrivatePlaneStore?
        var privatePlaneWiped = false

        func transactionStillCurrent() -> Bool {
            guard let transaction, let resetEpoch,
                  sessionBootEpoch == resetEpoch else { return false }
            return (try? householdLifecycleTransactionStore.pending()) == transaction
        }

        let runner = HouseholdFactoryResetBoundaryRunner(
            beginLocalInvalidation: { [self] in
                guard householdLifecycleGateState() == .absent,
                      let session = householdSession,
                      session.hasCurrentAuthority,
                      session.engine.activeMirrorScopeSnapshot?.accountRecordName
                        == accountRecordName else {
                    throw HouseholdLifecycleTransactionStore.Error.transactionConflict
                }

                resetRepairScheduler = session.repairScheduler
                privateStore = session.privateStore

                // Epoch/readiness/projections/capabilities move before persistence and before
                // this runner's first await.
                beginEpochFirstHouseholdTransition(
                    clearPersonalData: true,
                    interventionMessage: "Resetting this household…")
                resetEpoch = sessionBootEpoch

                let boundary = try HouseholdLifecycleTransaction(
                    kind: .factoryReset,
                    scope: nil,
                    remoteAccountRecordName: accountRecordName)
                try householdLifecycleTransactionStore.begin(boundary)
                transaction = boundary
                // The import marker outlives transaction completion, covering a crash between
                // remote deletion/mint and the final successful re-import.
                try factoryResetImportMarkerStore.set()
                try requestLifecycleInvalidation(for: boundary)
                syncPhase = .idle
                startFreshState = .running(progress: "Clearing local data…")
            },
            completeLocalInvalidation: { [self] in
                await resetRepairScheduler?.quiesce()
                resetRepairScheduler = nil
                guard transactionStillCurrent() else {
                    throw HouseholdLifecycleTransactionStore.Error.transactionConflict
                }
                try householdLifecycleExecutor.completeRootClear(
                    householdLifecyclePaths.shadowRootURL)

                if let privateStore {
                    do {
                        try privateStore.clearPrivatePlane()
                        privatePlaneWiped = true
                    } catch {
                        result.warnings.append(
                            "Private data wasn't fully cleared: \(error.localizedDescription)")
                    }
                } else {
                    result.warnings.append("Private data plane wasn't available to clear.")
                }
            },
            deleteServerZones: { [self] in
                guard transactionStillCurrent() else {
                    throw HouseholdLifecycleTransactionStore.Error.transactionConflict
                }
                startFreshState = .running(progress: "Erasing CloudKit households…")
                guard let transaction else {
                    throw HouseholdLifecycleTransactionStore.Error.transactionConflict
                }
                return try await deleteFactoryResetZonesBoundToAccount(
                    transaction: transaction,
                    isCurrent: transactionStillCurrent)
            },
            completeTransaction: { [self] in
                guard let transaction, transactionStillCurrent() else {
                    throw HouseholdLifecycleTransactionStore.Error.transactionConflict
                }
                try householdLifecycleTransactionStore.complete(transaction)
            },
            mintReplacement: { [self] in
                guard let resetEpoch, sessionBootEpoch == resetEpoch else { return false }
                startFreshState = .running(progress: "Creating a fresh household…")
                await ensureSessionBootOp(
                    requestEpoch: resetEpoch,
                    expectedAccountRecordName: accountRecordName)
                guard let replacementSession = householdSession else { return false }
                return factoryResetReplacementSessionIsCurrent(
                    replacementSession,
                    requestEpoch: resetEpoch,
                    resetAccountRecordName: accountRecordName)
                    && householdLaunchPhase == .ready
            })

        switch await runner.run() {
        case .failed(let reason):
            discardOneShotJWT()
            startFreshState = .failed("Couldn't finish reset: \(reason)")
            return
        case .ready(let deletedHouseholdIDs):
            result.deletedHouseholdIDs = deletedHouseholdIDs
        }

        guard let session = householdSession else {
            discardOneShotJWT()
            startFreshState = .failed("Couldn't access the fresh household.")
            return
        }
        let importEpoch = sessionBootEpoch
        result.newHouseholdID = HouseholdZoneProvisioner.householdID(
            fromZoneName: session.zoneID.zoneName)

        func importSessionIsCurrent() -> Bool {
            factoryResetReplacementSessionIsCurrent(
                session,
                requestEpoch: importEpoch,
                resetAccountRecordName: accountRecordName)
        }

        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("The fresh household changed before import.")
            return
        }

        startFreshState = .running(progress: "Importing ingredients…")
        _ = await migrateIngredientsIfNeeded(session: session, apiClient: apiClient)
        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("Household access changed during import.")
            return
        }
        result.ingredientsImported = hasReceipt(scope: "ingredients", session: session)

        startFreshState = .running(progress: "Importing recipes…")
        _ = await migrateRecipesIfNeeded(session: session, apiClient: apiClient)
        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("Household access changed during import.")
            return
        }
        result.recipesImported = hasReceipt(scope: "recipes", session: session)

        startFreshState = .running(progress: "Importing weeks…")
        _ = await migrateWeeksIfNeeded(session: session, apiClient: apiClient)
        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("Household access changed during import.")
            return
        }
        result.weeksImported = hasReceipt(scope: "weeks", session: session)

        startFreshState = .running(progress: "Importing events…")
        _ = await migrateEventsIfNeeded(session: session, apiClient: apiClient)
        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("Household access changed during import.")
            return
        }
        result.eventsImported = hasReceipt(scope: "events", session: session)

        startFreshState = .running(progress: "Importing pantry & profile…")
        await migratePantryProfileIfNeeded(session: session, apiClient: apiClient)
        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("Household access changed during import.")
            return
        }
        if privatePlaneWiped {
            result.pantryProfileImported =
                session.privateStore?.hasMigrationReceipt(scope: "pantry-profile") ?? false
        } else {
            result.warnings.append(
                "Pantry/Profile was NOT re-imported — old private data may remain. "
                    + "Please run Start Fresh again.")
        }

        if privatePlaneWiped {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        guard importSessionIsCurrent() else {
            discardOneShotJWT()
            startFreshState = .failed("Household access changed while finalizing import.")
            return
        }
        _ = privateStore

        discardOneShotJWT()
        startFreshState = .running(progress: "Refreshing your kitchen…")
        await reloadAllRepositoriesAfterImport()
        guard importSessionIsCurrent() else {
            startFreshState = .failed("Household access changed while refreshing.")
            return
        }
        do {
            try factoryResetImportMarkerStore.clear()
        } catch {
            startFreshState = .failed(
                "Reset finished, but its local import receipt couldn't be finalized.")
            return
        }
        startFreshState = .done(result)
    }

    /// The replacement may only continue the reset under the same iCloud account whose
    /// server zones were deleted. `ensureSessionBootOp` resolves identity before constructing
    /// an exact scope, so this check also fences the delete-to-mint account-switch window.
    func factoryResetReplacementSessionIsCurrent(
        _ session: HouseholdSession,
        requestEpoch: Int,
        resetAccountRecordName: String
    ) -> Bool {
        isCurrentAuthoritativeHouseholdSession(
            session,
            requestEpoch: requestEpoch)
            && householdLifecycleGateState() == .absent
            && session.engine.activeMirrorScopeSnapshot?.accountRecordName
                == resetAccountRecordName
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
