#if canImport(CloudKit)
import Darwin
import Foundation
import CloudKit
import CloudKitProvisioning
import HouseholdSync
import HouseholdRecords

enum DurableLifecycleFileSupport {
    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try synchronize(parent)
        try data.write(to: url, options: .atomic)
        try synchronize(url)
        try synchronize(parent)
    }

    static func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        try synchronize(url.deletingLastPathComponent())
    }

    static func synchronize(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

struct DurableParticipantMarker: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    enum Error: Swift.Error {
        case invalid
        case accountMismatch
    }

    let formatVersion: Int
    let zoneName: String
    let ownerName: String
    let accountRecordName: String
    let integrityDigest: String

    init(zoneName: String, ownerName: String, accountRecordName: String) throws {
        formatVersion = Self.currentFormatVersion
        self.zoneName = zoneName
        self.ownerName = ownerName
        self.accountRecordName = accountRecordName
        integrityDigest = Self.digest(
            formatVersion: Self.currentFormatVersion,
            zoneName: zoneName,
            ownerName: ownerName,
            accountRecordName: accountRecordName)
        try validate()
    }

    var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
    }

    func validated(for accountRecordName: String) throws -> Self {
        try validate()
        guard self.accountRecordName == accountRecordName else { throw Error.accountMismatch }
        return self
    }

    fileprivate func validate() throws {
        guard formatVersion == Self.currentFormatVersion,
              !zoneName.isEmpty,
              !ownerName.isEmpty,
              !accountRecordName.isEmpty,
              integrityDigest == Self.digest(
                formatVersion: formatVersion,
                zoneName: zoneName,
                ownerName: ownerName,
                accountRecordName: accountRecordName) else {
            throw Error.invalid
        }
    }

    private static func digest(
        formatVersion: Int,
        zoneName: String,
        ownerName: String,
        accountRecordName: String
    ) -> String {
        let value = "\(formatVersion)\u{0}\(zoneName)\u{0}\(ownerName)\u{0}\(accountRecordName)"
        return ShadowMirrorDigest.sha256(Data(value.utf8))
    }
}

final class ParticipantMarkerStore: @unchecked Sendable {
    enum Error: Swift.Error {
        case malformed
    }

    let fileURL: URL
    private let lock = NSLock()

    private struct Storage: Codable {
        let state: String
        let marker: DurableParticipantMarker?

        static func active(_ marker: DurableParticipantMarker) -> Self {
            Self(state: "active", marker: marker)
        }

        static let cleared = Self(state: "cleared", marker: nil)
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var hasDurableState: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() throws -> DurableParticipantMarker? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let storage = try JSONDecoder().decode(
                Storage.self,
                from: Data(contentsOf: fileURL))
            switch (storage.state, storage.marker) {
            case ("active", .some(let marker)):
                try marker.validate()
                return marker
            case ("cleared", .none):
                return nil
            default:
                throw Error.malformed
            }
        } catch {
            throw Error.malformed
        }
    }

    func save(_ marker: DurableParticipantMarker) throws {
        lock.lock(); defer { lock.unlock() }
        try marker.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableLifecycleFileSupport.write(
            try encoder.encode(Storage.active(marker)),
            to: fileURL)
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try DurableLifecycleFileSupport.write(
            try encoder.encode(Storage.cleared),
            to: fileURL)
    }
}

final class DurableLifecycleFlagStore: @unchecked Sendable {
    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    func set() throws {
        lock.lock(); defer { lock.unlock() }
        try DurableLifecycleFileSupport.write(Data("required".utf8), to: fileURL)
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        try DurableLifecycleFileSupport.remove(fileURL)
    }
}

/// Durable boundary between CloudKit share acceptance and owner→participant handoff. The
/// account-bound marker must exist before owner parking or participant publication so a crash at
/// any later instruction can only resume toward the accepted shared zone.
@MainActor
struct AcceptedShareAdoptionBoundaryRunner {
    enum Outcome: Equatable {
        case adopted(publicationEpoch: Int)
        case markerPersistenceFailed
        case adoptionFailed
    }

    let persistMarker: () -> Bool
    let adoptSharedZone: () async -> Int?

