#if canImport(CloudKit)
import Foundation
import CloudKit
import CloudKitProvisioning
import HouseholdSync
import HouseholdRecords

// SP-C household sharing v1 — the participant (adopt) side. The owner-side share creation
// lives in Settings (UICloudSharingController over HouseholdShareFlow.makeOrFetchZoneWideShare).
// Here a SECOND iCloud account accepts a zone-wide CKShare and ADOPTS the owner's household:
// it boots a participant HouseholdSession on the shared database (a second CKSyncEngine), with
// NO merge of its own solo data. See .docs/ai/phases/household-sharing-spec.md.
enum ParticipantHouseholdIDPolicy {
    static func resolve(
        cachedHouseholdID: String?,
        recoveryHouseholdID: String?,
        fallbackZoneName: String
    ) -> String {
        cachedHouseholdID ?? recoveryHouseholdID ?? fallbackZoneName
    }
}

extension AppState {

    // MARK: - Participant marker (durable adopt-across-launches)

    struct ParticipantMarker {
        let zoneName: String
        let ownerName: String
        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }
    }

    private static let markerZoneNameKey = "sharing.participant.zoneName.v1"
    private static let markerOwnerNameKey = "sharing.participant.ownerName.v1"

    /// The saved participant household, if this device has adopted one. Checked BEFORE owner
    /// discovery in `ensureHouseholdSession` so a participant re-boots as participant on relaunch.
    func loadParticipantMarker() -> ParticipantMarker? {
        let d = UserDefaults.standard
        guard let zoneName = d.string(forKey: Self.markerZoneNameKey), !zoneName.isEmpty,
              let ownerName = d.string(forKey: Self.markerOwnerNameKey), !ownerName.isEmpty
        else { return nil }
        return ParticipantMarker(zoneName: zoneName, ownerName: ownerName)
    }

    func saveParticipantMarker(_ marker: ParticipantMarker) {
        let d = UserDefaults.standard
        d.set(marker.zoneName, forKey: Self.markerZoneNameKey)
        d.set(marker.ownerName, forKey: Self.markerOwnerNameKey)
    }

    func clearParticipantMarker() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.markerZoneNameKey)
        d.removeObject(forKey: Self.markerOwnerNameKey)
    }

    /// CloudKit revoked/deleted the participant zone. The engine has already requested exact
    /// scope retirement; clear durable adoption before advancing the epoch and dropping repos.
    func handleParticipantRevocation() {
        clearParticipantMarker()
        teardownHouseholdSession(clearShadowRoot: false)
    }

    func handleHouseholdAccountChange() {
        clearParticipantMarker()
        teardownHouseholdSession()
    }

    var isParticipant: Bool { loadParticipantMarker() != nil }

    /// True when this device owns its household (a booted owner session) and can share it.
    var canShareHousehold: Bool { (householdSession?.role.isOwner ?? false) && !isParticipant }

    // MARK: - Owner: prepare the zone-wide share for UICloudSharingController

    /// A prepared zone-wide share + its container, for `UICloudSharingController`.
    struct OwnerSharePackage: Identifiable {
        let id = UUID()
        let share: CKShare
        let container: CKContainer
    }

    /// Create (or fetch) the household's zone-wide CKShare so the owner can hand it to the
    /// system share sheet. Returns nil if there's no owner session yet.
    func prepareOwnerShare(title: String) async -> OwnerSharePackage? {
        guard let session = householdSession,
              session.role.isOwner,
              CachedHouseholdSystemOperationPolicy.allows(
                .ownerShareCreation,
                isCachedBootstrap: session.isCachedBootstrap)
        else { return nil }
        do {
            let flow = HouseholdShareFlow()
            let share = try await flow.makeOrFetchZoneWideShare(householdID: session.householdID, title: title)
            return OwnerSharePackage(share: share, container: flow.container)
        } catch {
            lastErrorMessage = "Couldn't prepare the share: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Accept a share / boot the participant session

    /// Warm-tap entry: drain a just-accepted share from the inbox and adopt it (swapping out
    /// an already-booted owner session). Called by the scene delegate when the app is running.
    ///
    /// Re-entrancy (simmersmith-0gf): this is one of TWO entry points that can boot a household
    /// session — the other is `ensureHouseholdSession()`. Both enqueue on `sessionBootQueue` (a
    /// strict FIFO) so a warm share-accept boot and an in-flight owner boot never interleave at
    /// suspension points and race on which session wins last-writer-wins.
    func processPendingShare() async {
        // simmersmith-0gf blocking-finding fix: capture the epoch AT REQUEST TIME, before
        // this op enters the queue — see `ensureHouseholdSession()` for the matching owner-
        // side capture and `AppState.sessionBootEpoch`'s doc comment for why this is needed.
        let requestEpoch = sessionBootEpoch
        await sessionBootQueue.enqueue { [weak self] in
            guard let self else { return }
            // Stale: a sign-out landed while this request was queued behind a predecessor.
            guard self.sessionBootEpoch == requestEpoch else { return }
            guard let metadata = PendingShareInbox.shared.take() else { return }
            print("[Sharing] processPendingShare: draining metadata, role=\(metadata.participantRole.rawValue) container=\(metadata.containerIdentifier)")
            await self.bootParticipantSession(accepting: metadata, requestEpoch: requestEpoch)
        }.value
    }

    /// Accept a zone-wide CKShare and adopt the owner's household.
    ///
    /// Must only be called from within a `sessionBootQueue` op (simmersmith-0gf) — it is called
    /// directly by `ensureSessionBootOp()`'s participant-first check and by
    /// `processPendingShare()`'s queued op. It must NOT itself enqueue: both of those callers
    /// already run inside the queue's chain, so a nested `enqueue(...).value` here would await
    /// a task that can only run after itself — a self-deadlock.
    func bootParticipantSession(accepting metadata: CKShare.Metadata, requestEpoch: Int) async {
        print("[Sharing] bootParticipantSession: role=\(metadata.participantRole.rawValue) container=\(metadata.containerIdentifier)")
        // The owner tapping their own link is benign — do nothing (the owner path boots
        // normally on the next ensureHouseholdSession).
        if metadata.participantRole == .owner {
            print("[Sharing] skip: participantRole == .owner (owner tapped own link)")
            return
        }
        // Defensive: only accept shares for our container. Non-silent so a mismatch is visible.
        if metadata.containerIdentifier != "iCloud.app.simmersmith.cloud" {
            print("[Sharing] reject: container mismatch \(metadata.containerIdentifier)")
            lastErrorMessage = "This share is for a different app (\(metadata.containerIdentifier))."
            return
        }

        do {
            print("[Sharing] accepting zone-wide share…")
            let flow = HouseholdShareFlow()
            let zoneID = try await flow.acceptZoneWideShare(metadata)
            print("[Sharing] accepted; adopting zone \(zoneID.zoneName) owner=\(zoneID.ownerName)")
            // simmersmith-0gf blocking-finding fix: a sign-out during the accept round-trip
            // above makes this request stale — don't adopt/wire or persist a participant
            // marker for a household the user just tore down.
            guard sessionBootEpoch == requestEpoch else {
                print("[Sharing] abort: sessionBootEpoch moved during accept (stale request)")
                return
            }
            let adopted = await adoptSharedZone(zoneID, requestEpoch: requestEpoch)
            guard adopted else {
                print("[Sharing] abort: sessionBootEpoch moved during adopt (stale request) — not saving marker")
                return
            }
            saveParticipantMarker(ParticipantMarker(zoneName: zoneID.zoneName, ownerName: zoneID.ownerName))
            print("[Sharing] adopted + marker saved — participant booted")
            lastErrorMessage = nil
        } catch {
            print("[Sharing] accept FAILED: \(error)")
            // Re-deposit so a foreground retry re-attempts the accept rather than falling
            // through to owner discovery (which would orphan-mint a solo zone). A permanently
            // bad share just keeps surfacing this message — never corrupts data. Leave the
            // launch phase unchanged (a cold accept stays .resolving → RootView keeps loading
            // and the scenePhase==.active retry re-fires; a warm accept keeps the owner ready).
            PendingShareInbox.shared.deposit(metadata)
            lastErrorMessage = "Couldn't join the shared household — will retry. (\(error.localizedDescription))"
        }
    }

    /// Re-boot an already-adopted participant household from the saved marker (relaunch).
    func bootParticipantSession(reusing marker: ParticipantMarker, requestEpoch: Int) async {
        let candidate: MirrorBootstrapCandidate?
        let recoveryCandidate: MirrorRecoveryCandidate?
        if cacheFirstLaunchEnabled {
            let account = try? await HouseholdShareFlow().currentUserRecordName()
            // This account lookup is a new async identity boundary; stale participant boot
            // must not detach the current session or select any marker scope.
            guard sessionBootEpoch == requestEpoch else { return }
            if let account {
                let selection = bootstrapSelection(
                    accountRecordName: account,
                    request: .participant(
                        accountRecordName: account,
                        markerZone: MirrorZoneReference(
                            ownerName: marker.ownerName,
                            zoneName: marker.zoneName)),
                    expectedRole: .participant,
                    expectedZone: MirrorZoneReference(
                        ownerName: marker.ownerName,
                        zoneName: marker.zoneName))
                candidate = selection.cachedCandidate
                recoveryCandidate = selection.recoveryCandidate
            } else {
                candidate = nil
                recoveryCandidate = nil
            }
        } else {
            candidate = nil
            recoveryCandidate = nil
        }
        await adoptSharedZone(
            marker.zoneID,
            requestEpoch: requestEpoch,
            bootstrapCandidate: candidate,
            recoveryCandidate: recoveryCandidate)
    }

    /// Boot a participant `HouseholdSession` on the owner's shared zone, fetch, and wire repos.
    /// Returns `false` (without wiring anything) if `requestEpoch` went stale mid-flight —
    /// see the `discardableResult` callers for the simmersmith-0gf blocking-finding fix.
    @discardableResult
    private func adoptSharedZone(
        _ zoneID: CKRecordZone.ID,
        requestEpoch: Int,
        bootstrapCandidate: MirrorBootstrapCandidate? = nil,
        recoveryCandidate: MirrorRecoveryCandidate? = nil
    ) async -> Bool {
        // The entry check precedes the destructive warm-swap step. A queued/stale adoption
        // must not detach the current household or construct a competing participant session.
        guard sessionBootEpoch == requestEpoch else { return false }
        // Warm swap: detach an already-booted owner engine (KEEP its state token so the
        // parked solo zone survives a future un-adopt), then replace the session.
        householdSession?.detach()
        // simmersmith-qrt (backstop): the warm owner→participant swap must not carry the
        // pre-swap session's stale failure/last-synced state into the new session's status
        // surface. participantJoin is overwritten by the join loop below either way; this
        // clears the rest. Mirrors teardownHouseholdSession()'s reset.
        syncStatusCenter.reset()

        let session = HouseholdSession(
            householdID: ParticipantHouseholdIDPolicy.resolve(
                cachedHouseholdID: bootstrapCandidate?.bootstrap.scope.householdID,
                recoveryHouseholdID: recoveryCandidate?.plan.scope.householdID,
                fallbackZoneName: zoneID.zoneName),
            role: .participant(sharedZoneID: zoneID),
            syncStatusCenter: self.syncStatusCenter,
            bootstrapCandidate: bootstrapCandidate,
            recoveryCandidate: recoveryCandidate)
        // Cached candidates already contain the local household projection. Keep it visible
        // while the independent first reconciliation runs; the no-cache path retains its
        // participant-first fetch/retry order.
        await session.start()
        // Recovery-only durable intents cannot render or continue participant discovery until
        // their exact nil-state full fetch and atomic overlay have succeeded.
        guard !session.isRecoveryOnly || session.recoveryOnlyFetchSucceeded else {
            session.detach()
            return false
        }
        if session.isCachedBootstrap {
            guard sessionBootEpoch == requestEpoch else {
                session.detach()
                return false
            }
            await wireHouseholdRepositories(session: session, requestEpoch: requestEpoch)
            guard sessionBootEpoch == requestEpoch, householdSession === session else {
                session.detach()
                return false
            }
            publishCachedHouseholdAuthority(session: session, epoch: requestEpoch)
            guard sessionBootEpoch == requestEpoch, householdSession === session else { return false }
            householdLaunchPhase = .ready
            scheduleCachedPrivatePlaneOpen(session: session, requestEpoch: requestEpoch)
            scheduleCachedReconciliation(session: session, requestEpoch: requestEpoch)
            return true
        }
        await participantInitialFetch(session: session, requestEpoch: requestEpoch)

        // simmersmith-0gf blocking-finding fix: re-check right before the commit point — a
        // sign-out could have landed during any of the awaits above (session.start(),
        // participantInitialFetch()). Detach (don't wire) a session built for a now-stale
        // request rather than resurrecting it post-teardown.
        guard sessionBootEpoch == requestEpoch else {
            session.detach()
            return false
        }

        await wireHouseholdRepositories(session: session, requestEpoch: requestEpoch)
        guard sessionBootEpoch == requestEpoch, householdSession === session else {
            session.detach()
            return false
        }
        installAuthorityDispatcher(for: session, epoch: requestEpoch)
        guard sessionBootEpoch == requestEpoch, householdSession === session else { return false }
        // Noncached participants complete the exact P1 fetch/retry path before publication.
        publishDirectHouseholdAuthority(session: session, epoch: requestEpoch)
        personalDataReadiness = session.privateStore == nil ? .unavailable : .ready
        householdLaunchPhase = .ready
        return true
    }

    /// The make-or-break post-accept fetch: the accepting device usually receives no push
    /// for its own acceptance, and `accept()` can return before the server finishes creating
    /// the zone — so fetch once, then again after a short backoff to close the race.
    ///
    /// `requestEpoch` (simmersmith-7in): re-checked between attempts and before every
    /// `syncStatusCenter` publish — this loop can run up to ~9s (6 attempts × ~1.5s backoff);
    /// without the re-check, a sign-out mid-loop leaves it fetching into a torn-down session
    /// and publishing stale join status for several more seconds.
    private func participantInitialFetch(session: HouseholdSession, requestEpoch: Int) async {
        // A freshly-accepted shared zone can take several fetch cycles to fully propagate to
        // this device — the accept can return before the server finishes, and the device gets
        // no push for its own acceptance. Retry until the owner's weeks land (or attempts run
        // out), logging record counts so a TestFlight run reveals whether data is arriving.
        let maxAttempts = 6
        for attempt in 1...maxAttempts {
            guard sessionBootEpoch == requestEpoch else { return }
            syncStatusCenter.setParticipantJoin(.joining(attempt: attempt, maxAttempts: maxAttempts))
            do { try await session.engine.fetchChanges() }
            catch { print("[Sharing] participant fetch \(attempt) error: \(error)") }
            guard sessionBootEpoch == requestEpoch else { return }
            let weeks = session.store.records(ofType: HouseholdRecordType.week.recordTypeName).count
            let meals = session.store.records(ofType: HouseholdRecordType.weekMeal.recordTypeName).count
            let recipes = session.store.records(ofType: HouseholdRecordType.recipe.recordTypeName).count
            print("[Sharing] participant fetch \(attempt): weeks=\(weeks) meals=\(meals) recipes=\(recipes)")
            if weeks > 0 {
                syncStatusCenter.setParticipantJoin(.joined)
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        // Retry budget exhausted and the shared household still looks empty — a slow join
        // is indistinguishable from an empty household without this: surface it distinctly
        // rather than letting the join silently give up (simmersmith-qrt).
        guard sessionBootEpoch == requestEpoch else { return }
        syncStatusCenter.setParticipantJoin(.stalled)
    }
}
#endif
