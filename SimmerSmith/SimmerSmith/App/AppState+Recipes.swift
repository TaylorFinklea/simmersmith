import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import CloudKit
import CloudKitProvisioning
import HouseholdSync
import HouseholdRecords
import AIProviderKit

/// One-shot import orchestration with an exact-session fence around every continuation
/// effect. The concrete AppState caller supplies the epoch/session predicate and live effects.
@MainActor
struct PantryProfileImportFlow {
    let isCurrentAuthoritative: () -> Bool
    let prepare: () -> Void
    let exchangeToken: () async throws -> String
    let saveImportToken: (String) -> Void
    let migrate: () async -> Void
    let hasMigrationReceipt: () -> Bool
    let publishCompletion: (Bool) -> Void
    let publishSignInFailure: (String) -> Void
    let clearImportToken: () -> Void
    let reloadImportedData: () -> Void

    func run() async {
        guard isCurrentAuthoritative() else { return }
        prepare()

        let token: String
        do {
            token = try await exchangeToken()
        } catch {
            guard isCurrentAuthoritative() else { return }
            publishSignInFailure(error.localizedDescription)
            return
        }

        guard isCurrentAuthoritative() else { return }
        saveImportToken(token)

        await migrate()
        guard isCurrentAuthoritative() else { return }

        let didMigrate = hasMigrationReceipt()
        guard isCurrentAuthoritative() else { return }
        publishCompletion(didMigrate)

        guard isCurrentAuthoritative() else { return }
        clearImportToken()

        guard didMigrate, isCurrentAuthoritative() else { return }
        reloadImportedData()
    }
}

/// Shared continuation fence for the one-shot Week and Event imports. Each
/// post-await effect must still belong to the exact session that began it.
@MainActor
struct WeekEventImportFlow {
    let isCurrentAuthoritative: () -> Bool
    let prepare: () -> Void
    let exchangeToken: () async throws -> String
    let saveImportToken: (String) -> Void
    let migrate: () async -> DeferredMigrationCompletion
    let hasMigrationReceipt: () -> Bool
    let publishCompletion: (Bool) -> Void
    let publishSignInFailure: (String) -> Void
    let clearImportToken: () -> Void
    let reloadImportedData: () -> Void

    func run() async -> DeferredMigrationCompletion {
        guard isCurrentAuthoritative() else { return .retryable }
        prepare()

        let token: String
        do {
            token = try await exchangeToken()
        } catch {
            guard isCurrentAuthoritative() else { return .retryable }
            publishSignInFailure(error.localizedDescription)
            return .retryable
        }

        guard isCurrentAuthoritative() else { return .retryable }
        saveImportToken(token)

        let migrationCompletion = await migrate()
        guard isCurrentAuthoritative() else { return .retryable }
        guard migrationCompletion == .complete else {
            publishCompletion(false)
            return .retryable
        }

        let didMigrate = hasMigrationReceipt()
        guard isCurrentAuthoritative() else { return .retryable }
        publishCompletion(didMigrate)
        guard didMigrate else { return .retryable }

        guard isCurrentAuthoritative() else { return .retryable }
        clearImportToken()

        guard isCurrentAuthoritative() else { return .retryable }
        reloadImportedData()
        return .complete
    }
}
#endif

extension AppState {
    // MARK: - SP-C Task 5: CloudKit lifecycle + mirroring

    #if canImport(CloudKit)
    var shouldSuppressLegacyCacheHydration: Bool {
        cacheFirstLaunchEnabled
            || householdLifecycleGateState() != .absent
            || factoryResetImportMarkerStore.isSet
    }

    var factoryResetImportRequired: Bool {
        factoryResetImportMarkerStore.isSet
    }

    /// Fence for legacy/Fly projection work that began before a lifecycle transition. The
    /// transaction/marker checks prevent a continuation from republishing after durable replay
    /// starts even if its original network request cannot be cancelled.
    func householdProjectionEpochIsCurrent(_ epoch: Int) -> Bool {
        sessionBootEpoch == epoch
            && householdLifecycleGateState() == .absent
            && !factoryResetImportRequired
    }

    func householdLifecycleGateState() -> HouseholdLifecycleGateState {
        do {
            guard let transaction = try householdLifecycleTransactionStore.pending() else {
                return .absent
            }
            return .pending(transaction)
        } catch {
            return .malformed
        }
    }