    func run() async -> Outcome {
        guard persistMarker() else { return .markerPersistenceFailed }
        guard let publicationEpoch = await adoptSharedZone() else { return .adoptionFailed }
        return .adopted(publicationEpoch: publicationEpoch)
    }
}

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

    struct ParticipantMarker: Equatable {
        let zoneName: String
        let ownerName: String
        let accountRecordName: String
        let requiresDurableMigration: Bool
        var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }

        init(
            zoneName: String,
            ownerName: String,
            accountRecordName: String = "",
            requiresDurableMigration: Bool = false
        ) {
            self.zoneName = zoneName
            self.ownerName = ownerName
            self.accountRecordName = accountRecordName
            self.requiresDurableMigration = requiresDurableMigration
        }
    }

    private static let markerZoneNameKey = "sharing.participant.zoneName.v1"
    private static let markerOwnerNameKey = "sharing.participant.ownerName.v1"

    /// UI-only marker presence. Boot code must use the account-bound overload below.
    func loadParticipantMarker() -> ParticipantMarker? {
        if participantMarkerStore.hasDurableState {
            guard let marker = try? participantMarkerStore.load() else { return nil }
            return ParticipantMarker(
                zoneName: marker.zoneName,
                ownerName: marker.ownerName,
                accountRecordName: marker.accountRecordName)
        }
        let d = UserDefaults.standard
        guard let zoneName = d.string(forKey: Self.markerZoneNameKey), !zoneName.isEmpty,
              let ownerName = d.string(forKey: Self.markerOwnerNameKey), !ownerName.isEmpty
        else { return nil }
        return ParticipantMarker(
            zoneName: zoneName,
            ownerName: ownerName,
            requiresDurableMigration: true)
    }

    /// Boot-only marker load. Durable markers must match the CloudKit-proved current account.
    /// Legacy UserDefaults data remains untrusted and cannot select a cached scope; it is bound
    /// to the current account only after a direct shared-zone fetch proves access.
    func loadParticipantMarker(accountRecordName: String) throws -> ParticipantMarker? {
        if participantMarkerStore.hasDurableState {
            guard let marker = try participantMarkerStore.load() else { return nil }
            let validated = try marker.validated(for: accountRecordName)
            return ParticipantMarker(
                zoneName: validated.zoneName,
                ownerName: validated.ownerName,
                accountRecordName: validated.accountRecordName)
        }
        let defaults = UserDefaults.standard
        guard let zoneName = defaults.string(forKey: Self.markerZoneNameKey), !zoneName.isEmpty,
              let ownerName = defaults.string(forKey: Self.markerOwnerNameKey), !ownerName.isEmpty
        else { return nil }
        return ParticipantMarker(
            zoneName: zoneName,
            ownerName: ownerName,
            accountRecordName: accountRecordName,
            requiresDurableMigration: true)
    }

    @discardableResult
    func saveParticipantMarker(_ marker: ParticipantMarker) -> Bool {
        do {
            let durable = try DurableParticipantMarker(
                zoneName: marker.zoneName,
                ownerName: marker.ownerName,
                accountRecordName: marker.accountRecordName)
            try participantMarkerStore.save(durable)
        } catch {
            return false
        }
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.markerZoneNameKey)
        d.removeObject(forKey: Self.markerOwnerNameKey)
        _ = d.synchronize()
        return true
    }

    @discardableResult
    func clearParticipantMarker() -> Bool {
        do {
            try participantMarkerStore.clear()
        } catch {
            return false
        }
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.markerZoneNameKey)
        d.removeObject(forKey: Self.markerOwnerNameKey)
        _ = d.synchronize()
        return true
    }

    /// CloudKit revoked/deleted the participant zone. Clear durable adoption before advancing
    /// the epoch and dropping repos; teardown revokes the old session's authority first.
    func handleParticipantRevocation() {
        _ = handleHouseholdLifecycleEvent(
            .participantRevocation,
            scope: householdSession?.engine.activeMirrorScopeSnapshot)
    }

    func handleHouseholdAccountChange() {
        _ = handleHouseholdLifecycleEvent(
            .accountBoundary(.unknown),
            scope: nil)
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
    /// system share sheet. Returns nil only when there is genuinely no owner session; a cached
    /// authority denial stays typed so Settings cannot present a false-success share controller.
    func prepareOwnerShare(title: String) async throws -> OwnerSharePackage? {
        guard let session = householdSession, session.role.isOwner else { return nil }
        let requestEpoch = sessionBootEpoch
        guard isCurrentAuthoritativeHouseholdSession(session, requestEpoch: requestEpoch) else {
            let denial = CachedHouseholdSystemOperationResult.retryableNotAuthoritative
            lastErrorMessage = denial.errorDescription
            throw denial
        }
        let prepared: HouseholdSystemOperationExecutor.ZoneWideShare
        do {
            prepared = try await householdSystemOperationExecutor.prepareZoneWideShare(
                session.householdID,
                title
            )
        } catch {
            guard isCurrentAuthoritativeHouseholdSession(session, requestEpoch: requestEpoch) else {
                throw CachedHouseholdSystemOperationResult.retryableNotAuthoritative
            }
            lastErrorMessage = "Couldn't prepare the share: \(error.localizedDescription)"
            throw error
        }
        guard isCurrentAuthoritativeHouseholdSession(session, requestEpoch: requestEpoch) else {
            throw CachedHouseholdSystemOperationResult.retryableNotAuthoritative
        }
        return OwnerSharePackage(share: prepared.share, container: prepared.container)
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
            _ = await self.completePendingHouseholdLifecycleBoundary()
            guard self.householdLifecycleAllowsEntry() else { return }
            let effectiveEpoch = self.sessionBootEpoch
            guard self.completePendingShadowRootRetirementIfNeeded() else {
                self.householdLaunchPhase = .resolving
                self.householdAuthority = .intervention(
                    message: "Finish retiring the previous household before joining a share.")
                return
            }
            let accountRecordName = try? await HouseholdShareFlow().currentUserRecordName()
            guard self.sessionBootEpoch == effectiveEpoch,
                  self.householdLifecycleAllowsEntry(),
                  let accountRecordName,
                  !accountRecordName.isEmpty else {
                self.householdLaunchPhase = .resolving
                self.householdAuthority = .intervention(
                    message: "Couldn't verify the current iCloud account before joining.")
                return
            }
            guard let metadata = PendingShareInbox.shared.take() else { return }
            print("[Sharing] processPendingShare: draining metadata, role=\(metadata.participantRole.rawValue) container=\(metadata.containerIdentifier)")
            await self.bootParticipantSession(
                accepting: metadata,
                requestEpoch: effectiveEpoch,
                accountRecordName: accountRecordName)
        }.value
    }

    /// Accept a zone-wide CKShare and adopt the owner's household.
    ///
    /// Must only be called from within a `sessionBootQueue` op (simmersmith-0gf) — it is called
    /// directly by `ensureSessionBootOp()`'s participant-first check and by
    /// `processPendingShare()`'s queued op. It must NOT itself enqueue: both of those callers
    /// already run inside the queue's chain, so a nested `enqueue(...).value` here would await
    /// a task that can only run after itself — a self-deadlock.
    func bootParticipantSession(
        accepting metadata: CKShare.Metadata,
        requestEpoch: Int,
        accountRecordName: String
    ) async {
        guard householdLifecycleAllowsEntry() else { return }
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
        guard completePendingShadowRootRetirementIfNeeded() else {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Finish retiring the previous household before joining a share.")
            PendingShareInbox.shared.deposit(metadata)
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
            guard householdLifecycleAllowsEntry() else { return }
            let participantMarker = ParticipantMarker(
                zoneName: zoneID.zoneName,
                ownerName: zoneID.ownerName,
                accountRecordName: accountRecordName)
            let boundary = AcceptedShareAdoptionBoundaryRunner(
                persistMarker: { [self] in
                    saveParticipantMarker(participantMarker)
                },
                adoptSharedZone: { [self] in
                    await adoptSharedZone(
                        zoneID,
                        requestEpoch: requestEpoch,
                        accountRecordName: accountRecordName)
                })
            switch await boundary.run() {
            case .markerPersistenceFailed:
                // No owner/session mutation has happened yet. Preserve both the owner and the
                // accepted metadata so a later retry can establish the durable boundary first.
                PendingShareInbox.shared.deposit(metadata)
                lastErrorMessage = "Couldn't durably remember the shared household — will retry."
                return
            case .adoptionFailed:
                // Keep the durable marker. If owner parking already occurred, relaunch must
                // continue toward this participant scope rather than reopening the owner.
                print("[Sharing] abort: adoption handoff did not complete — marker retained")
                PendingShareInbox.shared.deposit(metadata)
                lastErrorMessage = "Couldn't finish joining the shared household — will retry."
                return
            case .adopted(let adoptionEpoch):
                guard sessionBootEpoch == adoptionEpoch else { return }
            }
            print("[Sharing] marker saved + adopted — participant booted")
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
    func bootParticipantSession(
        reusing marker: ParticipantMarker,
        requestEpoch: Int,
        accountRecordName: String
    ) async {
        guard marker.accountRecordName == accountRecordName,
              householdLifecycleAllowsEntry() else { return }
        guard completePendingShadowRootRetirementIfNeeded() else {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Finish retiring the previous household before reconnecting.")
            return
        }
        let candidate: MirrorBootstrapCandidate?
        let recoveryCandidate: MirrorRecoveryCandidate?
        if cacheFirstLaunchEnabled, !marker.requiresDurableMigration {
            let selection = bootstrapSelection(
                accountRecordName: accountRecordName,
                request: .participant(
                    accountRecordName: accountRecordName,
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
        guard householdLifecycleAllowsEntry() else { return }
        let adoptedEpoch = await adoptSharedZone(
            marker.zoneID,
            requestEpoch: requestEpoch,
            accountRecordName: accountRecordName,
            bootstrapCandidate: candidate,
            recoveryCandidate: recoveryCandidate)
        guard let adoptedEpoch,
              sessionBootEpoch == adoptedEpoch,
              householdLifecycleAllowsEntry() else { return }
        if marker.requiresDurableMigration,
           !saveParticipantMarker(ParticipantMarker(
                zoneName: marker.zoneName,
                ownerName: marker.ownerName,
                accountRecordName: accountRecordName)) {
            _ = handleHouseholdLifecycleEvent(
                .participantRevocation,
                scope: householdSession?.engine.activeMirrorScopeSnapshot)
        }
    }

    /// Boot a participant `HouseholdSession` on the owner's shared zone, fetch, and wire repos.
    /// Returns the publication epoch only after the participant is fully wired. A warm owner
    /// handoff advances the epoch before the first participant construction await.
    @discardableResult
    private func adoptSharedZone(
        _ zoneID: CKRecordZone.ID,
        requestEpoch: Int,
        accountRecordName: String,
        bootstrapCandidate: MirrorBootstrapCandidate? = nil,
        recoveryCandidate: MirrorRecoveryCandidate? = nil
    ) async -> Int? {
        // The entry check precedes the warm swap. A queued/stale adoption must not detach the
        // current household or construct a competing participant session.
        guard sessionBootEpoch == requestEpoch,
              completePendingShadowRootRetirementIfNeeded() else { return nil }
        let publicationEpoch: Int
        if let currentSession = householdSession, currentSession.role.isOwner {
            // This is the only retained lifecycle retry: do not construct or publish a
            // participant until the exact owner writer has durably parked its scope.
            guard teardownHouseholdSession(
                clearShadowRoot: false,
                parkOwnerScopeForAdoption: true
            ) else { return nil }
            publicationEpoch = sessionBootEpoch
        } else if householdSession != nil || bootingHouseholdSession != nil {
            _ = beginEpochFirstHouseholdTransition(clearPersonalData: false)
            publicationEpoch = sessionBootEpoch
        } else {
            publicationEpoch = requestEpoch
        }
        guard sessionBootEpoch == publicationEpoch,
              householdLifecycleAllowsEntry() else { return nil }

        let householdID = ParticipantHouseholdIDPolicy.resolve(
            cachedHouseholdID: bootstrapCandidate?.bootstrap.scope.householdID,
            recoveryHouseholdID: recoveryCandidate?.plan.scope.householdID,
            fallbackZoneName: zoneID.zoneName)
        let session: HouseholdSession
        do {
            session = try HouseholdSession(
                householdID: householdID,
                role: .participant(sharedZoneID: zoneID),
                initialMirrorScope: MirrorScope(
                    accountRecordName: accountRecordName,
                    zoneOwnerName: zoneID.ownerName,
                    zoneName: zoneID.zoneName,
                    householdID: householdID,
                    role: .participant,
                    databaseScope: .shared),
                syncStatusCenter: self.syncStatusCenter,
                bootstrapCandidate: bootstrapCandidate,
                recoveryCandidate: recoveryCandidate)
        } catch {
            householdLaunchPhase = .resolving
            householdAuthority = .intervention(
                message: "Couldn't establish an exact shared-household cache identity.")
            return nil
        }
        bootingHouseholdSession = session
        installLifecycleDispatcher(for: session, epoch: publicationEpoch)
        guard sessionBootEpoch == publicationEpoch, householdLifecycleAllowsEntry() else {
            bootingHouseholdSession = nil
            session.detach()
            return nil
        }
        // Cached candidates already contain the local household projection. Keep it visible
        // while the independent first reconciliation runs; the no-cache path retains its
        // participant-first fetch/retry order.
        await session.start()
        // Recovery-only durable intents cannot render or continue participant discovery until
        // their exact nil-state full fetch and atomic overlay have succeeded.
        guard householdLifecycleAllowsEntry(),
              !session.isRecoveryOnly || session.recoveryOnlyFetchSucceeded else {
            if bootingHouseholdSession === session { bootingHouseholdSession = nil }
            session.detach()
            return nil
        }
        guard householdLifecycleAllowsEntry(),
              DirectHouseholdBootstrapPolicy.shouldContinueAfterInitialStart(
            isCachedBootstrap: session.isCachedBootstrap,
            hasCurrentAuthority: session.hasCurrentAuthority
        ) else {
            if bootingHouseholdSession === session { bootingHouseholdSession = nil }
            session.detach()
            return nil
        }
        if session.isCachedBootstrap {
            guard sessionBootEpoch == publicationEpoch,
                  householdLifecycleAllowsEntry() else {
                session.detach()
                return nil
            }
            await wireHouseholdRepositories(session: session, requestEpoch: publicationEpoch)
            guard sessionBootEpoch == publicationEpoch,
                  householdLifecycleAllowsEntry(),
                  householdSession === session else {
                session.detach()
                return nil
            }
            publishCachedHouseholdAuthority(session: session, epoch: publicationEpoch)
            guard sessionBootEpoch == publicationEpoch, householdSession === session else { return nil }
            householdLaunchPhase = .ready
            scheduleCachedPrivatePlaneOpen(session: session, requestEpoch: publicationEpoch)
            scheduleCachedReconciliation(session: session, requestEpoch: publicationEpoch)
            return publicationEpoch
        }
        await participantInitialFetch(session: session, requestEpoch: publicationEpoch)

        // simmersmith-0gf blocking-finding fix: re-check right before the commit point — a
        // sign-out could have landed during any of the awaits above (session.start(),
        // participantInitialFetch()). Detach (don't wire) a session built for a now-stale
        // request rather than resurrecting it post-teardown.
        guard sessionBootEpoch == publicationEpoch,
              householdLifecycleAllowsEntry() else {
            session.detach()
            return nil
        }

        await wireHouseholdRepositories(session: session, requestEpoch: publicationEpoch)
        guard sessionBootEpoch == publicationEpoch,
              householdLifecycleAllowsEntry(),
              householdSession === session else {
            session.detach()
            return nil
        }
        installAuthorityDispatcher(for: session, epoch: publicationEpoch)
        guard sessionBootEpoch == publicationEpoch, householdSession === session else { return nil }
        // Noncached participants complete the exact P1 fetch/retry path before publication.
        publishDirectHouseholdAuthority(session: session, epoch: publicationEpoch)
        personalDataReadiness = session.privateStore == nil ? .unavailable : .ready
        householdLaunchPhase = .ready
        return publicationEpoch
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
