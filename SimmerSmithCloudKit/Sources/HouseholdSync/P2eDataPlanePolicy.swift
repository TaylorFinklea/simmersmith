#if canImport(CloudKit)
import Foundation
import CloudKit

/// Whether a household engine is still non-authoritative cached content or has completed
/// reconciliation. P2e keeps cached sessions blanket-denied for destructive work; P2f replaces
/// this with exact authority checks.
public enum HouseholdDataPlaneMode: Equatable, Sendable {
    case normal
    case cached
}

public enum HouseholdDataPlaneOperation: Equatable, Sendable {
    case save
    case delete
    case deleteCascading
    case zoneRecreation
}

/// The result of a data-plane operation that requires a reconciled household session.
/// Callers can present a retry affordance without treating a denied destructive request as a
/// successful no-op.
public enum HouseholdDataPlaneResult: Error, Equatable, LocalizedError, Sendable {
    case allowed
    case notAuthoritative
    case durabilityFailure(MirrorDurabilityFailure)

    public var errorDescription: String? {
        switch self {
        case .allowed:
            return nil
        case .notAuthoritative:
            return "Finish household reconciliation before trying that again."
        case .durabilityFailure(let failure):
            return failure.message
        }
    }
}

/// A capability owned by exactly one `HouseholdSession` and passed to that session's engine.
/// Cached sessions begin denied; AppState promotes only the still-current session after its first
/// fetch. Revocation is terminal, so repositories that retain a torn-down engine remain denied.
public final class HouseholdSessionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var isAuthoritative: Bool
    private var isRevoked = false

    public init(initiallyAuthoritative: Bool) {
        self.isAuthoritative = initiallyAuthoritative
    }

    public func result(for operation: HouseholdDataPlaneOperation) -> HouseholdDataPlaneResult {
        switch operation {
        case .save:
            return lock.withLock { isRevoked ? .notAuthoritative : .allowed }
        case .delete, .deleteCascading, .zoneRecreation:
            return lock.withLock {
                isAuthoritative && !isRevoked ? .allowed : .notAuthoritative
            }
        }
    }

    /// Returns true only for the one denied-to-authoritative transition.
    @discardableResult
    public func promote() -> Bool {
        lock.withLock {
            guard !isRevoked, !isAuthoritative else { return false }
            isAuthoritative = true
            return true
        }
    }

    /// Teardown is irreversible for this object. A successor receives a fresh authority object.
    public func revoke() {
        lock.withLock {
            isRevoked = true
            isAuthoritative = false
        }
    }

    public var allowsAuthoritativeOperations: Bool {
        lock.withLock { isAuthoritative && !isRevoked }
    }
}

public enum HouseholdDataPlanePolicy {
    public static func allows(
        _ operation: HouseholdDataPlaneOperation,
        mode: HouseholdDataPlaneMode
    ) -> Bool {
        switch (mode, operation) {
        case (.cached, .delete), (.cached, .deleteCascading),
             (.cached, .zoneRecreation):
            return false
        default:
            return true
        }
    }
}

/// A cached or recovered session could not durably append its local intent before a mutation.
/// P1 continues with its historical diagnostic-only mirror behavior; cache-first sessions must
/// stop before modifying their store because a later restart could otherwise lose that intent.
public struct MirrorDurabilityFailure: Equatable, Sendable {
    public let message: String

    public init(message: String = "Couldn't save this cached change safely. Retry when storage is available.") {
        self.message = message
    }
}

public enum MirrorParticipantFetchProof: String, Codable, Equatable, Sendable {
    case verified
    case failed
    case unverified
}

/// Versioned checkpoint evidence. A Boolean `zoneEnsured` from an old participant build is
/// never equivalent to this proof: only the matching successful fetch event can create it.
public struct MirrorParticipantFetchCheckpointProof: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let fetch: MirrorParticipantFetchProof

    public init(fetch: MirrorParticipantFetchProof) {
        self.formatVersion = Self.currentFormatVersion
        self.fetch = fetch
    }

    public var isVerified: Bool {
        formatVersion == Self.currentFormatVersion && fetch == .verified
    }
}

/// Production event-to-proof seam. A participant earns zone coverage only from the matching
/// shared-zone completion event with no CloudKit error; local mutations and unrelated zones do
/// not establish coverage.
public enum MirrorParticipantFetchObservation {
    public static func proof(
        role: MirrorRole,
        expectedZoneID: CKRecordZone.ID,
        fetchedZoneID: CKRecordZone.ID?,
        error: CKError?
    ) -> MirrorParticipantFetchProof {
        guard role == .participant else { return .verified }
        guard let fetchedZoneID, fetchedZoneID == expectedZoneID else { return .unverified }
        return error == nil ? .verified : .failed
    }
}

/// The owner checkpoint's zone proof remains unchanged. A participant only gains the proof after
/// a successful shared-zone fetch, never merely because a local save happened.
public enum MirrorZoneEnsuredPolicy {
    public static func value(
        role: MirrorRole,
        recoveredZoneEnsured: Bool,
        checkpointProof: MirrorParticipantFetchCheckpointProof? = nil,
        fetch: MirrorParticipantFetchProof
    ) -> Bool {
        switch role {
        case .owner:
            return recoveredZoneEnsured
        case .participant:
            return checkpointProof?.isVerified == true || fetch == .verified
        }
    }
}
#endif