    /// One gate shared by owner boot, participant boot, share acceptance, and reconciliation.
    /// Malformed bytes are deliberately left untouched for intervention/recovery evidence.
    func householdLifecycleAllowsEntry() -> Bool {
        switch householdLifecycleGateState() {
        case .absent:
            return true
        case .pending:
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Finishing a previous household security transition.")
            return false
        case .malformed:
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "The local household security transition needs attention.")
            return false
        }
    }

    /// The mandatory non-suspending lifecycle choke point. Epoch/readiness/projections move
    /// first; only then are the old session's capabilities and callbacks revoked.
    @discardableResult
    func beginEpochFirstHouseholdTransition(
        clearPersonalData: Bool,
        interventionMessage: String? = nil,
        parkOwnerScopeForAdoption: Bool = false
    ) -> Bool {
        let tearingDownSession = householdSession ?? bootingHouseholdSession

        sessionBootEpoch &+= 1
        householdLaunchPhase = .resolving
        householdAuthority = interventionMessage.map {
            .intervention(message: $0)
        } ?? .none
        detachPublishedHouseholdProjections(clearPersonalData: clearPersonalData)

        cachedPrivatePlaneTask?.cancel()
        cachedPrivatePlaneTask = nil
        tearingDownSession?.revokeAuthority()

        let parkingSucceeded: Bool
        if parkOwnerScopeForAdoption {
            parkingSucceeded = tearingDownSession?.parkForOwnerToParticipantAdoption() ?? true
            if !parkingSucceeded, let tearingDownSession {
                pendingAdoptionParkingSession = tearingDownSession
            }
        } else {
            tearingDownSession?.detach()
            parkingSucceeded = true
        }
        householdSession = nil
        bootingHouseholdSession = nil
        syncStatusCenter.reset()
        AIService.clearSeasonalCache()
        recipeRepository = nil
        metadataRepository = nil
        weekRepository = nil
        groceryRepository = nil
        ingredientRepository = nil
        eventRepository = nil
        guestRepository = nil
        profileRepository = nil
        preferenceRepository = nil
        pantryRepository = nil
        aliasRepository = nil
        aiService = nil
        assistantRepository = nil

        if !parkingSucceeded {
            householdAuthority = .intervention(
                message: "Couldn't safely park the previous household before joining a share.")
        }
        return parkingSucceeded
    }

    private func detachPublishedHouseholdProjections(clearPersonalData: Bool) {
        recipes = []
        recipeMetadata = nil
        recipeMemories = [:]
        currentWeek = nil
        browsedWeek = nil
        exports = []
        checkedGroceryItemIDs = []
        eventSummaries = []
        eventDetails = [:]
        guests = []
        pantryItems = []
        householdAliases = []
        currentHousehold = nil
        pendingLeftoverHouseholdIDs = []
        forkedHouseholdIDs = []

        guard clearPersonalData else { return }
        profile = nil
        ingredientPreferences = []
        assistantThreads = []
        assistantThreadDetails = [:]
        assistantPromptOverrides = [:]
        assistantSendingThreadIDs = []
        assistantErrorByThreadID = [:]
        personalDataReadiness = .unavailable
        aiCapabilities = nil
        aiProviderModeDraft = "auto"
        aiDirectProviderDraft = ""
        aiDirectAPIKeyDraft = ""
        aiOpenAIModelDraft = ""
        aiAnthropicModelDraft = ""
        availableAIModelsByProvider = [:]
        aiModelErrorByProvider = [:]
    }

    func detachLegacyCachedProjections() {
        detachPublishedHouseholdProjections(clearPersonalData: true)
        reminderListIdentifier = nil
        lastReminderSyncAt = nil
        lastReminderSyncSummary = nil
    }

    private func clearLegacyCacheStorageForLifecycle() throws {
        postClearRefreshTask?.cancel()
        postClearRefreshTask = nil
        try cacheStore.clearAll()
        clearReminderMappings()
    }

    private func transaction(
        for event: HouseholdSyncLifecycleEvent,
        scope: MirrorScope?
    ) throws -> HouseholdLifecycleTransaction {
        switch event {
        case .participantRevocation:
            guard let scope,
                  scope.role == .participant,
                  scope.databaseScope == .shared else {
                // No exact identity is selectable. Whole-root retirement is the fail-closed
                // fallback; it never guesses a scope from the zone event.
                return try HouseholdLifecycleTransaction(kind: .accountBoundary, scope: nil)
            }
            return try HouseholdLifecycleTransaction(kind: .participantRevocation, scope: scope)
        case .unexpectedOwnerZoneDeletion:
            guard let scope,
                  scope.role == .owner,
                  scope.databaseScope == .private else {
                return try HouseholdLifecycleTransaction(kind: .accountBoundary, scope: nil)
            }
            return try HouseholdLifecycleTransaction(
                kind: .unexpectedOwnerZoneDeletion,
                scope: scope)
        case .accountBoundary:
            return try HouseholdLifecycleTransaction(kind: .accountBoundary, scope: nil)
        }
    }

    /// Persist one new lifecycle boundary, or atomically upgrade an exact-scope boundary to the
    /// stronger whole-root account boundary. Factory reset and account boundaries are terminal
    /// precedence states and are never overwritten or downgraded.
    private func beginOrUpgradeLifecycleTransaction(
        _ proposed: HouseholdLifecycleTransaction
    ) throws -> HouseholdLifecycleTransaction {
        guard let pending = try householdLifecycleTransactionStore.pending() else {
            try householdLifecycleTransactionStore.begin(proposed)
            return proposed
        }
        if pending.kind == proposed.kind, pending.scope == proposed.scope {
            return pending
        }
        let pendingIsExact = pending.kind == .participantRevocation
            || pending.kind == .unexpectedOwnerZoneDeletion
        if pendingIsExact, proposed.kind == .accountBoundary {
            try householdLifecycleTransactionStore.replace(expected: pending, with: proposed)
            return proposed
        }
        if pending.kind == .accountBoundary {
            return pending
        }
        throw HouseholdLifecycleTransactionStore.Error.transactionConflict
    }

    func requestLifecycleInvalidation(
        for transaction: HouseholdLifecycleTransaction
    ) throws {
        switch transaction.kind {
        case .participantRevocation:
            guard clearParticipantMarker(), let scope = transaction.scope else {
                throw HouseholdLifecycleTransaction.Error.invalidScope
            }
            try householdLifecycleExecutor.requestScopeClear(
                scope,
                householdLifecyclePaths.shadowRootURL)
        case .unexpectedOwnerZoneDeletion:
            guard let scope = transaction.scope else {
                throw HouseholdLifecycleTransaction.Error.invalidScope
            }
            try householdLifecycleExecutor.requestScopeClear(
                scope,
                householdLifecyclePaths.shadowRootURL)
        case .accountBoundary, .factoryReset:
            guard clearParticipantMarker() else {
                throw ParticipantMarkerStore.Error.malformed
            }
            try householdLifecycleExecutor.requestRootClear(
                householdLifecyclePaths.shadowRootURL)
            try householdLifecycleExecutor.clearRoleEngineStateFiles(
                householdLifecyclePaths.directory)
        }
        try clearLegacyCacheStorageForLifecycle()
    }

    /// Called synchronously from the typed HouseholdSession callback. Event and exact scope were
    /// captured before HouseholdSession crossed into a MainActor Task.
    @discardableResult
    func handleHouseholdLifecycleEvent(
        _ event: HouseholdSyncLifecycleEvent,
        scope: MirrorScope?,
        scheduleReplay: Bool = true
    ) -> Bool {
        if case .unexpectedOwnerZoneDeletion = event,
           case .pending(let pending) = householdLifecycleGateState(),
           pending.kind == .factoryReset {
            return false
        }

        let clearPersonal: Bool
        if case .accountBoundary = event {
            clearPersonal = true
        } else {
            clearPersonal = false
        }
        beginEpochFirstHouseholdTransition(
            clearPersonalData: clearPersonal,
            interventionMessage: "Finishing a household security transition.")

        do {
            let effective = try beginOrUpgradeLifecycleTransaction(
                transaction(for: event, scope: scope))
            try requestLifecycleInvalidation(for: effective)
        } catch {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Couldn't safely invalidate the previous household: \(error.localizedDescription)")
            return false
        }

        if scheduleReplay {
            schedulePendingHouseholdLifecycleReplay()
        }
        return true
    }

    func schedulePendingHouseholdLifecycleReplay() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            var outcome: HouseholdLifecycleReplayOutcome?
            await self.sessionBootQueue.enqueue { [weak self] in
                outcome = await self?.completePendingHouseholdLifecycleBoundary()
            }.value
            guard outcome == .unexpectedOwnerZoneDeletion else { return }
            await self.ensureHouseholdSession()
        }
    }

    func replayPendingHouseholdLifecycleBeforeEntry() async {
        let requestEpoch = sessionBootEpoch
        await sessionBootQueue.enqueue { [weak self] in
            guard let self, self.sessionBootEpoch == requestEpoch else { return }
            _ = await self.completePendingHouseholdLifecycleBoundary()
        }.value
    }

    /// Delete reset-owned server zones only while both the app transaction and CloudKit account
    /// remain the exact boundary that authorized the operation. The provisioner independently
    /// repeats this account check around enumeration/modification; the post-return lookup fences
    /// transaction completion and replacement minting if identity changed during the await.
    func deleteFactoryResetZonesBoundToAccount(
        transaction: HouseholdLifecycleTransaction,
        isCurrent: () -> Bool
    ) async throws -> [String] {
        guard transaction.kind == .factoryReset,
              let expectedAccountRecordName = transaction.remoteAccountRecordName,
              isCurrent() else {
            throw HouseholdLifecycleTransactionStore.Error.transactionConflict
        }
        let accountBeforeDeletion = try await
            householdLifecycleExecutor.currentAccountRecordName()
        guard isCurrent(), accountBeforeDeletion == expectedAccountRecordName else {
            throw HouseholdLifecycleTransaction.Error.invalidRemoteAccount
        }
        let deleted = try await householdLifecycleExecutor.deleteAllHouseholdZones(
            expectedAccountRecordName)
        guard isCurrent() else {
            throw HouseholdLifecycleTransactionStore.Error.transactionConflict
        }
        let accountAfterDeletion = try await
            householdLifecycleExecutor.currentAccountRecordName()
        guard isCurrent(), accountAfterDeletion == expectedAccountRecordName else {
            throw HouseholdLifecycleTransaction.Error.invalidRemoteAccount
        }
        return deleted
    }

    /// Runs inside the serialized boot lane (or directly in deterministic tests). A valid file is
    /// replayed idempotently; malformed bytes remain intact and block every successor session.
    func completePendingHouseholdLifecycleBoundary() async -> HouseholdLifecycleReplayOutcome? {
        let pending: HouseholdLifecycleTransaction
        switch householdLifecycleGateState() {
        case .absent:
            if factoryResetImportRequired {
                startFreshState = .failed(
                    "CloudKit was reset. Run Start Fresh again to restore your Fly data.")
            }
            return nil
        case .malformed:
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "The local household security transition needs attention.")
            return nil
        case .pending(let transaction):
            pending = transaction
        }

        if householdSession != nil {
            beginEpochFirstHouseholdTransition(
                clearPersonalData: pending.kind == .accountBoundary || pending.kind == .factoryReset,
                interventionMessage: "Finishing a previous household security transition.")
        }
        let replayEpoch = sessionBootEpoch

        func transactionStillCurrent() -> Bool {
            guard sessionBootEpoch == replayEpoch else { return false }
            return (try? householdLifecycleTransactionStore.pending()) == pending
        }

        do {
            guard transactionStillCurrent() else {
                throw HouseholdLifecycleTransactionStore.Error.transactionConflict
            }
            try requestLifecycleInvalidation(for: pending)
            switch pending.kind {
            case .participantRevocation, .unexpectedOwnerZoneDeletion:
                guard let scope = pending.scope else {
                    throw HouseholdLifecycleTransaction.Error.invalidScope
                }
                try householdLifecycleExecutor.completeScopeClear(
                    scope,
                    householdLifecyclePaths.shadowRootURL)
            case .accountBoundary, .factoryReset:
                try householdLifecycleExecutor.completeRootClear(
                    householdLifecyclePaths.shadowRootURL)
            }

            if pending.kind == .factoryReset {
                _ = try await deleteFactoryResetZonesBoundToAccount(
                    transaction: pending,
                    isCurrent: transactionStillCurrent)
                try factoryResetImportMarkerStore.set()
            }
            guard transactionStillCurrent() else {
                throw HouseholdLifecycleTransactionStore.Error.transactionConflict
            }
            try householdLifecycleTransactionStore.complete(pending)
        } catch {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Couldn't finish the household security transition: \(error.localizedDescription)")
            if pending.kind == .factoryReset {
                startFreshState = .failed(
                    "Couldn't erase CloudKit households: \(error.localizedDescription)")
            }
            return nil
        }

        switch pending.kind {
        case .accountBoundary:
            householdAuthority = .none
            return .accountBoundary
        case .participantRevocation:
            householdAuthority = .intervention(
                message: "Access to the shared household changed. Reconnecting…")
            return .participantRevocation
        case .unexpectedOwnerZoneDeletion:
            householdAuthority = .none
            return .unexpectedOwnerZoneDeletion
        case .factoryReset:
            householdAuthority = .none
            startFreshState = .failed(
                "CloudKit was reset. Run Start Fresh again to restore your Fly data.")
            return .factoryResetNeedsImport
        }
    }

    /// Construct the CloudKit household session + repositories once the household
    /// ID is known (from the Fly household snapshot). Idempotent — no-op if a
    /// session already exists. Called from `refreshAll()` after `refreshHousehold()`.
    ///
    /// Re-entrancy (simmersmith-0gf): this is only one of TWO entry points that can boot a
    /// household session — the other is `processPendingShare()` (a share-accept boot from an
    /// independent task, e.g. the warm-tap scene-delegate callback). Both entry points enqueue
    /// their work on `sessionBootQueue` (a strict FIFO), so an in-flight owner boot and a
    /// share-accept boot never interleave at suspension points and race on which session wins.
    /// The queued op re-checks `householdSession != nil` after its predecessors finish — that
    /// re-check (not a dedup flag) is what makes a chained-but-now-redundant boot no-op.
    func ensureHouseholdSession() async {
        let requestEpoch = sessionBootEpoch
        await sessionBootQueue.enqueue { [weak self] in
            guard let self, self.sessionBootEpoch == requestEpoch else { return }
            _ = await self.completePendingHouseholdLifecycleBoundary()
            guard self.householdLifecycleAllowsEntry() else { return }
            await self.ensureSessionBootOp(requestEpoch: self.sessionBootEpoch)
        }.value
    }

    /// The body of an owner-boot session op, run strictly serialized (after any
    /// preceding boot) inside `sessionBootQueue`. See `ensureHouseholdSession()`.
    func ensureSessionBootOp(
        requestEpoch: Int,
        expectedAccountRecordName: String? = nil
    ) async {
        // simmersmith-0gf blocking-finding fix: this op was enqueued behind (possibly
        // several) predecessors — if a sign-out (`teardownHouseholdSession`) bumped the
        // epoch while this request was waiting its turn, the request is stale: abort before
        // touching anything rather than re-booting a session the user just tore down.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry() else { return }

        // Re-check AFTER predecessors have run — this is the whole point of doing the check
        // here rather than only in the outer function: a preceding share-accept boot may have
        // just installed a participant session, and this chained ensure must no-op rather than
        // fall through to owner discovery/mint.
        if let session = householdSession {
            if CachedForegroundRetryPolicy.shouldRetry(
                hasCachedSession: session.isCachedBootstrap,
                authority: householdAuthority,
                hasPendingDeferredSystemWork: session.hasPendingDeferredSystemWork) {
                await retryCachedHouseholdReconciliationOp(
                    requestEpoch: requestEpoch,
                    onlyIfNeeded: true)
            } else if householdLaunchPhase != .resolving {
                householdLaunchPhase = .ready
            }
            return
        }
        // SP-C identity slice (spec §1.2): the household id no longer comes from Fly
        // (`currentHousehold?.householdId`) — it is DISCOVERED from CloudKit, or minted
        // if the user has no household zone yet. Resolution is async (it lists the
        // private DB's zones), so it happens here rather than as a pre-task guard. The
        // discover-before-create ordering is load-bearing (spec §7): minting a new zone
        // when `household-<existingId>` already exists would orphan the migrated recipes.
        // P2e resolves the account identity before selecting any cached scope.
        let accountRecordName = try? await householdLifecycleExecutor.currentAccountRecordName()
        // Every engine, including the gate-off nil-state control, receives an exact scope before
        // automatic sync starts. Unknown identity cannot construct a session or trust a marker.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              let accountRecordName,
              !accountRecordName.isEmpty else {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Couldn't verify the current iCloud account.")
            return
        }
        guard expectedAccountRecordName == nil
                || accountRecordName == expectedAccountRecordName else {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "The iCloud account changed before household setup completed.")
            return
        }

        // PARTICIPANT-FIRST (accept-before-mint, sharing spec §6): if the user just
        // accepted a share (PendingShareInbox) or has a saved participant marker, this
        // device ADOPTS an owner's household — boot as participant and NEVER fall through
        // to owner discovery/mint (which would orphan-mint a solo zone on a cold accept).
        if let metadata = PendingShareInbox.shared.take() {
            await bootParticipantSession(
                accepting: metadata,
                requestEpoch: requestEpoch,
                accountRecordName: accountRecordName)
            return
        }
        do {
            if let marker = try loadParticipantMarker(accountRecordName: accountRecordName) {
                await bootParticipantSession(
                    reusing: marker,
                    requestEpoch: requestEpoch,
                    accountRecordName: accountRecordName)
                return
            }
        } catch {
            _ = handleHouseholdLifecycleEvent(
                .accountBoundary(.switchedAccounts),
                scope: nil)
            return
        }

        // 1. Resolve the household id: discover first, mint only if none exists. A verified
        // cached candidate may bypass the zone census because its exact scope is already named.
        let cachedCandidate: MirrorBootstrapCandidate?
        let recoveryCandidate: MirrorRecoveryCandidate?
        if cacheFirstLaunchEnabled {
            let selection = bootstrapSelection(
                accountRecordName: accountRecordName,
                request: .owner(accountRecordName: accountRecordName),
                expectedRole: .owner,
                expectedZone: nil)
            cachedCandidate = selection.cachedCandidate
            recoveryCandidate = selection.recoveryCandidate
        } else {
            cachedCandidate = nil
            recoveryCandidate = nil
        }
        let householdID: String?
        if let cachedHouseholdID = cachedCandidate?.bootstrap.scope.householdID {
            householdID = cachedHouseholdID
        } else if let recoveryHouseholdID = recoveryCandidate?.plan.scope.householdID {
            householdID = recoveryHouseholdID
        } else {
            householdID = await resolveHouseholdID(requestEpoch: requestEpoch)
        }
        guard let householdID else {
            // Discovery failed. The specific phase (.iCloudUnavailable vs .resolving)
            // was already set inside resolveHouseholdID() before returning nil. Leave
            // the session unset so a later retry can call ensureHouseholdSession() again.
            return
        }
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry() else { return }

        let session: HouseholdSession
        do {
            session = try HouseholdSession(
                householdID: householdID,
                initialMirrorScope: MirrorScope(
                    accountRecordName: accountRecordName,
                    zoneOwnerName: CKCurrentUserDefaultName,
                    zoneName: HouseholdZoneProvisioner.zoneName(householdID: householdID),
                    householdID: householdID,
                    role: .owner,
                    databaseScope: .private),
                syncStatusCenter: self.syncStatusCenter,
                bootstrapCandidate: cachedCandidate,
                recoveryCandidate: recoveryCandidate)
        } catch {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Couldn't establish an exact household cache identity.")
            return
        }
        bootingHouseholdSession = session
        installLifecycleDispatcher(for: session, epoch: requestEpoch)
        guard sessionBootEpoch == requestEpoch, householdLifecycleAllowsEntry() else {
            bootingHouseholdSession = nil
            session.detach()
            return
        }
        await session.start()

        // Recovery-only durable intents may overlay only after a successful nil-state full
        // fetch. A transient failure keeps the exact plan recoverable but cannot wire or render.
        guard householdLifecycleAllowsEntry(),
              !session.isRecoveryOnly || session.recoveryOnlyFetchSucceeded else {
            if bootingHouseholdSession === session { bootingHouseholdSession = nil }
            session.detach()
            return
        }
        guard householdLifecycleAllowsEntry(),
              DirectHouseholdBootstrapPolicy.shouldContinueAfterInitialStart(
            isCachedBootstrap: session.isCachedBootstrap,
            hasCurrentAuthority: session.hasCurrentAuthority
        ) else {
            if bootingHouseholdSession === session { bootingHouseholdSession = nil }
            session.detach()
            return
        }

        // simmersmith-7in: re-check after session.start() — a teardown mid-provisioning must
        // not fall through into the migration writes below (they would land in the PRIOR
        // user's household zone). Detach what start() built rather than migrating into it.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry() else {
            if bootingHouseholdSession === session { bootingHouseholdSession = nil }
            session.detach()
            return
        }

        // Cached content is wired and published before its first reconciliation. P2e keeps
        // migration/repair/week-creation entry points denied for this entire session.
        if session.isCachedBootstrap {
            await wireHouseholdRepositories(session: session, requestEpoch: requestEpoch)
            guard sessionBootEpoch == requestEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === session else {
                session.detach()
                return
            }
            publishCachedHouseholdAuthority(session: session, epoch: requestEpoch)
            guard sessionBootEpoch == requestEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === session else { return }
            householdLaunchPhase = .ready
            scheduleCachedPrivatePlaneOpen(session: session, requestEpoch: requestEpoch)
            scheduleCachedReconciliation(session: session, requestEpoch: requestEpoch)
            return
        }

        // Import household-owned catalog rows before recipes so any preserved
        // ingredient links already have canonical targets when recipes hydrate.
        await migrateIngredientsIfNeeded(session: session, apiClient: apiClient)

        // simmersmith-7in: re-check between the two migrations — same hazard as above; a
        // teardown during ingredient migration must not fall through into the recipe migration.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry() else {
            session.detach()
            return
        }

        // SP-C Task 6: one-time first-launch recipe migration Fly→CloudKit.
        // Receipt-gated (idempotent) — safe to call every launch. Runs after
        // session.start() (zone provisioned + first fetch done) and before
        // recipeRepo.reload() so a new install hydrates CloudKit before the
        // first read. The migration is a no-op once the "recipes" receipt is
        // present in the local store.
        await migrateRecipesIfNeeded(session: session, apiClient: apiClient)

        // simmersmith-0gf blocking-finding fix: re-check right before the commit point — a
        // sign-out could have landed during any of the awaits above. Detach (don't wire) a
        // session built for a now-stale request rather than resurrecting it post-teardown.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry() else {
            session.detach()
            return
        }

        await wireHouseholdRepositories(session: session, requestEpoch: requestEpoch)

        // simmersmith-7in: wireHouseholdRepositories may have already aborted internally
        // (stale epoch after its own await) — don't let this redundant flip resurrect .ready,
        // and don't schedule the leftover-household sweep for a session we just tore down.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else { return }
        installAuthorityDispatcher(for: session, epoch: requestEpoch)
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else { return }

        // SP-C identity slice (spec §1.3): signal RootView that the household is
        // resolved and the app is ready to show MainTabView.
        publishDirectHouseholdAuthority(session: session, epoch: requestEpoch)
        personalDataReadiness = session.privateStore == nil ? .unavailable : .ready
        householdLaunchPhase = .ready

        // simmersmith-auc: sweep the leftover empty households from earlier builds. Kicked
        // AFTER .ready and detached — a destructive CloudKit pass must never be on the path
        // that opens the kitchen. No-ops unless discovery actually saw extra zones.
        scheduleLeftoverHouseholdCleanup(keeping: householdID)
    }

    /// Build + wire all repositories for a booted session (OWNER or PARTICIPANT). The caller
    /// alone publishes authority and `.ready` after this returns, so cached content never has a
    /// visible authority-`.none` frame. Owner-only steps (current-week creation) are gated on
    /// the session role so a participant adopts the owner's weeks.
    ///
    /// `requestEpoch` (simmersmith-7in): the caller's epoch snapshot is re-checked after this
    /// function's one await (`ensureCurrentCloudKitWeek`). `householdSession = session` below
    /// commits synchronously before that await; a stale request must stop before the caller
    /// publishes authority or launch readiness.
    func wireHouseholdRepositories(session: HouseholdSession, requestEpoch: Int) async {
        let recipeRepo = RecipeRepository(session: session)
        let metadataRepo = MetadataRepository(session: session)
        let weekRepo = WeekRepository(session: session)
        let groceryRepo = GroceryRepository(session: session)
        let ingredientRepo = IngredientRepository(session: session)
        let guestRepo = GuestRepository(session: session)
        let eventRepo = EventRepository(session: session, guests: guestRepo)
        let profileRepo = ProfileRepository(session: session)
        let preferenceRepo = PreferenceRepository(session: session)
        let pantryRepo = PantryRepository(session: session)
        let aliasRepo = AliasRepository(session: session)
        let aiSvc = AIService(session: session)
        let assistantRepo = AssistantRepository(session: session)

        householdSession = session
        if bootingHouseholdSession === session { bootingHouseholdSession = nil }
        recipeRepository = recipeRepo
        metadataRepository = metadataRepo
        weekRepository = weekRepo
        groceryRepository = groceryRepo
        ingredientRepository = ingredientRepo
        guestRepository = guestRepo
        eventRepository = eventRepo
        profileRepository = profileRepo
        preferenceRepository = preferenceRepo
        pantryRepository = pantryRepo
        aliasRepository = aliasRepo
        aiService = aiSvc
        assistantRepository = assistantRepo

        // Initial kick — the repos auto-reload on session.storeRevision, but need a first
        // read after construction.
        recipeRepo.startObserving()
        metadataRepo.startObserving()
        weekRepo.startObserving()
        ingredientRepo.startObserving()
        guestRepo.startObserving()
        eventRepo.startObserving()
        pantryRepo.startObserving()
        aliasRepo.startObserving()
        recipeRepo.reload()
        metadataRepo.reloadMetadata()
        weekRepo.reload()
        ingredientRepo.reload()
        guestRepo.reload()
        eventRepo.reload()
        pantryRepo.reload()
        aliasRepo.reload()
        profileRepo.reload()
        preferenceRepo.reload()

        observeRecipeRepository()
        observeMetadataRepository()
        observeWeekRepository()
        observeEventRepository()
        observePantryRepository()
        observeAliasRepository()
        observeProfileRepository()
        observePreferenceRepository()
        mirrorRecipesFromRepository()
        mirrorMetadataFromRepository()
        mirrorWeekFromRepository()
        // The OWNER owns the current week (create today's if none covers it, carrying over
        // in-memory meals). A PARTICIPANT adopts the owner's weeks — it must NOT auto-create
        // (that would race the first shared fetch and could fork a duplicate week).
        if session.role.isOwner,
           CachedHouseholdSystemOperationPolicy.allows(
            .currentWeekCreation,
            isAuthoritative: session.hasCurrentAuthority) {
            _ = await ensureCurrentCloudKitWeek(session: session, requestEpoch: requestEpoch)
        }

        // simmersmith-7in blocking-finding fix: re-check after this function's one await — a
        // sign-out during ensureCurrentCloudKitWeek() clears householdSession/repos and sets
        // .resolving; don't let this stale op overwrite that back to .ready.
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else { return }

        mirrorEventsFromRepository()
        mirrorGuestsFromRepository()
        mirrorPantryFromRepository()
        mirrorAliasesFromRepository()
        mirrorProfileFromRepository()
        mirrorPreferencesFromRepository()
        syncAIDraftsFromRepo()
        loadAssistantPromptOverrides()

    }

    struct BootstrapSelection {
        let cachedCandidate: MirrorBootstrapCandidate?
        let recoveryCandidate: MirrorRecoveryCandidate?
    }

    /// Opens the catalog exactly once and transfers the one returned writer/lease into one
    /// terminal launch outcome. Ineligible-but-valid bytes are fenced and released (not
    /// quarantined); catalog-detected corruption remains the catalog's exact-scope concern.
    func bootstrapSelection(
        accountRecordName: String,
        request: MirrorBootstrapRequest,
        expectedRole: MirrorRole,
        expectedZone: MirrorZoneReference?
    ) -> BootstrapSelection {
        let root = householdLifecyclePaths.shadowRootURL
        let result = ShadowMirrorBootstrapCatalog.open(request: request, rootDirectory: root)
        switch result.outcome {
        case .none:
            return BootstrapSelection(cachedCandidate: nil, recoveryCandidate: nil)
        case .cached(let bootstrap, let writer):
            let zone = expectedZone ?? MirrorZoneReference(
                ownerName: bootstrap.scope.zoneOwnerName,
                zoneName: bootstrap.scope.zoneName)
            let expected = MirrorBootstrapExpectedIdentity(
                accountRecordName: accountRecordName,
                role: expectedRole,
                zone: zone,
                participantMarkerZone: expectedRole == .participant ? expectedZone : nil)
            guard bootstrap.scope.accountRecordName == accountRecordName,
                  bootstrap.scope.role == expectedRole,
                  bootstrap.scope.zoneOwnerName == zone.ownerName,
                  bootstrap.scope.zoneName == zone.zoneName else {
                writer.releaseGenerationLeaseSynchronously(bootstrap.lease.id)
                writer.fenceSynchronously()
                return BootstrapSelection(cachedCandidate: nil, recoveryCandidate: nil)
            }
            return BootstrapSelection(
                cachedCandidate: MirrorBootstrapCandidate(
                    bootstrap: bootstrap, writer: writer, expectedIdentity: expected),
                recoveryCandidate: nil)
        case .recoveryOnly(let plan, let writer):
            let zoneMatches: Bool
            if let expectedZone {
                zoneMatches = plan.scope.zoneOwnerName == expectedZone.ownerName
                    && plan.scope.zoneName == expectedZone.zoneName
            } else {
                zoneMatches = plan.scope.role == expectedRole
            }
            guard plan.scope.accountRecordName == accountRecordName,
                  plan.scope.role == expectedRole,
                  zoneMatches else {
                writer.releaseGenerationLeaseSynchronously(plan.lease.id)
                writer.fenceSynchronously()
                return BootstrapSelection(cachedCandidate: nil, recoveryCandidate: nil)
            }
            return BootstrapSelection(
                cachedCandidate: nil,
                recoveryCandidate: MirrorRecoveryCandidate(plan: plan, writer: writer))
        }
    }

    func installAuthorityDispatcher(for session: HouseholdSession, epoch: Int) {
        session.onAuthorityEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.dispatchHouseholdAuthority(event, epoch: epoch, session: session)
        }
    }

    /// Installed immediately after construction and before `start()`. This is intentionally
    /// separate from ordinary authority buffering: cached-ready remains the authority baseline,
    /// while account/revocation/zone-deletion must never wait behind repository publication.
    func installLifecycleDispatcher(for session: HouseholdSession, epoch: Int) {
        let sourceID = session.lifecycleSourceID
        session.onLifecycleEvent = { [weak self, weak session] snapshot in
            guard let self else { return }
            let sourceIsCurrent = session.map {
                epoch == self.sessionBootEpoch
                    && (self.householdSession === $0
                        || self.bootingHouseholdSession === $0)
            } ?? false
            guard sourceIsCurrent
                    || self.acceptedRetiredLifecycleSourceIDs.contains(sourceID) else { return }
            self.acceptedRetiredLifecycleSourceIDs.insert(sourceID)
            self.handleHouseholdLifecycleEvent(
                snapshot.event,
                scope: snapshot.scope)
            if case .accountBoundary = snapshot.event {
                self.acceptedRetiredLifecycleSourceIDs.remove(sourceID)
            }
        }
    }

    /// Establish the cached baseline before installing the dispatcher. Installing drains every
    /// construction-time engine callback synchronously; reversing these two steps would let a
    /// later `.cachedReady` overwrite an already-buffered pending state.
    func publishCachedHouseholdAuthority(session: HouseholdSession, epoch: Int) {
        dispatchHouseholdAuthority(.cachedReady(.now), epoch: epoch, session: session)
        installAuthorityDispatcher(for: session, epoch: epoch)
        guard session.cachedInterventionCount > 0 else { return }
        let count = session.cachedInterventionCount
        let noun = count == 1 ? "change" : "changes"
        let verb = count == 1 ? "needs" : "need"
        dispatchHouseholdAuthority(
            .intervention("\(count) cached \(noun) \(verb) attention."),
            epoch: epoch,
            session: session)
    }

    func dispatchHouseholdAuthority(
        _ event: HouseholdAuthorityEvent,
        epoch: Int,
        session: HouseholdSession
    ) {
        householdAuthority = HouseholdAuthorityReducer.reduce(
            householdAuthority,
            event: event,
            epoch: epoch,
            currentEpoch: sessionBootEpoch,
            sessionMatches: householdSession === session)
    }

    /// Publish direct/recovery authority in one verified order. Keeping this separate from
    /// launch readiness preserves P1's content timing while preventing an offline start from
    /// advertising `.current` authority.
    func publishDirectHouseholdAuthority(
        session: HouseholdSession,
        epoch: Int
    ) {
        let isSynchronized: Bool
        if case .synced = session.syncPhase {
            isSynchronized = true
        } else {
            isSynchronized = false
        }
        for event in DirectHouseholdAuthorityPlan.events(
            isSynchronized: isSynchronized,
            pendingCount: session.engine.pendingRecordChangeCount,
            interventionCount: session.cachedInterventionCount,
            now: .now) {
            dispatchHouseholdAuthority(event, epoch: epoch, session: session)
        }
    }

    func reloadPrivatePlaneIfCurrent(session: HouseholdSession, requestEpoch: Int) {
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else { return }
        profileRepository?.reload()
        preferenceRepository?.reload()
        mirrorProfileFromRepository()
        mirrorPreferencesFromRepository()
        syncAIDraftsFromRepo()
        loadAssistantPromptOverrides()
    }

    /// Cached household readiness is published before this intentionally deferred main-actor
    /// turn. Creating the SwiftData container can synchronously block, so opening it directly
    /// after `.ready` would still prevent SwiftUI from rendering the cached household first.
    func scheduleCachedPrivatePlaneOpen(session: HouseholdSession, requestEpoch: Int) {
        cachedPrivatePlaneTask?.cancel()
        personalDataReadiness = .loading
        cachedPrivatePlaneTask = Task { @MainActor [weak self, weak session] in
            await Task.yield()
            guard !Task.isCancelled, let self, let session,
                  self.sessionBootEpoch == requestEpoch,
                  self.householdLifecycleAllowsEntry(),
                  self.householdSession === session else { return }
            session.openPrivatePlane()
            guard !Task.isCancelled,
                  self.sessionBootEpoch == requestEpoch,
                  self.householdLifecycleAllowsEntry(),
                  self.householdSession === session else { return }
            self.reloadPrivatePlaneIfCurrent(session: session, requestEpoch: requestEpoch)
            self.personalDataReadiness = session.privateStore == nil ? .unavailable : .ready
        }
    }

    /// Reconciliation always enters through the boot queue so a foreground retry cannot
    /// overlap a participant adoption or another boot. There is no user-visible control here.
    func retryCachedHouseholdReconciliation(onlyIfNeeded: Bool = false) async {
        let requestEpoch = sessionBootEpoch
        await sessionBootQueue.enqueue { [weak self] in
            guard let self, self.sessionBootEpoch == requestEpoch else { return }
            _ = await self.completePendingHouseholdLifecycleBoundary()
            guard self.householdLifecycleAllowsEntry() else { return }
            await self.retryCachedHouseholdReconciliationOp(
                requestEpoch: self.sessionBootEpoch,
                onlyIfNeeded: onlyIfNeeded)
        }.value
    }

    func scheduleCachedReconciliation(session: HouseholdSession, requestEpoch: Int) {
        Task { @MainActor [weak self, weak session] in
            guard let self, let session,
                  self.sessionBootEpoch == requestEpoch,
                  self.householdLifecycleAllowsEntry(),
                  self.householdSession === session else { return }
            await self.retryCachedHouseholdReconciliation()
        }
    }

    private func retryCachedHouseholdReconciliationOp(
        requestEpoch: Int,
        onlyIfNeeded: Bool
    ) async {
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              let session = householdSession,
              session.isCachedBootstrap else { return }
        guard !onlyIfNeeded || CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: true,
            authority: householdAuthority,
            hasPendingDeferredSystemWork: session.hasPendingDeferredSystemWork) else { return }
        if CachedHouseholdRetryPlan.next(
            hasCurrentAuthority: session.hasCurrentAuthority,
            hasPendingDeferredSystemWork: session.hasPendingDeferredSystemWork
        ) == .resumeDeferredSystemWork {
            await runDeferredCachedSystemWork(session: session, requestEpoch: requestEpoch)
            return
        }
        dispatchHouseholdAuthority(.retry(.now), epoch: requestEpoch, session: session)
        let outcome = await session.reconcileCachedHousehold()
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else { return }
        switch outcome {
        case .succeeded(let pendingCount):
            // The fetch completed, but only the exact session that began it may cross the
            // destructive/system boundary. A stale completion after teardown is a no-op.
            let promoted = session.promoteCachedAuthority()
            guard promoted || session.hasCurrentAuthority else { return }
            dispatchHouseholdAuthority(.reconciliationSucceeded(.now), epoch: requestEpoch, session: session)
            // A pending callback may have preceded success; publish the exact final count after
            // success so `.current` never overwrites unresolved local work.
            dispatchHouseholdAuthority(.pending(count: pendingCount), epoch: requestEpoch, session: session)
            await runDeferredCachedSystemWork(session: session, requestEpoch: requestEpoch)
        case .failed:
            dispatchHouseholdAuthority(.reconciliationFailed("offline"), epoch: requestEpoch, session: session)
        }
    }

    /// The P1 direct path already runs this tail before wiring. A cached session defers it until
    /// its first exact reconciliation succeeds, then owns it once for its remaining lifetime.
    private func runDeferredCachedSystemWork(
        session: HouseholdSession,
        requestEpoch: Int
    ) async {
        while let stage = session.claimNextDeferredSystemWorkStage() {
            guard sessionBootEpoch == requestEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === session,
                  session.hasCurrentAuthority else {
                session.abandonDeferredSystemWorkStage(stage)
                return
            }
            switch stage {
            case .ingredientsMigration:
                guard await migrateIngredientsIfNeeded(session: session, apiClient: apiClient) == .complete else {
                    session.abandonDeferredSystemWorkStage(stage)
                    return
                }
            case .recipesMigration:
                guard await migrateRecipesIfNeeded(session: session, apiClient: apiClient) == .complete else {
                    session.abandonDeferredSystemWorkStage(stage)
                    return
                }
            case .ownerCurrentWeek:
                if session.role.isOwner {
                    guard await ensureCurrentCloudKitWeek(
                        session: session,
                        requestEpoch: requestEpoch
                    ) == .allowed else {
                        session.abandonDeferredSystemWorkStage(stage)
                        return
                    }
                }
            case .projectionReload:
                recipeRepository?.reload()
                metadataRepository?.reloadMetadata()
                weekRepository?.reload()
                eventRepository?.reload()
                pantryRepository?.reload()
                mirrorRecipesFromRepository()
                mirrorMetadataFromRepository()
                mirrorWeekFromRepository()
                mirrorEventsFromRepository()
                mirrorPantryFromRepository()
            case .repairActivation:
                session.repairScheduler.activate()
            case .leftoverCleanup:
                scheduleLeftoverHouseholdCleanup(keeping: session.householdID)
            }
            guard sessionBootEpoch == requestEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === session,
                  session.hasCurrentAuthority else {
                session.abandonDeferredSystemWorkStage(stage)
                return
            }
            session.completeDeferredSystemWorkStage(stage)
        }
    }

    /// True when a foreground App lifecycle event must route through the serialized cached
    /// retry rather than treating visible cached content as a finished session.
    var shouldRetryCachedHouseholdOnForeground: Bool {
        CachedForegroundRetryPolicy.shouldRetry(
            hasCachedSession: householdSession?.isCachedBootstrap == true,
            authority: householdAuthority,
            hasPendingDeferredSystemWork: householdSession?.hasPendingDeferredSystemWork == true)
    }

    /// SP-C identity slice (spec §1.2): resolve the CloudKit household id with NO Fly
    /// call. Discover first (zone listing); mint a fresh household only when none exists.
    ///
    /// Returns `nil` when resolution can't complete (discovery threw — e.g. iCloud
    /// unavailable / transient CloudKit error — OR minting threw). The caller leaves the
    /// session unset so a later refresh retries; it must NOT fall through to minting on a
    /// discovery error, which would orphan an existing `household-<id>` zone (spec §7).
    private func resolveHouseholdID(requestEpoch: Int) async -> String? {
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
        // simmersmith-7in: re-check after the accountStatus await, before writing the launch
        // phase below — a teardown during that await must not have this stale request flip
        // .iCloudUnavailable back over the sign-out's .resolving.
        guard sessionBootEpoch == requestEpoch else { return nil }
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
            // simmersmith-7in: re-check before writing the phase below — same hazard as the
            // preflight guard above, and this await can run several seconds of internal backoff.
            guard sessionBootEpoch == requestEpoch else { return nil }
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
        // simmersmith-7in: re-check before the ambiguous check + pendingLeftoverHouseholdIDs
        // write below — discoverWithZeroZoneRetry can run ~4.5s of backoff internally.
        guard sessionBootEpoch == requestEpoch else { return nil }

        // Ambiguous: multiple household zones, none provably populated (finding A). Do NOT
        // alphabetical-guess into an unproven zone — surface an error and stay resolving so
        // a later retry (foreground) can re-probe once propagation/repair settles.
        if result.isAmbiguous {
            lastErrorMessage = "Found \(result.ignoredHouseholdIDs.count) CloudKit households "
                + "but couldn't confirm which holds your data. Will retry."
            return nil
        }

        // Multiple household zones — discovery picked the data-RICHEST (the zone holding your
        // recipes/data); the rest are stale mints from earlier builds' repeated minting.
        //
        // simmersmith-auc: these used to raise a banner ("Found N leftover empty household(s)
        // — harmless") on `lastErrorMessage` — the ERROR channel, warning triangle and all —
        // which is a nag, not a fix, and its copy was wrong besides: "ignored" means NOT CHOSEN,
        // not empty (a tie-break loser is ignored while holding every one of its records). So
        // hand the ids to the post-launch cleanup pass instead of to the user; it re-censuses
        // each zone and deletes only the ones it can PROVE are empty.
        pendingLeftoverHouseholdIDs = result.ignoredHouseholdIDs

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
            // simmersmith-7in: re-check before writing the phase below — same hazard as the
            // other catch blocks in this function.
            guard sessionBootEpoch == requestEpoch else { return nil }
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

    /// Retry only the retained owner writer whose adoption parking failed. A participant
    /// successor remains blocked until this same writer persists its parking marker.
    func completePendingShadowRootRetirementIfNeeded() -> Bool {
        if let session = pendingAdoptionParkingSession {
            guard session.parkForOwnerToParticipantAdoption() else { return false }
            pendingAdoptionParkingSession = nil
        }
        return true
    }

    /// Tear down the CloudKit session + repositories and delete the durable engine
    /// state so a different household signed in on this device cannot inherit the
    /// prior sync token. Called from sign-out (`clearHouseholdContext`).
    @discardableResult
    func teardownHouseholdSession(
        clearShadowRoot: Bool = true,
        parkOwnerScopeForAdoption: Bool = false
    ) -> Bool {
        if clearShadowRoot {
            return handleHouseholdLifecycleEvent(
                .accountBoundary(.signedOut),
                scope: nil)
        }
        return beginEpochFirstHouseholdTransition(
            clearPersonalData: false,
            parkOwnerScopeForAdoption: parkOwnerScopeForAdoption)
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

        // Resolve currentWeek: the week whose [weekStart, weekStart+7) CONTAINS today
        // (UTC) — not merely one that starts exactly today, so a mid-week launch still
        // resolves the active week. PREFER the Monday-aligned (canonical) week so a stray
        // mis-aligned artifact still syncing never shadows the real week.
        let today = Date()
        let coveringToday = all.first(where: { WeekBoundary.weekContains($0.weekStart, day: today) && WeekBoundary.isMonday($0.weekStart) })
            ?? all.first(where: { WeekBoundary.weekContains($0.weekStart, day: today) })
        if let coveringToday {
            currentWeek = coveringToday
        } else if let cw = currentWeek, let refreshed = all.first(where: { $0.weekId == cw.weekId }) {
            // Same week, refreshed projection.
            currentWeek = refreshed
        } else if !all.isEmpty {
            // No week covers today and the prior currentWeek is gone from the repo
            // (stale cache / phantom) — fall back to the newest real week rather than
            // keep a phantom id the write tools can't resolve. (ensureCurrentCloudKitWeek
            // creates today's week during session setup; this is the reactive fallback.)
            currentWeek = all.first
        }
        // If the repo is momentarily empty, leave currentWeek as-is (transient reload).

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

    /// Manual pull from CloudKit (the Settings "Refresh Now" button) — fetch the household zone,
    /// reload the repos, and re-mirror. Works for owner AND participant; the legacy `refreshAll`
    /// only hits Fly (a no-op in CloudKit-only mode), so a participant otherwise had no way to pull.
    func refreshHouseholdFromCloud() async {
        guard householdLifecycleAllowsEntry(),
              let session = householdSession else { return }
        let requestEpoch = sessionBootEpoch
        syncPhase = .loading
        do {
            try await session.engine.fetchChanges()
        } catch {
            guard sessionBootEpoch == requestEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === session else { return }
            print("[Sharing] refreshHouseholdFromCloud fetch error: \(error)")
        }
        guard sessionBootEpoch == requestEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else { return }
        reloadAndMirrorHousehold()
        let weeks = session.store.records(ofType: HouseholdRecordType.week.recordTypeName).count
        let meals = session.store.records(ofType: HouseholdRecordType.weekMeal.recordTypeName).count
        print("[Sharing] refreshHouseholdFromCloud: weeks=\(weeks) meals=\(meals) role=\(session.role.isOwner ? "owner" : "participant")")
        syncPhase = .synced(.now)
    }

    /// Reload every repo from the LOCAL store + re-mirror to the published @Observable snapshots.
    /// No network fetch — callers that already mutated the local store (e.g. a restore) use this so
    /// a fetch can't pull stale server state back over the just-written records.
    func reloadAndMirrorHousehold() {
        recipeRepository?.reload()
        metadataRepository?.reloadMetadata()
        weekRepository?.reload()
        eventRepository?.reload()
        pantryRepository?.reload()
        guestRepository?.reload()
        mirrorRecipesFromRepository()
        mirrorWeekFromRepository()
        mirrorEventsFromRepository()
        mirrorPantryFromRepository()
        mirrorGuestsFromRepository()
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

    /// UserDefaults key for the sticky "this household has legacy Fly
    /// evidence" marker. Set once, below, when a weeks-import receipt is
    /// found — and never cleared — so it keeps gating in the Import*/Start
    /// Fresh Settings sections even after `hasSavedConnection` reverts to
    /// false (Reset Connection / Sign Out clear the live Fly token, but a
    /// migrated household's CloudKit data — and this marker — survive that).
    static let hasLegacyFlyEvidenceKey = "sm.hasLegacyFlyEvidence"

    /// True once evidence of a legacy Fly-backed household has been
    /// observed. Read by `SettingsView` (alongside `hasSavedConnection`) to
    /// decide whether to show the Import*/Start Fresh migration sections —
    /// new CloudKit-only installs never set this, so those sections stay
    /// hidden for them (simmersmith-8o7). Reads UserDefaults directly
    /// rather than caching on `AppState`; safe because SwiftUI re-evaluates
    /// this at view-build time whenever the host view re-renders for any
    /// other reason (same reasoning as `topBarPrimary(for:)` in
    /// AppState+TopBar.swift).
    var hasLegacyFlyEvidence: Bool {
        UserDefaults.standard.bool(forKey: Self.hasLegacyFlyEvidenceKey)
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
        let hasReceipt = session.store.record(for: receiptID) != nil
        weekImportState = hasReceipt ? .alreadyImported : .idle
        if hasReceipt {
            // Evidence of a legacy Fly-backed household — stamp the marker
            // once so the migration sections keep showing later even if
            // hasSavedConnection reverts to false.
            UserDefaults.standard.set(true, forKey: Self.hasLegacyFlyEvidenceKey)
        }
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
        let requestEpoch = sessionBootEpoch
        let flow = WeekEventImportFlow(
            isCurrentAuthoritative: { [weak self] in
                guard let self else { return false }
                return self.isCurrentAuthoritativeHouseholdSession(session, requestEpoch: requestEpoch)
            },
            prepare: { [weak self] in
                guard let self else { return }
                self.weekImportState = .running
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
                self.serverURLDraft = Self.productionServerURL
            },
            exchangeToken: { [apiClient] in
                let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
                return response.token
            },
            saveImportToken: { [weak self] token in
                guard let self else { return }
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: token)
                self.authTokenDraft = token
            },
            migrate: { [apiClient] in
                await migrateWeeksIfNeeded(session: session, apiClient: apiClient)
            },
            hasMigrationReceipt: {
                let receiptID = CKRecord.ID(
                    recordName: HouseholdMigrationRunner.receiptRecordName(scope: "weeks"),
                    zoneID: session.zoneID
                )
                return session.store.record(for: receiptID) != nil
            },
            publishCompletion: { [weak self] didMigrate in
                self?.weekImportState = didMigrate
                    ? .done
                    : .failed("Import failed — please try again.")
            },
            publishSignInFailure: { [weak self] message in
                self?.weekImportState = .failed("Sign-in failed: \(message)")
            },
            clearImportToken: { [weak self] in
                guard let self else { return }
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
                self.authTokenDraft = ""
            },
            reloadImportedData: { [weak self] in
                guard let self else { return }
                self.weekRepository?.reload()
                self.mirrorWeekFromRepository()
            }
        )
        _ = await flow.run()
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
        let requestEpoch = sessionBootEpoch
        let flow = WeekEventImportFlow(
            isCurrentAuthoritative: { [weak self] in
                guard let self else { return false }
                return self.isCurrentAuthoritativeHouseholdSession(session, requestEpoch: requestEpoch)
            },
            prepare: { [weak self] in
                guard let self else { return }
                self.eventImportState = .running
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
                self.serverURLDraft = Self.productionServerURL
            },
            exchangeToken: { [apiClient] in
                let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
                return response.token
            },
            saveImportToken: { [weak self] token in
                guard let self else { return }
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: token)
                self.authTokenDraft = token
            },
            migrate: { [apiClient] in
                await migrateEventsIfNeeded(session: session, apiClient: apiClient)
            },
            hasMigrationReceipt: {
                let receiptID = CKRecord.ID(
                    recordName: HouseholdMigrationRunner.receiptRecordName(scope: "events"),
                    zoneID: session.zoneID
                )
                return session.store.record(for: receiptID) != nil
            },
            publishCompletion: { [weak self] didMigrate in
                self?.eventImportState = didMigrate
                    ? .done
                    : .failed("Import failed — please try again.")
            },
            publishSignInFailure: { [weak self] message in
                self?.eventImportState = .failed("Sign-in failed: \(message)")
            },
            clearImportToken: { [weak self] in
                guard let self else { return }
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
                self.authTokenDraft = ""
            },
            reloadImportedData: { [weak self] in
                guard let self else { return }
                self.guestRepository?.reload()
                self.eventRepository?.reload()
                self.mirrorGuestsFromRepository()
                self.mirrorEventsFromRepository()
            }
        )
        _ = await flow.run()
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
        let requestEpoch = sessionBootEpoch
        let flow = PantryProfileImportFlow(
            isCurrentAuthoritative: { [weak self] in
                guard let self else { return false }
                return self.isCurrentAuthoritativeHouseholdSession(session, requestEpoch: requestEpoch)
            },
            prepare: { [weak self] in
                guard let self else { return }
                self.pantryProfileImportState = .running
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
                self.serverURLDraft = Self.productionServerURL
            },
            exchangeToken: { [apiClient] in
                let response = try await apiClient.signInWithApple(identityToken: appleIdentityToken)
                return response.token
            },
            saveImportToken: { [weak self] token in
                guard let self else { return }
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: token)
                self.authTokenDraft = token
            },
            migrate: { [weak self, apiClient] in
                await migratePantryProfileIfNeeded(
                    session: session,
                    apiClient: apiClient,
                    isCurrentAuthoritative: { [weak self] in
                        guard let self else { return false }
                        return self.isCurrentAuthoritativeHouseholdSession(
                            session,
                            requestEpoch: requestEpoch
                        )
                    }
                )
            },
            hasMigrationReceipt: {
                session.privateStore?.hasMigrationReceipt(scope: "pantry-profile") ?? false
            },
            publishCompletion: { [weak self] didMigrate in
                self?.pantryProfileImportState = didMigrate
                    ? .done
                    : .failed("Import failed — please try again.")
            },
            publishSignInFailure: { [weak self] message in
                self?.pantryProfileImportState = .failed("Sign-in failed: \(message)")
            },
            clearImportToken: { [weak self] in
                guard let self else { return }
                self.settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
                self.authTokenDraft = ""
            },
            reloadImportedData: { [weak self] in
                guard let self else { return }
                self.pantryRepository?.reload()
                self.aliasRepository?.reload()
                self.profileRepository?.reload()
                self.preferenceRepository?.reload()
                self.mirrorPantryFromRepository()
                self.mirrorAliasesFromRepository()
            }
        )
        await flow.run()
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
        #if canImport(CloudKit)
        if let repo = recipeRepository, let aiSvc = aiService {
            // Gather recipe fields for the prompt.
            guard let recipe = repo.recipes.first(where: { $0.recipeId == recipeID }) else {
                throw NSError(
                    domain: "SimmerSmith.RecipeRepository",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Recipe not found."]
                )
            }
            let ingredientNames = recipe.ingredients.map(\.ingredientName)
            let (imageData, mime) = try await aiSvc.generateRecipeImage(
                name: recipe.name,
                cuisine: recipe.cuisine,
                ingredients: ingredientNames
            )
            repo.setImage(recipeID, imageData, mime: mime)
            mirrorRecipesFromRepository()
            return
        }
        #endif
        // Fly fallback (pre-CloudKit-session or non-CloudKit build).
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
            let result = repo.removeImage(recipeID)
            guard result == .allowed else { throw result }
            mirrorRecipesFromRepository()
            return
        }
        #endif
        let updated = try await apiClient.deleteRecipeImage(recipeID: recipeID)
        upsertRecipe(updated)
        try? cacheStore.saveRecipes(recipes)
    }

    /// Run the backfill that generates header images for every recipe missing one.
    /// On the CloudKit path: generates via AIService (BYO key) → RecipeRepository.stageImage
    /// (staged per recipe without per-item reload/drain), then ONE reload + ONE drain at the
    /// end. This avoids O(N²) re-decodes and N unbounded concurrent drains (AI-4 fix F3).
    /// Per-recipe errors are counted but do not abort the whole backfill.
    func backfillRecipeImages() async throws -> SimmerSmithAPIClient.RecipeImageBackfillResult {
        #if canImport(CloudKit)
        if let repo = recipeRepository, let aiSvc = aiService {
            var generated = 0
            var skipped = 0
            var failed = 0

            // Reload first so imageUrl freshness reflects the latest CloudKit state —
            // a retried backfill should not regenerate already-imaged recipes (F3 staleness fix).
            repo.reload()
            mirrorRecipesFromRepository()
            let allRecipes = repo.recipes.filter { !$0.archived }

            for recipe in allRecipes {
                // hasImage is derived from the presence of a RecipeImage child record.
                if recipe.imageUrl != nil {
                    skipped += 1
                    continue
                }
                let ingredientNames = recipe.ingredients.map(\.ingredientName)
                do {
                    let (imageData, mime) = try await aiSvc.generateRecipeImage(
                        name: recipe.name,
                        cuisine: recipe.cuisine,
                        ingredients: ingredientNames
                    )
                    // Stage without per-item reload/drain (batch path — F3).
                    repo.stageImage(recipe.recipeId, imageData, mime: mime)
                    generated += 1
                } catch {
                    failed += 1
                    // Count + continue — don't abort the whole backfill on one failure.
                }
            }

            if generated > 0 {
                // ONE reload + ONE drain for all staged images.
                repo.reload()
                Task { [weak repo] in await repo?.drainSync() }
                mirrorRecipesFromRepository()
            }
            return SimmerSmithAPIClient.RecipeImageBackfillResult(
                generated: generated, failed: failed, skipped: skipped)
        }
        #endif
        // Fly fallback (pre-CloudKit-session or non-CloudKit build).
        let result = try await apiClient.backfillRecipeImages()
        if result.generated > 0 {
            await refreshRecipes()
        }
        return result
    }

    // MARK: - Recipe memories log (M15)

    #if canImport(CloudKit)
    /// Map repository memory entries onto the RecipeMemory DTO the memories UI consumes.
    /// The repository returns oldest→newest; the UI contract (RecipeMemoriesSection) is
    /// newest-first, so the list is reversed. A photo is signalled by the `ckmem:<id>`
    /// sentinel in `photoUrl` — the view layer fetches bytes via
    /// `fetchRecipeMemoryPhotoBytes`, never the URL itself.
    /// Internal (not private) so the app-target test can exercise the mapping.
    static func memoryDTOs(from entries: [RecipeMemoryEntry]) -> [RecipeMemory] {
        entries.reversed().map { entry in
            RecipeMemory(
                id: entry.id,
                body: entry.body,
                createdAt: entry.createdAt,
                photoUrl: entry.hasPhoto ? "ckmem:\(entry.id)" : nil
            )
        }
    }
    #endif

    /// Refresh + cache the memory log for one recipe. Returns the
    /// fresh list so callers can use it directly. Caches by recipeID
    /// so navigating away/back doesn't refetch immediately.
    func refreshRecipeMemories(recipeID: String) async throws -> [RecipeMemory] {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            let memories = Self.memoryDTOs(from: repo.memories(forRecipe: recipeID))
            recipeMemories[recipeID] = memories
            return memories
        }
        #endif
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
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            let memoryId = repo.addMemory(recipeID, body: body)
            if let imageData {
                repo.setMemoryPhoto(memoryId, imageData, mime: mimeType ?? "image/jpeg")
            }
            // Read back after setMemoryPhoto so hasPhoto (→ photoUrl sentinel) is correct.
            let memory: RecipeMemory
            if let entry = repo.memories(forRecipe: recipeID).first(where: { $0.id == memoryId }),
               let mapped = Self.memoryDTOs(from: [entry]).first {
                memory = mapped
            } else {
                memory = RecipeMemory(
                    id: memoryId,
                    body: body,
                    createdAt: Date(),
                    photoUrl: imageData != nil ? "ckmem:\(memoryId)" : nil
                )
            }
            var current = recipeMemories[recipeID] ?? []
            current.insert(memory, at: 0)
            recipeMemories[recipeID] = current
            return memory
        }
        #endif
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
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            if let data = await repo.memoryPhotoBytes(memoryID) {
                return data
            }
            throw NSError(
                domain: "SimmerSmith.RecipeRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Memory photo not found in the local store."]
            )
        }
        #endif
        return try await apiClient.fetchRecipeMemoryPhotoBytes(
            recipeID: recipeID,
            memoryID: memoryID
        )
    }

    func deleteRecipeMemory(recipeID: String, memoryID: String) async throws {
        #if canImport(CloudKit)
        if let repo = recipeRepository {
            let result = repo.deleteMemory(memoryID)
            guard result == .allowed else { throw result }
            recipeMemories[recipeID] = (recipeMemories[recipeID] ?? []).filter { $0.id != memoryID }
            return
        }
        #endif
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
        // SP-C AI-3: deterministic catalog port (NOT LLM). PublicCatalogReader looks up
        // per-ingredient macros from the catalog (variation first, then base ingredient),
        // then NutritionCalculator scales by quantity/unit — the same logic as the server's
        // `calculate_recipe_nutrition`. No API key required.
        #if canImport(CloudKit)
        if let catalog = householdSession?.catalog {
            let ingredients: [NutritionCalculator.Ingredient] = draft.ingredients.map { ing in
                NutritionCalculator.Ingredient(
                    key: NutritionCalculator.IngredientKey(
                        ingredientName: ing.ingredientName,
                        normalizedName: ing.normalizedName,
                        baseIngredientID: ing.baseIngredientId,
                        ingredientVariationID: ing.ingredientVariationId
                    ),
                    quantity: ing.quantity,
                    unit: ing.unit
                )
            }
            // Build a sync catalog-lookup backed by the async PublicCatalogReader.
            // For each ingredient we do an async resolve on the catalog, then cache in a
            // local dict so the NutritionCalculator's sync closure can answer subsequent
            // calls immediately.
            //
            // NAME-ONLY RESOLUTION (SP-C AI-3): the public catalog
            // (`PublicCatalogReader.macros(forNormalizedName:)`) resolves a row ONLY by
            // `normalizedName` — there is no record-ID index on PUBLIC. The server's
            // ID-preference (variation → base → name) therefore CANNOT be honored against
            // the public catalog. So the fetch, the cache store, AND the lookup closure are
            // ALL keyed by `NutritionCalculator.normalizeName(ingredientName)` (preferring
            // the ingredient's own `normalizedName` field when present). A prior version keyed
            // the store by the record-ID (variationID ?? baseID ?? name) while the catalog
            // query + store value came from the normalized NAME — so any ingredient carrying a
            // baseIngredientID/variationID was stored and looked up under a key the catalog
            // never populated, returning nil → marked unmatched → wrong/zero calories. Dropping
            // the ID indirection fixes that.
            @Sendable func catalogKey(_ key: NutritionCalculator.IngredientKey) -> String {
                if let normalized = key.normalizedName, !normalized.isEmpty { return normalized }
                return NutritionCalculator.normalizeName(key.ingredientName)
            }
            var macroCache: [String: CatalogMacros] = [:]
            for ingredient in ingredients {
                let cacheKey = catalogKey(ingredient.key)
                if macroCache[cacheKey] != nil { continue }
                if let projection = await catalog.macros(forNormalizedName: cacheKey) {
                    macroCache[cacheKey] = CatalogMacros(
                        referenceAmount: projection.referenceAmount,
                        referenceUnit: projection.referenceUnit,
                        calories: projection.calories,
                        proteinG: projection.proteinG,
                        carbsG: projection.carbsG,
                        fatG: projection.fatG,
                        fiberG: projection.fiberG
                    )
                }
            }
            let capturedCache = macroCache
            let calculator = NutritionCalculator(lookup: { key in
                capturedCache[catalogKey(key)]
            })
            return calculator.calculateRecipeNutrition(ingredients: ingredients, servings: draft.servings)
        }
        #endif
        return try await apiClient.estimateRecipeNutrition(draft)
    }

    func importRecipeDraft(fromURL url: String) async throws -> RecipeDraft {
        // SP-C AI-2: deterministic JSON-LD first; LLM fallback when no Recipe node.
        // JSON-LD requires no API key; LLM fallback requires a key — the caller sees
        // AIServiceError.noKeyConfigured if no key is set and JSON-LD was absent.
        let html = try await RecipeURLFetcher().fetchHTML(from: url)
        if let draft = JSONLDRecipeExtractor.extract(fromHTML: html, sourceURL: url) {
            return draft
        }
        // No JSON-LD Recipe node — fall back to LLM extraction.
        return try await importRecipeDraft(fromHTML: html, sourceURL: url, sourceLabel: "")
    }

    func importRecipeDraft(fromHTML html: String, sourceURL: String, sourceLabel: String = "") async throws -> RecipeDraft {
        // SP-C AI-2: JSON-LD first (no key needed); LLM extraction fallback.
        if let draft = JSONLDRecipeExtractor.extract(fromHTML: html, sourceURL: sourceURL.isEmpty ? nil : sourceURL) {
            return draft
        }
        // No JSON-LD — LLM extraction. Requires a key; surfaces AIServiceError.noKeyConfigured.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let unit = currentUnitSystem()
        let prompt = RecipeAIPrompt.extractionPrompt(rawText: html, unit: unit)
        let request = AIRequest(feature: .companionDraft, prompt: prompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        let wire = try RecipeAIParser.parseRecipe(response.text)
        return recipeDraft(from: wire, source: "url_import", sourceURL: sourceURL, sourceLabelOverride: sourceLabel)
        #else
        return try await apiClient.importRecipe(fromHTML: html, sourceURL: sourceURL, sourceLabel: sourceLabel)
        #endif
    }

    func importRecipeDraft(
        fromText text: String,
        title: String = "",
        source: String = "scan_import",
        sourceLabel: String = "",
        sourceURL: String = ""
    ) async throws -> RecipeDraft {
        // SP-C AI-2: LLM extraction from unstructured text (OCR, paste). Requires a key.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let unit = currentUnitSystem()
        let prompt = RecipeAIPrompt.extractionPrompt(rawText: text, unit: unit)
        let request = AIRequest(feature: .companionDraft, prompt: prompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        let wire = try RecipeAIParser.parseRecipe(response.text)
        var draft = recipeDraft(from: wire, source: source, sourceURL: sourceURL, sourceLabelOverride: sourceLabel)
        if !title.isEmpty, draft.name.isEmpty { draft.name = title }
        return draft
        #else
        return try await apiClient.importRecipe(
            fromText: text,
            title: title,
            source: source,
            sourceLabel: sourceLabel,
            sourceURL: sourceURL
        )
        #endif
    }

    func generateRecipeVariationDraft(recipeID: String, goal: String) async throws -> RecipeAIDraft {
        // SP-C AI-2: on-device LLM variation via RecipeAIPrompt. Requires a key.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        guard let recipe = recipes.first(where: { $0.recipeId == recipeID }) else {
            throw NSError(
                domain: "SimmerSmith.RecipeRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Recipe not found."]
            )
        }
        let unit = currentUnitSystem()
        let context = recipeContext(from: recipe)
        let prompt = RecipeAIPrompt.variationPrompt(recipe: context, goal: goal, unit: unit)
        let request = AIRequest(feature: .companionDraft, prompt: prompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        let wire = try RecipeAIParser.parseVariation(response.text)
        var draft = recipeDraft(from: wire.recipe, source: "ai_variation", sourceURL: recipe.sourceUrl, sourceLabelOverride: "")
        draft.baseRecipeId = recipe.recipeId
        return RecipeAIDraft(goal: goal, rationale: wire.rationale, draft: draft)
        #else
        return try await apiClient.generateRecipeVariationDraft(recipeID: recipeID, goal: goal)
        #endif
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
        // SP-C AI-2: on-device provider web-search tool. Requires a key.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let unit = currentUnitSystem()
        let prompt = RecipeAIPrompt.webSearchInput(query: query, unit: unit)
        let request = AIRequest(feature: .companionDraft, prompt: prompt, wantsWebSearch: true)
        let response = try await aiSvc.generate(request)
        let wire = try RecipeAIParser.parseRecipe(response.text)
        return recipeDraft(from: wire, source: "web_search", sourceURL: wire.sourceUrl, sourceLabelOverride: wire.sourceLabel)
        #else
        return try await apiClient.searchRecipeOnWeb(query: query)
        #endif
    }

    func generateRecipeSuggestionDraft(goal: String) async throws -> RecipeAIDraft {
        // SP-C AI-2: on-device LLM suggestion via RecipeAIPrompt. Requires a key.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let unit = currentUnitSystem()
        let recentNames = recipes.prefix(20).map(\.name)
        let prompt = RecipeAIPrompt.suggestionPrompt(goal: goal, recentNames: Array(recentNames), unit: unit)
        let request = AIRequest(feature: .companionDraft, prompt: prompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        // SP-C AI-2 review I2: the prompt asks for the `{rationale, recipe}` envelope,
        // but a model that returns a FLAT recipe object would otherwise throw
        // `.invalidJSON`. Try the envelope first, then fall back to the flat
        // `parseRecipe` shape (deriving an empty rationale) so a flat response still
        // produces a usable draft instead of an error.
        let recipe: RecipeAIRecipe
        let rationale: String
        if let envelope = try? RecipeAIParser.parseVariation(response.text) {
            recipe = envelope.recipe
            rationale = envelope.rationale
        } else {
            recipe = try RecipeAIParser.parseRecipe(response.text)
            rationale = ""
        }
        let draft = recipeDraft(from: recipe, source: "ai_suggestion", sourceURL: "", sourceLabelOverride: "")
        return RecipeAIDraft(goal: goal, rationale: rationale, draft: draft)
        #else
        return try await apiClient.generateRecipeSuggestionDraft(goal: goal)
        #endif
    }

    /// SP-C AI-2: side-dish draft, composed as a suggestion goal referencing
    /// the parent meal + side name + optional user hint, then delegated to
    /// `generateRecipeSuggestionDraft(goal:)`. No dedicated side-draft prompt
    /// or CloudKit record type — reuses the already-ported suggestion path.
    func generateSideRecipeDraft(
        weekID: String,
        mealID: String,
        sideID: String,
        sideName: String,
        prompt: String = "",
        servings: Int = 0
    ) async throws -> RecipeDraft {
        #if canImport(CloudKit)
        let mealName = currentWeek?.meals.first(where: { $0.mealId == mealID })?.recipeName
        var goal = "A side dish named \"\(sideName)\""
        if let mealName, !mealName.isEmpty {
            goal += " to serve alongside \(mealName)"
        }
        goal += "."
        let trimmedHint = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHint.isEmpty {
            goal += " \(trimmedHint)"
        }
        let aiDraft = try await generateRecipeSuggestionDraft(goal: goal)
        return aiDraft.draft
        #else
        return try await apiClient.generateSideRecipeDraft(
            weekID: weekID, mealID: mealID, sideID: sideID, prompt: prompt, servings: servings
        )
        #endif
    }

    func generateRecipeCompanionDrafts(recipeID: String) async throws -> RecipeAIOptions {
        // SP-C AI-2: on-device LLM companion suggestions. Requires a key.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        guard let recipe = recipes.first(where: { $0.recipeId == recipeID }) else {
            throw NSError(
                domain: "SimmerSmith.RecipeRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Recipe not found."]
            )
        }
        let unit = currentUnitSystem()
        let context = recipeContext(from: recipe)
        let prompt = RecipeAIPrompt.companionPrompt(recipe: context, unit: unit)
        let request = AIRequest(feature: .companionDraft, prompt: prompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        let wire = try RecipeAIParser.parseCompanion(response.text)
        let options = wire.options.map { opt in
            RecipeAIDraftOption(
                optionId: opt.optionId,
                label: opt.label,
                rationale: opt.rationale,
                draft: recipeDraft(from: opt.recipe, source: "ai_companion", sourceURL: "", sourceLabelOverride: "")
            )
        }
        return RecipeAIOptions(goal: recipe.name, rationale: wire.rationale, options: options)
        #else
        return try await apiClient.generateRecipeCompanionDrafts(recipeID: recipeID)
        #endif
    }

    // MARK: - SP-C AI-2: recipe-AI helpers (prompt input + wire-to-domain mapping)

    /// Convert a saved `RecipeSummary` to the dependency-free `RecipeContext` the
    /// prompt builders need. Ingredients are rendered as "quantity unit name (prep)"
    /// strings; steps use their instruction text in sort order.
    private func recipeContext(from recipe: RecipeSummary) -> RecipeContext {
        RecipeContext(
            name: recipe.name,
            mealType: recipe.mealType,
            cuisine: recipe.cuisine,
            servings: recipe.servings,
            prepMinutes: recipe.prepMinutes,
            cookMinutes: recipe.cookMinutes,
            tags: recipe.tags,
            ingredients: recipe.ingredients.map { renderIngredient($0) },
            steps: recipe.steps.sorted { $0.sortOrder < $1.sortOrder }.map(\.instruction),
            notes: recipe.notes
        )
    }

    /// Convert an in-flight `RecipeDraft` to `RecipeContext` for the refine prompt.
    private func recipeContext(from draft: RecipeDraft) -> RecipeContext {
        RecipeContext(
            name: draft.name,
            mealType: draft.mealType,
            cuisine: draft.cuisine,
            servings: draft.servings,
            prepMinutes: draft.prepMinutes,
            cookMinutes: draft.cookMinutes,
            tags: draft.tags,
            ingredients: draft.ingredients.map { renderIngredient($0) },
            steps: draft.steps.sorted { $0.sortOrder < $1.sortOrder }.map(\.instruction),
            notes: draft.notes
        )
    }

    private func renderIngredient(_ ing: RecipeIngredient) -> String {
        var parts: [String] = []
        if let qty = ing.quantity {
            parts.append(qty == qty.rounded() ? String(Int(qty)) : String(qty))
        }
        if !ing.unit.isEmpty { parts.append(ing.unit) }
        parts.append(ing.ingredientName.isEmpty ? "—" : ing.ingredientName)
        if !ing.prep.isEmpty { parts.append("(\(ing.prep))") }
        return parts.joined(separator: " ")
    }

    /// Render the AVOID/PREFERS preference bullets `SubstitutionPrompt` expects, so
    /// the model doesn't suggest a flagged/avoided ingredient. Mirrors
    /// `substitution_ai._preference_note`: only ACTIVE preferences count, and a
    /// preference is either an AVOID (choiceMode avoid/dislike/allergy) or a PREFERS
    /// (a preferred brand or variation on record) — never both.
    #if canImport(CloudKit)
    private func substitutionPreferenceNotes(from preferences: [IngredientPreference]) -> [String] {
        var bullets: [String] = []
        for pref in preferences where pref.active {
            let name = pref.baseIngredientName.isEmpty ? pref.baseIngredientId : pref.baseIngredientName
            if ["avoid", "dislike", "allergy"].contains(pref.choiceMode) {
                bullets.append("- AVOID: \(name) (\(pref.choiceMode))")
            } else {
                let variation = pref.preferredVariationId ?? ""
                guard !pref.preferredBrand.isEmpty || !variation.isEmpty else { continue }
                let brand = pref.preferredBrand.isEmpty ? variation : pref.preferredBrand
                bullets.append("- PREFERS: \(name) → \(brand)")
            }
        }
        return bullets
    }
    #endif

    /// Map a `RecipeAIRecipe` wire value onto a `RecipeDraft` with the given source
    /// metadata. All identity fields (recipeId, baseRecipeId) are left nil — callers
    /// set them as needed (variation sets baseRecipeId; refine restores recipeId).
    private func recipeDraft(
        from wire: RecipeAIRecipe,
        source: String,
        sourceURL: String,
        sourceLabelOverride: String
    ) -> RecipeDraft {
        let ingredients: [RecipeIngredient] = wire.ingredients.map { ai in
            RecipeIngredient(
                ingredientName: ai.ingredientName,
                resolutionStatus: "unresolved",
                quantity: ai.quantity,
                unit: ai.unit,
                prep: ai.prep,
                category: ai.category,
                notes: ai.notes
            )
        }
        let steps: [RecipeStep] = wire.steps.enumerated().map { index, ai in
            RecipeStep(sortOrder: index + 1, instruction: ai.instruction)
        }
        let summary = steps
            .map { "\($0.sortOrder). \($0.instruction)" }
            .joined(separator: "\n")
        let effectiveSourceLabel = sourceLabelOverride.isEmpty ? wire.sourceLabel : sourceLabelOverride
        let effectiveSourceURL = sourceURL.isEmpty ? wire.sourceUrl : sourceURL
        return RecipeDraft(
            name: wire.name,
            mealType: wire.mealType,
            cuisine: wire.cuisine,
            servings: wire.servings,
            prepMinutes: wire.prepMinutes,
            cookMinutes: wire.cookMinutes,
            tags: wire.tags,
            instructionsSummary: summary,
            source: source,
            sourceLabel: effectiveSourceLabel,
            sourceUrl: effectiveSourceURL,
            notes: wire.notes,
            ingredients: ingredients,
            steps: steps
        )
    }

    /// Resolve the user's unit-system preference — mirrors `currentUnitSystemSetting()`
    /// in `AppState+WeekGen` but scoped to the recipe-AI methods.
    #if canImport(CloudKit)
    private func currentUnitSystem() -> UnitSystem {
        let raw: String?
        if let v = profileRepository?.settings["unit_system"], !v.isEmpty {
            raw = v
        } else {
            raw = profile?.settings["unit_system"]
        }
        return UnitSystem.normalized(raw)
    }
    #endif

    /// AI ingredient-substitution suggestions for one recipe ingredient.
    /// Façade so `SubstitutionSheetView` no longer reaches into `apiClient` directly.
    ///
    /// SP-D substitution port: on-device LLM substitution suggestions via
    /// `SubstitutionPrompt`. Requires a key.
    func suggestIngredientSubstitutions(
        recipeID: String,
        ingredientID: String,
        hint: String = ""
    ) async throws -> IngredientSubstituteResponse {
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        guard let recipe = recipes.first(where: { $0.recipeId == recipeID }) else {
            throw NSError(
                domain: "SimmerSmith.RecipeRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Recipe not found."]
            )
        }
        guard let target = recipe.ingredients.first(where: { $0.id == ingredientID }) else {
            throw NSError(
                domain: "SimmerSmith.RecipeRepository",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Ingredient not found."]
            )
        }
        let unit = currentUnitSystem()
        let allIngredients = recipe.ingredients.map { renderIngredient($0) }
        let targetLine = renderIngredient(target)
        let preferenceNotes = substitutionPreferenceNotes(from: ingredientPreferences)
        let prompt = SubstitutionPrompt.build(
            recipeName: recipe.name,
            cuisine: recipe.cuisine,
            mealType: recipe.mealType,
            allIngredients: allIngredients,
            targetIngredientLine: targetLine,
            hint: hint,
            preferenceNotes: preferenceNotes,
            unit: unit
        )
        let request = AIRequest(feature: .substitution, prompt: prompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        let wire = try SubstitutionAIParser.parse(response.text)
        let suggestions = wire.map {
            SubstitutionSuggestion(name: $0.name, reason: $0.reason, quantity: $0.quantity, unit: $0.unit)
        }
        return IngredientSubstituteResponse(
            ingredientId: target.id,
            originalName: target.ingredientName,
            suggestions: suggestions
        )
        #else
        return try await apiClient.suggestIngredientSubstitutions(
            recipeID: recipeID,
            ingredientID: ingredientID,
            hint: hint
        )
        #endif
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
        // SP-C AI-2: on-device LLM refinement. Requires a key.
        #if canImport(CloudKit)
        guard let aiSvc = aiService else {
            throw NSError(
                domain: "SimmerSmith.AIService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "AI service not ready — try again after iCloud loads."]
            )
        }
        let unit = currentUnitSystem()
        let context = recipeContext(from: currentDraft)
        let builtPrompt = RecipeAIPrompt.refinePrompt(
            draft: context,
            instruction: prompt,
            contextHint: contextHint,
            unit: unit
        )
        let request = AIRequest(feature: .companionDraft, prompt: builtPrompt, wantsStructuredJSON: true)
        let response = try await aiSvc.generate(request)
        let wire = try RecipeAIParser.parseVariation(response.text)
        // Preserve the draft's identity fields (recipeId, baseRecipeId, source) — the refine
        // path is "apply instruction, change as little as possible"; the caller owns save.
        var refined = recipeDraft(from: wire.recipe, source: currentDraft.source, sourceURL: currentDraft.sourceUrl, sourceLabelOverride: currentDraft.sourceLabel)
        refined.recipeId = currentDraft.recipeId
        refined.baseRecipeId = currentDraft.baseRecipeId
        return refined
        #else
        return try await apiClient.refineRecipeDraft(
            draft: currentDraft,
            prompt: prompt,
            contextHint: contextHint
        )
        #endif
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
    /// The ingredient slice owns the composed household + bounded PUBLIC prefix search;
    /// this compatibility façade keeps recipe call sites on that single path.
    func fetchBaseIngredients(query: String, limit: Int) async throws -> [BaseIngredient] {
        try await searchBaseIngredients(query: query, limit: limit)
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
            let result = repo.delete(recipe.recipeId)
            guard result == .allowed else { throw result }
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
