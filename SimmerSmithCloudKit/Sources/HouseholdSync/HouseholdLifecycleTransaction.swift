#if canImport(CloudKit)
import Darwin
import Foundation

/// A crash-replayable lifecycle boundary. The transaction file is supplied by the app and must
/// live outside the shadow-mirror root so whole-root retirement cannot delete the pending work.
public struct HouseholdLifecycleTransaction: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public enum Kind: String, Codable, Equatable, Sendable {
        case accountBoundary
        case participantRevocation
        case unexpectedOwnerZoneDeletion
        case factoryReset
    }

    public enum Error: Swift.Error, Equatable {
        case invalidScope
        case invalidRemoteAccount
        case invalidIntegrity
        case unsupportedFormatVersion
    }

    public let formatVersion: Int
    public let identifier: UUID
    public let kind: Kind
    public let scope: MirrorScope?
    /// CloudKit account that authorized a remote-destructive factory reset. Exact-scope events
    /// bind their account through `scope`; non-remote whole-root boundaries carry neither.
    public let remoteAccountRecordName: String?
    public let integrityDigest: String

    public init(
        identifier: UUID = UUID(),
        kind: Kind,
        scope: MirrorScope?,
        remoteAccountRecordName: String? = nil
    ) throws {
        self.formatVersion = Self.currentFormatVersion
        self.identifier = identifier
        self.kind = kind
        self.scope = scope
        self.remoteAccountRecordName = remoteAccountRecordName
        self.integrityDigest = try Self.makeIntegrityDigest(
            formatVersion: Self.currentFormatVersion,
            identifier: identifier,
            kind: kind,
            scope: scope,
            remoteAccountRecordName: remoteAccountRecordName)
        try validate()
    }

    fileprivate func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw Error.unsupportedFormatVersion
        }
        guard integrityDigest == (try Self.makeIntegrityDigest(
            formatVersion: formatVersion,
            identifier: identifier,
            kind: kind,
            scope: scope,
            remoteAccountRecordName: remoteAccountRecordName)) else {
            throw Error.invalidIntegrity
        }
        switch kind {
        case .accountBoundary:
            guard scope == nil else { throw Error.invalidScope }
            guard remoteAccountRecordName == nil else { throw Error.invalidRemoteAccount }
        case .factoryReset:
            guard scope == nil else { throw Error.invalidScope }
            guard let remoteAccountRecordName,
                  !remoteAccountRecordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Error.invalidRemoteAccount }
        case .participantRevocation:
            guard let scope, scope.role == .participant, scope.databaseScope == .shared else {
                throw Error.invalidScope
            }
            guard remoteAccountRecordName == nil else { throw Error.invalidRemoteAccount }
            try scope.validate()
        case .unexpectedOwnerZoneDeletion:
            guard let scope, scope.role == .owner, scope.databaseScope == .private else {
                throw Error.invalidScope
            }
            guard remoteAccountRecordName == nil else { throw Error.invalidRemoteAccount }
            try scope.validate()
        }
    }

    private static func makeIntegrityDigest(
        formatVersion: Int,
        identifier: UUID,
        kind: Kind,
        scope: MirrorScope?,
        remoteAccountRecordName: String?
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ShadowMirrorDigest.sha256(try encoder.encode(IntegrityPayload(
            formatVersion: formatVersion,
            identifier: identifier,
            kind: kind,
            scope: scope,
            remoteAccountRecordName: remoteAccountRecordName)))
    }

    private struct IntegrityPayload: Codable {
        let formatVersion: Int
        let identifier: UUID
        let kind: Kind
        let scope: MirrorScope?
        let remoteAccountRecordName: String?
    }
}

/// Serializes one pending lifecycle transaction at a caller-owned URL. A valid pending boundary
/// is never replaced by different work, and malformed persisted bytes are surfaced as pending
/// intervention rather than being interpreted as an empty store.
public final class HouseholdLifecycleTransactionStore: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable {
        case malformedTransaction
        case transactionConflict
    }

    public let fileURL: URL

    private let lock = NSLock()
    private let pathSynchronizer: (URL) throws -> Void

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.pathSynchronizer = Self.synchronizePath
    }

    init(
        fileURL: URL,
        pathSynchronizer: @escaping (URL) throws -> Void
    ) {
        self.fileURL = fileURL
        self.pathSynchronizer = pathSynchronizer
    }

    /// Returns a valid transaction only after synchronizing both its bytes and directory entry.
    /// This re-establishes durability when an earlier atomic write became visible but its final
    /// parent-directory fsync failed.
    public func pending() throws -> HouseholdLifecycleTransaction? {
        try lock.withLock {
            guard let transaction = try pendingLocked() else {
                let parent = fileURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: parent.path) {
                    try pathSynchronizer(parent)
                }
                return nil
            }
            try synchronizeVisibleTransactionLocked()
            return transaction
        }
    }

    /// Persists new work before any invalidation or server mutation. Re-recording the exact same
    /// value is idempotent; a different pending boundary must be completed instead of overwritten.
    public func begin(_ transaction: HouseholdLifecycleTransaction) throws {
        try lock.withLock {
            try transaction.validate()
            if let existing = try pendingLocked() {
                guard existing == transaction else { throw Error.transactionConflict }
                try synchronizeVisibleTransactionLocked()
                return
            }
            try writeDurable(
                try Self.encoder.encode(transaction),
                to: fileURL)
        }
    }

    /// Atomically advances matching pending work to a caller-selected replacement. The caller
    /// owns lifecycle precedence; the store only provides compare-and-swap durability.
    public func replace(
        expected: HouseholdLifecycleTransaction,
        with replacement: HouseholdLifecycleTransaction
    ) throws {
        try lock.withLock {
            guard let existing = try pendingLocked(), existing == expected else {
                throw Error.transactionConflict
            }
            try replacement.validate()
            try writeDurable(
                try Self.encoder.encode(replacement),
                to: fileURL)
        }
    }

    /// Removes only the matching boundary and synchronizes the parent directory. Absence is an
    /// idempotent success because a crash may occur after deletion became durable but before the
    /// caller observed completion.
    public func complete(_ transaction: HouseholdLifecycleTransaction) throws {
        try lock.withLock {
            let parent = fileURL.deletingLastPathComponent()
            guard let existing = try pendingLocked() else {
                if FileManager.default.fileExists(atPath: parent.path) {
                    try pathSynchronizer(parent)
                }
                return
            }
            guard existing == transaction else { throw Error.transactionConflict }
            try FileManager.default.removeItem(at: fileURL)
            try pathSynchronizer(parent)
        }
    }

    private func synchronizeVisibleTransactionLocked() throws {
        try pathSynchronizer(fileURL)
        try pathSynchronizer(fileURL.deletingLastPathComponent())
    }

    private func pendingLocked() throws -> HouseholdLifecycleTransaction? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let transaction = try JSONDecoder().decode(
                HouseholdLifecycleTransaction.self,
                from: Data(contentsOf: fileURL))
            try transaction.validate()
            return transaction
        } catch {
            throw Error.malformedTransaction
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func writeDurable(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try pathSynchronizer(parent)
        try data.write(to: url, options: .atomic)
        try pathSynchronizer(url)
        try pathSynchronizer(parent)
    }

    private static func synchronizePath(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw currentPOSIXError() }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
#endif
