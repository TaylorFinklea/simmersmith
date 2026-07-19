#if canImport(CloudKit)
import CloudKit
import Foundation

public enum HouseholdSyncAccountBoundary: String, Codable, Equatable, Sendable {
    case signedOut
    case switchedAccounts
    case unknown
}

/// Engine-observed lifecycle boundaries remain typed so AppState can choose whole-root versus
/// exact-scope teardown without inferring intent from a generic store-change callback.
public enum HouseholdSyncLifecycleEvent: Equatable, Sendable {
    case participantRevocation
    case unexpectedOwnerZoneDeletion
    case accountBoundary(HouseholdSyncAccountBoundary)
}

public enum HouseholdSyncLifecyclePolicy {
    public static func eventForZoneDeletion(
        ownsZone: Bool,
        activeZoneID: CKRecordZone.ID,
        deletedZoneIDs: [CKRecordZone.ID]
    ) -> HouseholdSyncLifecycleEvent? {
        guard deletedZoneIDs.contains(activeZoneID) else { return nil }
        return ownsZone ? .unexpectedOwnerZoneDeletion : .participantRevocation
    }
}

/// Immutable, thread-safe exact scope captured only after the package validates its complete
/// account/role/database/zone identity. Lifecycle handlers may read it synchronously after the
/// engine freezes; it is never reconstructed from the zone callback alone.
final class HouseholdSyncActiveMirrorScopeSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: MirrorScope?

    var value: MirrorScope? {
        lock.withLock { storage }
    }

    func installValidated(
        _ scope: MirrorScope,
        expectedZoneID: CKRecordZone.ID,
        ownsZone: Bool
    ) throws {
        try scope.validate()
        guard scope.zoneName == expectedZoneID.zoneName,
              scope.zoneOwnerName == expectedZoneID.ownerName,
              ownsZone == (scope.role == .owner),
              (ownsZone && scope.databaseScope == .private)
                || (!ownsZone && scope.databaseScope == .shared) else {
            throw MirrorCheckpointError.scopeMismatch
        }
        try lock.withLock {
            guard storage == nil || storage == scope else {
                throw MirrorCheckpointError.scopeMismatch
            }
            storage = scope
        }
    }
}

/// One-way synchronous engine fence. The first lifecycle event revokes session authority and
/// fences cache mutation before any callback can run. Concurrent later events wait for that first
/// fence and are still delivered distinctly so a stronger account boundary cannot be lost.
final class HouseholdSyncLifecycleFence: @unchecked Sendable {
    private enum State {
        case active
        case freezing
        case frozen
    }

    private let authority: HouseholdSessionAuthority
    private let condition = NSCondition()
    private var state: State = .active
    private var activeActivityCount = 0

    init(authority: HouseholdSessionAuthority) {
        self.authority = authority
    }

    var isFrozen: Bool {
        condition.withLock { state != .active }
    }

    /// Enters a short cache/store mutation section. A lifecycle boundary that wins first rejects
    /// the entry; a mutation already inside is allowed to finish before the callback is emitted.
    func beginActivity() -> Bool {
        condition.withLock {
            guard state == .active else { return false }
            activeActivityCount += 1
            return true
        }
    }

    func endActivity() {
        condition.withLock {
            guard activeActivityCount > 0 else { return }
            activeActivityCount -= 1
            if activeActivityCount == 0 {
                condition.broadcast()
            }
        }
    }

    /// An explicit CloudKit operation may suspend while a lifecycle callback freezes this
    /// session. Its transport result is authoritative only when the same session is still active
    /// after that suspension; otherwise callers must not advance into recovery/apply work.
    func performExplicitOperation<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard !isFrozen else { throw HouseholdDataPlaneResult.notAuthoritative }
        let result = try await operation()
        guard !isFrozen else { throw HouseholdDataPlaneResult.notAuthoritative }
        return result
    }

    func transition(
        to event: HouseholdSyncLifecycleEvent,
        fenceCacheMutation: @Sendable () -> Void,
        emit: @Sendable (HouseholdSyncLifecycleEvent) -> Void
    ) {
        let ownsFreeze = condition.withLock { () -> Bool in
            while state == .freezing {
                condition.wait()
            }
            guard state == .active else { return false }
            state = .freezing
            while activeActivityCount > 0 {
                condition.wait()
            }
            return true
        }

        if ownsFreeze {
            authority.revoke()
            fenceCacheMutation()
            condition.withLock {
                state = .frozen
                condition.broadcast()
            }
        }
        emit(event)
    }
}
#endif
