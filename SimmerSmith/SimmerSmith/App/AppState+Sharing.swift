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
        guard let session = householdSession, session.role.isOwner else { return nil }
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
    func processPendingShare() async {
        guard let metadata = PendingShareInbox.shared.take() else { return }
        print("[Sharing] processPendingShare: draining metadata, role=\(metadata.participantRole.rawValue) container=\(metadata.containerIdentifier)")
        await bootParticipantSession(accepting: metadata)
    }

    /// Accept a zone-wide CKShare and adopt the owner's household.
    func bootParticipantSession(accepting metadata: CKShare.Metadata) async {
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
            await adoptSharedZone(zoneID)
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
    func bootParticipantSession(reusing marker: ParticipantMarker) async {
        await adoptSharedZone(marker.zoneID)
    }

    /// Boot a participant `HouseholdSession` on the owner's shared zone, fetch, and wire repos.
    private func adoptSharedZone(_ zoneID: CKRecordZone.ID) async {
        // Warm swap: detach an already-booted owner engine (KEEP its state token so the
        // parked solo zone survives a future un-adopt), then replace the session.
        householdSession?.detach()
        // simmersmith-qrt (backstop): the warm owner→participant swap must not carry the
        // pre-swap session's stale failure/last-synced state into the new session's status
        // surface. participantJoin is overwritten by the join loop below either way; this
        // clears the rest. Mirrors teardownHouseholdSession()'s reset.
        syncStatusCenter.reset()

        let session = HouseholdSession(
            householdID: zoneID.zoneName, role: .participant(sharedZoneID: zoneID),
            syncStatusCenter: self.syncStatusCenter
        )
        // start() already runs one fetchChanges(); its raced .offline is non-terminal here.
        await session.start()
        await participantInitialFetch(session: session)
        await wireHouseholdRepositories(session: session)
    }

    /// The make-or-break post-accept fetch: the accepting device usually receives no push
    /// for its own acceptance, and `accept()` can return before the server finishes creating
    /// the zone — so fetch once, then again after a short backoff to close the race.
    private func participantInitialFetch(session: HouseholdSession) async {
        // A freshly-accepted shared zone can take several fetch cycles to fully propagate to
        // this device — the accept can return before the server finishes, and the device gets
        // no push for its own acceptance. Retry until the owner's weeks land (or attempts run
        // out), logging record counts so a TestFlight run reveals whether data is arriving.
        let maxAttempts = 6
        for attempt in 1...maxAttempts {
            syncStatusCenter.setParticipantJoin(.joining(attempt: attempt, maxAttempts: maxAttempts))
            do { try await session.engine.fetchChanges() }
            catch { print("[Sharing] participant fetch \(attempt) error: \(error)") }
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
        syncStatusCenter.setParticipantJoin(.stalled)
    }
}
#endif
