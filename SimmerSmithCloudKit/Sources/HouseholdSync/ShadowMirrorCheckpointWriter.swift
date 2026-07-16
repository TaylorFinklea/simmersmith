#if canImport(CloudKit)
import CloudKit
import CryptoKit
import Darwin
import Foundation

public enum ShadowMirrorCheckpointFailurePoint: Equatable, Sendable {
    case afterScopeAnchorWrite
    case afterRecordsWrite
    case afterStateWrite
    case afterManifestWrite
    case afterPointerPublication
}

public enum ShadowMirrorCheckpointWriterError: Error, Equatable {
    case injectedFailure(ShadowMirrorCheckpointFailurePoint)
    case fenced
}

public struct ShadowMirrorCheckpointRecoveryState: Equatable, Sendable {
    public let outbox: [MirrorOutboxIntent]
    public let tombstones: [MirrorRecordIdentity]
    public let lastIntentSequence: UInt64
}

public struct ShadowMirrorCheckpointRecoveredSnapshot: Equatable, Sendable {
    public let scope: MirrorScope
    public let current: MirrorCheckpointBundle?
    public let recoveryState: ShadowMirrorCheckpointRecoveryState
    public let hasValidatedAnchor: Bool

    public var isRecoveryOnly: Bool {
        current == nil && recoveryState.lastIntentSequence > 0
    }
}

public final class ShadowMirrorCheckpointWriter: @unchecked Sendable {
    public let scope: MirrorScope

    private let scopeDirectory: URL
    private let failurePoint: ShadowMirrorCheckpointFailurePoint?
    private let stateQueue = DispatchQueue(label: "app.simmersmith.shadow-mirror.state")
    private let generationQueue = DispatchQueue(label: "app.simmersmith.shadow-mirror.generation")
    private let publicationGroup = DispatchGroup()
    private let fenceLock = NSLock()
    private var outbox: [MirrorOutboxIntent]
    private var tombstones: Set<MirrorRecordIdentity>
    private var lastIntentSequence: UInt64
    private var currentBundle: MirrorCheckpointBundle?
    private var hasValidatedAnchor: Bool
    private var fenced = false

    public init(
        scope: MirrorScope,
        rootDirectory: URL,
        failurePoint: ShadowMirrorCheckpointFailurePoint? = nil
    ) throws {
        try scope.validate()
        self.scope = scope
        self.failurePoint = failurePoint
        self.scopeDirectory = rootDirectory
            .appendingPathComponent(scope.cacheKey, isDirectory: true)
        try Self.prepareScopeDirectory(scopeDirectory)
        let recovered: RecoveredState
        do {
            recovered = try Self.recover(in: scopeDirectory, scope: scope)
        } catch {
            try Self.quarantine(scopeDirectory)
            try Self.prepareScopeDirectory(scopeDirectory)
            recovered = .empty
        }
        self.outbox = recovered.outbox
        self.tombstones = recovered.tombstones
        self.lastIntentSequence = recovered.lastIntentSequence
        self.currentBundle = recovered.bundle
        self.hasValidatedAnchor = recovered.hasValidatedAnchor
    }

    @discardableResult
    public func appendSave(
        _ record: CKRecord,
        mutationGeneration: UInt64,
        changedFields: [String] = [],
        clearedFields: [String] = []
    ) async throws -> UInt64 {
        let copy = record.copy() as! CKRecord
        return try await onStateQueue {
            try self.appendSaveLocked(
                copy,
                mutationGeneration: mutationGeneration,
                changedFields: changedFields,
                clearedFields: clearedFields)
        }
    }

    @discardableResult
    private func appendSaveLocked(
        _ record: CKRecord,
        mutationGeneration: UInt64,
        changedFields: [String],
        clearedFields: [String]
    ) throws -> UInt64 {
        try requireActive()
        let sequence = try nextSequence()
        let record = try archiveForJournal(record, sequence: sequence)
        let intent = MirrorOutboxIntent(
            sequence: sequence,
            mutationGeneration: mutationGeneration,
            operation: .save,
            record: record,
            changedFields: changedFields,
            clearedFields: clearedFields)
        try append(.mutation(sequence: sequence, intent: intent))
        return sequence
    }

    @discardableResult
    public func appendDelete(
        _ tombstone: MirrorRecordIdentity,
        mutationGeneration: UInt64
    ) async throws -> UInt64 {
        try await onStateQueue {
            try self.appendDeleteLocked(tombstone, mutationGeneration: mutationGeneration)
        }
    }

    @discardableResult
    private func appendDeleteLocked(
        _ tombstone: MirrorRecordIdentity,
        mutationGeneration: UInt64
    ) throws -> UInt64 {
        try requireActive()
        let sequence = try nextSequence()
        let intent = MirrorOutboxIntent(
            sequence: sequence,
            mutationGeneration: mutationGeneration,
            operation: .delete,
            tombstone: tombstone)
        try append(.mutation(sequence: sequence, intent: intent))
        return sequence
    }

    @discardableResult
    public func acknowledge(
        sequence: UInt64,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord? = nil
    ) async throws -> UInt64 {
        let copy = rebasedRecord.map { $0.copy() as! CKRecord }
        return try await onStateQueue {
            try self.acknowledgeLocked(
                sequence: sequence,
                mutationGeneration: mutationGeneration,
                rebasedRecord: copy)
        }
    }

    @discardableResult
    private func acknowledgeLocked(
        sequence: UInt64,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord?
    ) throws -> UInt64 {
        try requireActive()
        let transitionSequence = try nextSequence()
        let replacement = try rebasedRecord.map {
            try archiveForJournal($0, sequence: transitionSequence)
        }
        try append(.acknowledgement(
            sequence: transitionSequence,
            acknowledgedSequence: sequence,
            mutationGeneration: mutationGeneration,
            replacementRecord: replacement))
        return transitionSequence
    }

    @discardableResult
    public func markSent(sequence: UInt64, mutationGeneration: UInt64) async throws -> UInt64 {
        try await onStateQueue {
            try self.markSentLocked(sequence: sequence, mutationGeneration: mutationGeneration)
        }
    }

    @discardableResult
    private func markSentLocked(sequence: UInt64, mutationGeneration: UInt64) throws -> UInt64 {
        try requireActive()
        let transitionSequence = try nextSequence()
        try append(.sent(
            sequence: transitionSequence,
            sentSequence: sequence,
            mutationGeneration: mutationGeneration))
        return transitionSequence
    }

    @discardableResult
    public func markTransientFailure(
        sequence: UInt64,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord? = nil
    ) async throws -> UInt64 {
        let copy = rebasedRecord.map { $0.copy() as! CKRecord }
        return try await onStateQueue {
            try self.markTransientFailureLocked(
                sequence: sequence,
                mutationGeneration: mutationGeneration,
                rebasedRecord: copy)
        }
    }

    @discardableResult
    private func markTransientFailureLocked(
        sequence: UInt64,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord?
    ) throws -> UInt64 {
        try requireActive()
        let transitionSequence = try nextSequence()
        let replacement = try rebasedRecord.map {
            try archiveForJournal($0, sequence: transitionSequence)
        }
        try append(.transientFailure(
            sequence: transitionSequence,
            sentSequence: sequence,
            mutationGeneration: mutationGeneration,
            replacementRecord: replacement))
        return transitionSequence
    }

    @discardableResult
    public func markBlockedPermanent(
        sequence: UInt64,
        mutationGeneration: UInt64
    ) async throws -> UInt64 {
        try await onStateQueue {
            try self.markBlockedPermanentLocked(
                sequence: sequence,
                mutationGeneration: mutationGeneration)
        }
    }

    @discardableResult
    private func markBlockedPermanentLocked(
        sequence: UInt64,
        mutationGeneration: UInt64
    ) throws -> UInt64 {
        try requireActive()
        let transitionSequence = try nextSequence()
        try append(.blockedPermanent(
            sequence: transitionSequence,
            sentSequence: sequence,
            mutationGeneration: mutationGeneration))
        return transitionSequence
    }

    public func recoveryState() async -> ShadowMirrorCheckpointRecoveryState {
        await onStateQueueWithoutThrow { self.recoveryStateLocked() }
    }

    private func recoveryStateLocked() -> ShadowMirrorCheckpointRecoveryState {
        ShadowMirrorCheckpointRecoveryState(
            outbox: outbox.sorted { $0.sequence < $1.sequence },
            tombstones: tombstones.sorted { $0.sortKey < $1.sortKey },
            lastIntentSequence: lastIntentSequence)
    }

    public func recoveredCheckpoint() async -> ShadowMirrorCheckpointRecoveredSnapshot {
        await onStateQueueWithoutThrow { self.recoveredCheckpointLocked() }
    }

    private func recoveredCheckpointLocked() -> ShadowMirrorCheckpointRecoveredSnapshot {
        ShadowMirrorCheckpointRecoveredSnapshot(
            scope: scope,
            current: currentBundle,
            recoveryState: recoveryStateLocked(),
            hasValidatedAnchor: hasValidatedAnchor)
    }

    public func publish(records: [CKRecord], engineState: MirrorEngineState) async throws {
        let recoveryState = await recoveryState()
        try await publish(records: records, engineState: engineState, recoveryState: recoveryState)
    }

    /// Publishes an immutable mirror-boundary snapshot. Journal transitions appended after
    /// `recoveryState` was captured remain above its high-water mark and are replayed over the
    /// installed generation instead of leaking into (or being compacted with) this checkpoint.
    func publish(
        records: [CKRecord],
        engineState: MirrorEngineState,
        recoveryState: ShadowMirrorCheckpointRecoveryState
    ) async throws {
        let copies = records.map { $0.copy() as! CKRecord }
        try await withCheckedThrowingContinuation { continuation in
            enqueuePublication(
                records: copies,
                engineState: engineState,
                recoveryState: recoveryState
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    public func loadCurrent() async throws -> MirrorCheckpointBundle? {
        try await onStateQueue {
            try Self.loadCurrent(in: self.scopeDirectory, scope: self.scope)
        }
    }

    /// Prevent an old engine/session callback from writing into a scope that has been detached.
    /// Parking keeps the previously verified generation intact for a future identity-validated
    /// owner session, but this writer instance can never publish again.
    public func fenceAndPark() async {
        fenceSynchronously()
        await waitForPublications()
    }

    /// Fence first, then move the entire scope out of its live location before deleting it.
    /// A subsequent session receives a fresh directory, so it cannot observe a token without the
    /// matching records (or vice versa), and a stale writer cannot recreate either half.
    public func fenceAndClear() async throws {
        fenceSynchronously()
        await waitForPublications()
        try await onStateQueue {
            try self.clearLocked()
        }
    }

    /// A same-launch boundary mismatch means the installed generation is internally coherent
    /// but does not represent the immutable snapshot that requested publication. Quarantine the
    /// whole scope and permanently fence this writer so P1 can only continue via full fetch.
    public func fenceAndQuarantine() async throws {
        fenceSynchronously()
        await waitForPublications()
        try await onStateQueue {
            try self.quarantineLocked()
        }
    }

    // The active engine's save/delete APIs are deliberately synchronous. These bridge methods
    // keep P1's WAL-before-store-mutation invariant without changing repository call sites; the
    // dedicated state lane serializes WAL state and final pointer/compaction; immutable generation
    // construction uses a separate serial lane so later WAL appends are not trapped behind
    // whole-cache asset I/O.
    public func appendSaveSynchronously(
        _ record: CKRecord,
        mutationGeneration: UInt64,
        changedFields: [String] = [],
        clearedFields: [String] = []
    ) throws -> UInt64 {
        let copy = record.copy() as! CKRecord
        return try stateQueue.sync {
            try self.appendSaveLocked(
                copy,
                mutationGeneration: mutationGeneration,
                changedFields: changedFields,
                clearedFields: clearedFields)
        }
    }

    public func appendDeleteSynchronously(
        _ tombstone: MirrorRecordIdentity,
        mutationGeneration: UInt64
    ) throws -> UInt64 {
        try stateQueue.sync {
            try self.appendDeleteLocked(tombstone, mutationGeneration: mutationGeneration)
        }
    }

    public func markSentSynchronously(
        sequence: UInt64,
        mutationGeneration: UInt64
    ) throws -> UInt64 {
        try stateQueue.sync {
            try self.markSentLocked(sequence: sequence, mutationGeneration: mutationGeneration)
        }
    }

    public func acknowledgeSynchronously(
        sequence: UInt64,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord? = nil
    ) throws -> UInt64 {
        let copy = rebasedRecord.map { $0.copy() as! CKRecord }
        return try stateQueue.sync {
            try self.acknowledgeLocked(
                sequence: sequence,
                mutationGeneration: mutationGeneration,
                rebasedRecord: copy)
        }
    }

    public func markTransientFailureSynchronously(
        sequence: UInt64,
        mutationGeneration: UInt64,
        rebasedRecord: CKRecord? = nil
    ) throws -> UInt64 {
        let copy = rebasedRecord.map { $0.copy() as! CKRecord }
        return try stateQueue.sync {
            try self.markTransientFailureLocked(
                sequence: sequence,
                mutationGeneration: mutationGeneration,
                rebasedRecord: copy)
        }
    }

    public func markBlockedPermanentSynchronously(
        sequence: UInt64,
        mutationGeneration: UInt64
    ) throws -> UInt64 {
        try stateQueue.sync {
            try self.markBlockedPermanentLocked(
                sequence: sequence,
                mutationGeneration: mutationGeneration)
        }
    }

    public func recoveryStateSynchronously() throws -> ShadowMirrorCheckpointRecoveryState {
        stateQueue.sync { recoveryStateLocked() }
    }

    public func recoveredCheckpointSynchronously() throws -> ShadowMirrorCheckpointRecoveredSnapshot {
        stateQueue.sync { recoveredCheckpointLocked() }
    }

    public func loadCurrentSynchronously() throws -> MirrorCheckpointBundle? {
        try stateQueue.sync { try Self.loadCurrent(in: scopeDirectory, scope: scope) }
    }

    public func fenceAndParkSynchronously() {
        fenceSynchronously()
        publicationGroup.wait()
    }

    public func fenceSynchronously() {
        fenceLock.withLock { fenced = true }
    }

    public func fenceAndClearSynchronously() throws {
        fenceSynchronously()
        publicationGroup.wait()
        try stateQueue.sync { try clearLocked() }
    }

    public func fenceAndQuarantineSynchronously() throws {
        fenceSynchronously()
        publicationGroup.wait()
        try stateQueue.sync { try quarantineLocked() }
    }

    private func enqueuePublication(
        records: [CKRecord],
        engineState: MirrorEngineState,
        recoveryState: ShadowMirrorCheckpointRecoveryState,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        stateQueue.async {
            do {
                try self.requireActive()
                guard recoveryState.lastIntentSequence <= self.lastIntentSequence else {
                    throw MirrorCheckpointError.invalidOutbox(
                        "checkpoint high-water leads the writer")
                }
                let generationID = UUID().uuidString
                let generationDirectory = self.scopeDirectory
                    .appendingPathComponent("generations", isDirectory: true)
                    .appendingPathComponent(generationID, isDirectory: true)
                let input = ShadowMirrorGenerationInput(
                    scope: self.scope,
                    generationDirectory: generationDirectory,
                    records: records,
                    engineState: engineState,
                    recoveryState: recoveryState,
                    failurePoint: self.failurePoint)
                self.publicationGroup.enter()
                self.generationQueue.async {
                    let prepared = Result { try Self.prepareGeneration(input) }
                    self.stateQueue.async {
                        defer { self.publicationGroup.leave() }
                        do {
                            try prepared.get()
                            try self.installPreparedGenerationLocked(
                                generationID: generationID,
                                recoveryState: recoveryState)
                            completion(.success(()))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func installPreparedGenerationLocked(
        generationID: String,
        recoveryState: ShadowMirrorCheckpointRecoveryState
    ) throws {
        // Generation construction runs on a separate serial queue. A clear/park can fence this
        // writer meanwhile; final pointer installation rechecks the fence on the state lane.
        try requireActive()
        try Self.installCurrent(generationID, in: scopeDirectory)
        try failIfNeeded(.afterPointerPublication)
        guard let installed = try Self.loadCurrent(in: scopeDirectory, scope: scope),
              installed.manifest.generationID == generationID else {
            throw MirrorCheckpointError.invalidManifest
        }
        try Self.compactJournal(
            in: scopeDirectory,
            through: recoveryState.lastIntentSequence)
        try Self.removeJournalAssets(
            in: scopeDirectory,
            through: recoveryState.lastIntentSequence)
        let recovered = try Self.recover(in: scopeDirectory, scope: scope)
        outbox = recovered.outbox
        tombstones = recovered.tombstones
        lastIntentSequence = recovered.lastIntentSequence
        currentBundle = recovered.bundle
        hasValidatedAnchor = recovered.hasValidatedAnchor
    }

    private func clearLocked() throws {
        let parent = scopeDirectory.deletingLastPathComponent()
        let retired = parent.appendingPathComponent(
            ".clearing-\(UUID().uuidString)", isDirectory: true)
        if FileManager.default.fileExists(atPath: scopeDirectory.path) {
            try FileManager.default.moveItem(at: scopeDirectory, to: retired)
        }
        try Self.prepareScopeDirectory(scopeDirectory)
        outbox = []
        tombstones = []
        lastIntentSequence = 0
        currentBundle = nil
        hasValidatedAnchor = false
        try Self.synchronizeDirectory(parent)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: retired)
        }
    }

    private func quarantineLocked() throws {
        try Self.quarantine(scopeDirectory)
        try Self.prepareScopeDirectory(scopeDirectory)
        outbox = []
        tombstones = []
        lastIntentSequence = 0
        currentBundle = nil
        hasValidatedAnchor = false
    }

    private func waitForPublications() async {
        await withCheckedContinuation { continuation in
            publicationGroup.notify(queue: DispatchQueue.global(qos: .utility)) {
                continuation.resume()
            }
        }
    }

    private func onStateQueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func onStateQueueWithoutThrow<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private static func prepareGeneration(
        _ input: ShadowMirrorGenerationInput
    ) throws {
        let directory = input.generationDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try synchronizeDirectory(directory.deletingLastPathComponent())
        let snapshotOutbox = try rehomeOutbox(
            input.recoveryState.outbox,
            in: directory.appendingPathComponent("outbox-assets", isDirectory: true))
        let receiptIndex = MirrorReceiptIndex(receipts: input.records
            .filter { $0.recordType == "MigrationReceipt" }
            .map(MirrorRecordIdentity.init))
        let bundle = try MirrorCheckpointBundle.capture(
            scope: input.scope,
            generationID: directory.lastPathComponent,
            records: input.records,
            in: directory.appendingPathComponent("assets", isDirectory: true),
            tombstones: input.recoveryState.tombstones,
            outbox: snapshotOutbox,
            receipts: receiptIndex,
            engineState: input.engineState,
            lastIncludedIntentSequence: input.recoveryState.lastIntentSequence)
        try synchronizeTree(at: directory)
        let recordsData = try JSONEncoder().encode(PersistedRecords(bundle: bundle))
        let stateData = try JSONEncoder().encode(bundle.engineState)
        let manifest = PersistedManifest(
            manifest: bundle.manifest,
            recordsFileDigest: ShadowMirrorDigest.sha256(recordsData),
            stateFileDigest: ShadowMirrorDigest.sha256(stateData))

        try writeDurable(recordsData, to: directory.appendingPathComponent("records.json"))
        if input.failurePoint == .afterRecordsWrite {
            throw ShadowMirrorCheckpointWriterError.injectedFailure(.afterRecordsWrite)
        }
        try writeDurable(stateData, to: directory.appendingPathComponent("engine-state.json"))
        if input.failurePoint == .afterStateWrite {
            throw ShadowMirrorCheckpointWriterError.injectedFailure(.afterStateWrite)
        }
        try writeDurable(
            try JSONEncoder().encode(manifest),
            to: directory.appendingPathComponent("manifest.json"))
        if input.failurePoint == .afterManifestWrite {
            throw ShadowMirrorCheckpointWriterError.injectedFailure(.afterManifestWrite)
        }
        _ = try loadGeneration(at: directory, scope: input.scope)
    }

    private func failIfNeeded(_ point: ShadowMirrorCheckpointFailurePoint) throws {
        guard failurePoint == point else { return }
        throw ShadowMirrorCheckpointWriterError.injectedFailure(point)
    }

    private func requireActive() throws {
        guard fenceLock.withLock({ !fenced }) else {
            throw ShadowMirrorCheckpointWriterError.fenced
        }
    }

    private func nextSequence() throws -> UInt64 {
        guard lastIntentSequence < UInt64.max else {
            throw MirrorCheckpointError.invalidOutbox("journal sequence overflow")
        }
        return lastIntentSequence + 1
    }

    private func append(_ transition: JournalTransition) throws {
        try transition.validateShape()
        var nextOutbox = outbox
        var nextTombstones = tombstones
        try Self.apply(transition, to: &nextOutbox, tombstones: &nextTombstones)
        if !hasValidatedAnchor {
            try Self.persistScopeAnchor(for: scope, in: scopeDirectory)
            try failIfNeeded(.afterScopeAnchorWrite)
        }
        do {
            try Self.appendJournal(transition, in: scopeDirectory)
        } catch {
            fenceSynchronously()
            throw error
        }
        hasValidatedAnchor = true
        outbox = nextOutbox
        tombstones = nextTombstones
        lastIntentSequence = transition.sequence
    }

    private func archiveForJournal(
        _ record: CKRecord,
        sequence: UInt64
    ) throws -> ShadowMirrorRecordEnvelope {
        let assetDirectory = scopeDirectory
            .appendingPathComponent("journal-assets", isDirectory: true)
            .appendingPathComponent("\(sequence)", isDirectory: true)
        let envelope = try ShadowMirrorRecordEnvelope.archive(record, in: assetDirectory)
        try Self.synchronizeTree(at: assetDirectory)
        try Self.synchronizeDirectory(assetDirectory.deletingLastPathComponent())
        try Self.synchronizeDirectory(scopeDirectory)
        return envelope
    }

    private static func rehomeOutbox(
        _ intents: [MirrorOutboxIntent],
        in assetRoot: URL
    ) throws -> [MirrorOutboxIntent] {
        try intents.sorted { $0.sequence < $1.sequence }.map { intent in
            try intent.validate()
            guard let envelope = intent.record else { return intent }
            let record = try envelope.decode()
            let durableEnvelope = try ShadowMirrorRecordEnvelope.archive(
                record,
                in: assetRoot.appendingPathComponent("\(intent.sequence)", isDirectory: true))
            return MirrorOutboxIntent(
                sequence: intent.sequence,
                mutationGeneration: intent.mutationGeneration,
                operation: intent.operation,
                record: durableEnvelope,
                tombstone: intent.tombstone,
                changedFields: intent.changedFields,
                clearedFields: intent.clearedFields,
                delivery: intent.delivery)
        }
    }

    private static func recover(in scopeDirectory: URL, scope: MirrorScope) throws -> RecoveredState {
        let anchor = try loadScopeAnchor(in: scopeDirectory, scope: scope)
        let bundle = try loadCurrent(in: scopeDirectory, scope: scope)
        var outbox = bundle?.outbox ?? []
        var tombstones = Set(bundle?.tombstones ?? [])
        let highWater = bundle?.manifest.lastIntentSequence ?? 0
        let journal = try readJournal(in: scopeDirectory, repairingIncompleteTail: true)
        var lastSequence = highWater
        var previousJournalSequence: UInt64?
        var previousSuffixSequence: UInt64?
        for transition in journal {
            guard transition.sequence > 0 else {
                throw MirrorCheckpointError.invalidManifest
            }
            if let previousJournalSequence {
                guard previousJournalSequence < UInt64.max,
                      transition.sequence == previousJournalSequence + 1 else {
                    throw MirrorCheckpointError.invalidManifest
                }
            } else if transition.sequence > highWater {
                guard highWater < UInt64.max,
                      transition.sequence == highWater + 1 else {
                    throw MirrorCheckpointError.invalidManifest
                }
            }
            previousJournalSequence = transition.sequence
            guard transition.sequence > highWater else { continue }
            let precedingSequence = previousSuffixSequence ?? highWater
            guard precedingSequence < UInt64.max,
                  transition.sequence == precedingSequence + 1 else {
                throw MirrorCheckpointError.invalidManifest
            }
            previousSuffixSequence = transition.sequence
            lastSequence = transition.sequence
            try apply(transition, to: &outbox, tombstones: &tombstones)
        }
        return RecoveredState(
            bundle: bundle,
            hasValidatedAnchor: anchor != nil,
            outbox: outbox.sorted { $0.sequence < $1.sequence },
            tombstones: tombstones,
            lastIntentSequence: lastSequence)
    }

    private static func loadScopeAnchor(
        in scopeDirectory: URL,
        scope: MirrorScope
    ) throws -> MirrorScopeAnchor? {
        let url = scopeDirectory.appendingPathComponent("scope.anchor")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let anchor = try JSONDecoder().decode(MirrorScopeAnchor.self, from: Data(contentsOf: url))
        try anchor.validate(for: scope, in: scopeDirectory)
        return anchor
    }

    private static func loadCurrent(in scopeDirectory: URL, scope: MirrorScope) throws -> MirrorCheckpointBundle? {
        let pointer = scopeDirectory.appendingPathComponent("current")
        guard FileManager.default.fileExists(atPath: pointer.path) else { return nil }
        let generationID = try String(contentsOf: pointer, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generationID.isEmpty,
              !generationID.contains("/"),
              !generationID.contains("..") else {
            throw MirrorCheckpointError.invalidManifest
        }
        return try loadGeneration(
            at: scopeDirectory.appendingPathComponent("generations", isDirectory: true)
                .appendingPathComponent(generationID, isDirectory: true),
            scope: scope)
    }

    private static func apply(
        _ transition: JournalTransition,
        to outbox: inout [MirrorOutboxIntent],
        tombstones: inout Set<MirrorRecordIdentity>
    ) throws {
        switch transition.kind {
        case .mutation:
            guard let intent = transition.intent,
                  intent.sequence == transition.sequence else {
                throw MirrorCheckpointError.invalidOutbox("journal mutation is malformed")
            }
            try intent.validate()
            guard !outbox.contains(where: { $0.sequence == intent.sequence }) else {
                throw MirrorCheckpointError.invalidOutbox("journal sequence is duplicated")
            }
            let targetIdentity = Self.identity(of: intent)
            outbox.removeAll { existing in
                guard Self.identity(of: existing) == targetIdentity else { return false }
                return existing.delivery.state == .pending
                    || existing.delivery.state == .blockedPermanent
            }
            outbox.append(intent)
            switch intent.operation {
            case .save:
                if let identity = intent.record?.identity {
                    tombstones.remove(identity)
                }
            case .delete:
                if let tombstone = intent.tombstone {
                    tombstones.insert(tombstone)
                }
            }
        case .sent:
            guard let acknowledgedSequence = transition.acknowledgedSequence,
                  let mutationGeneration = transition.acknowledgedMutationGeneration,
                  transition.intent == nil else {
                throw MirrorCheckpointError.invalidOutbox("journal send transition is malformed")
            }
            guard let index = outbox.firstIndex(where: {
                $0.sequence == acknowledgedSequence && $0.mutationGeneration == mutationGeneration
            }), outbox[index].delivery == .pending else {
                throw MirrorCheckpointError.invalidOutbox("send transition does not match a pending intent")
            }
            let intent = outbox[index]
            outbox[index] = MirrorOutboxIntent(
                sequence: intent.sequence,
                mutationGeneration: intent.mutationGeneration,
                operation: intent.operation,
                record: intent.record,
                tombstone: intent.tombstone,
                changedFields: intent.changedFields,
                clearedFields: intent.clearedFields,
                delivery: .sent(sequence: acknowledgedSequence, generation: mutationGeneration))
        case .transientFailure:
            guard let acknowledgedSequence = transition.acknowledgedSequence,
                  let mutationGeneration = transition.acknowledgedMutationGeneration,
                  transition.intent == nil else {
                throw MirrorCheckpointError.invalidOutbox("journal transient failure is malformed")
            }
            guard let index = outbox.firstIndex(where: {
                $0.sequence == acknowledgedSequence && $0.mutationGeneration == mutationGeneration
            }), outbox[index].delivery == .sent(
                sequence: acknowledgedSequence, generation: mutationGeneration) else {
                throw MirrorCheckpointError.invalidOutbox(
                    "transient failure does not match an exact sent intent")
            }
            let intent = outbox[index]
            let record = try replacementRecord(
                transition.replacementRecord,
                for: intent,
                required: false)
            outbox[index] = MirrorOutboxIntent(
                sequence: intent.sequence,
                mutationGeneration: intent.mutationGeneration,
                operation: intent.operation,
                record: record,
                tombstone: intent.tombstone,
                changedFields: intent.changedFields,
                clearedFields: intent.clearedFields,
                delivery: .pending)
        case .blockedPermanent:
            guard let acknowledgedSequence = transition.acknowledgedSequence,
                  let mutationGeneration = transition.acknowledgedMutationGeneration,
                  transition.intent == nil else {
                throw MirrorCheckpointError.invalidOutbox("journal permanent failure is malformed")
            }
            guard let index = outbox.firstIndex(where: {
                $0.sequence == acknowledgedSequence && $0.mutationGeneration == mutationGeneration
            }), outbox[index].delivery == .sent(
                sequence: acknowledgedSequence, generation: mutationGeneration) else {
                throw MirrorCheckpointError.invalidOutbox(
                    "permanent failure does not match an exact sent intent")
            }
            let intent = outbox[index]
            outbox[index] = MirrorOutboxIntent(
                sequence: intent.sequence,
                mutationGeneration: intent.mutationGeneration,
                operation: intent.operation,
                record: intent.record,
                tombstone: intent.tombstone,
                changedFields: intent.changedFields,
                clearedFields: intent.clearedFields,
                delivery: .blockedPermanent(
                    sequence: acknowledgedSequence,
                    generation: mutationGeneration))
        case .acknowledgement:
            guard let acknowledgedSequence = transition.acknowledgedSequence,
                  let mutationGeneration = transition.acknowledgedMutationGeneration,
                  transition.intent == nil else {
                throw MirrorCheckpointError.invalidOutbox("journal acknowledgement is malformed")
            }
            guard let index = outbox.firstIndex(where: {
                $0.sequence == acknowledgedSequence && $0.mutationGeneration == mutationGeneration
            }), outbox[index].delivery == .sent(
                sequence: acknowledgedSequence, generation: mutationGeneration) else {
                throw MirrorCheckpointError.invalidOutbox(
                    "acknowledgement does not match an exact sent intent")
            }
            let acknowledged = outbox.remove(at: index)
            let acknowledgedIdentity = identity(of: acknowledged)
            let newerSaveIndex = outbox.indices
                .filter {
                    outbox[$0].sequence > acknowledged.sequence
                        && outbox[$0].operation == .save
                        && identity(of: outbox[$0]) == acknowledgedIdentity
                }
                .max { outbox[$0].sequence < outbox[$1].sequence }
            if acknowledged.operation == .save, let newerSaveIndex {
                let newer = outbox[newerSaveIndex]
                let rebasedRecord = try replacementRecord(
                    transition.replacementRecord,
                    for: newer,
                    required: true)
                outbox[newerSaveIndex] = MirrorOutboxIntent(
                    sequence: newer.sequence,
                    mutationGeneration: newer.mutationGeneration,
                    operation: newer.operation,
                    record: rebasedRecord,
                    tombstone: newer.tombstone,
                    changedFields: newer.changedFields,
                    clearedFields: newer.clearedFields,
                    delivery: newer.delivery)
            } else if transition.replacementRecord != nil {
                throw MirrorCheckpointError.invalidOutbox("acknowledgement rebase has no newer save")
            }
            guard acknowledged.operation == .delete,
                  let tombstone = acknowledged.tombstone else { return }
            let hasNewerMutation = outbox.contains { intent in
                guard intent.mutationGeneration > acknowledged.mutationGeneration else { return false }
                switch intent.operation {
                case .save: return intent.record?.identity == tombstone
                case .delete: return intent.tombstone == tombstone
                }
            }
            if !hasNewerMutation {
                tombstones.remove(tombstone)
            }
        }
    }

    private static func identity(of intent: MirrorOutboxIntent) -> MirrorRecordIdentity {
        switch intent.operation {
        case .save: return intent.record!.identity
        case .delete: return intent.tombstone!
        }
    }

    private static func replacementRecord(
        _ replacement: ShadowMirrorRecordEnvelope?,
        for intent: MirrorOutboxIntent,
        required: Bool
    ) throws -> ShadowMirrorRecordEnvelope? {
        guard intent.operation == .save, let current = intent.record else {
            guard replacement == nil else {
                throw MirrorCheckpointError.invalidOutbox("delete transition cannot carry a record rebase")
            }
            return nil
        }
        guard let replacement else {
            guard !required else {
                throw MirrorCheckpointError.invalidOutbox("stale save acknowledgement requires a rebase")
            }
            return current
        }
        guard replacement.identity == current.identity else {
            throw MirrorCheckpointError.invalidOutbox("rebased record identity does not match the intent")
        }
        _ = try replacement.decode()
        return replacement
    }

    /// Persists the exact scope supplied by CloudKit discovery. This never infers a scope from
    /// the directory name; it only verifies that the known scope's cache key names this directory.
    public static func persistScopeAnchor(for scope: MirrorScope, in scopeDirectory: URL) throws {
        try scope.validate()
        guard scopeDirectory.lastPathComponent == scope.cacheKey else {
            throw MirrorCheckpointError.scopeMismatch
        }
        try FileManager.default.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        try synchronizeDirectory(scopeDirectory.deletingLastPathComponent())
        if let anchor = try loadScopeAnchor(in: scopeDirectory, scope: scope) {
            guard anchor.scope == scope else { throw MirrorCheckpointError.scopeMismatch }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeDurable(
            try encoder.encode(try MirrorScopeAnchor(scope: scope)),
            to: scopeDirectory.appendingPathComponent("scope.anchor"))
    }

    private static func appendJournal(_ transition: JournalTransition, in scopeDirectory: URL) throws {
        let journalURL = scopeDirectory.appendingPathComponent("journal.wal")
        let journalAlreadyExisted = FileManager.default.fileExists(atPath: journalURL.path)
        if !journalAlreadyExisted {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: nil) else {
                throw MirrorCheckpointError.notCacheReady("cannot create journal")
            }
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let encoded = try JSONEncoder().encode(transition)
        try handle.write(contentsOf: frame(for: encoded))
        try handle.synchronize()
        if !journalAlreadyExisted {
            try synchronizeDirectory(scopeDirectory)
        }
    }

    private static func readJournal(
        in scopeDirectory: URL,
        repairingIncompleteTail: Bool = false
    ) throws -> [JournalTransition] {
        let journalURL = scopeDirectory.appendingPathComponent("journal.wal")
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        let data = try Data(contentsOf: journalURL)
        var offset = 0
        var transitions: [JournalTransition] = []
        while offset < data.count {
            guard data.count - offset >= JournalFrame.headerLength else {
                if repairingIncompleteTail { try truncateJournal(at: journalURL, to: offset) }
                break
            }
            let length = data[offset..<(offset + 8)].reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
            guard length <= JournalFrame.maximumPayloadLength else {
                throw MirrorCheckpointError.invalidManifest
            }
            let payloadStart = offset + JournalFrame.headerLength
            let payloadEnd = payloadStart + Int(length)
            guard payloadEnd <= data.count else {
                if repairingIncompleteTail { try truncateJournal(at: journalURL, to: offset) }
                break
            }
            let checksum = data[(offset + 8)..<(offset + JournalFrame.headerLength)]
            let payload = data[payloadStart..<payloadEnd]
            guard Data(checksum) == Data(SHA256.hash(data: payload)) else {
                throw MirrorCheckpointError.invalidManifest
            }
            do {
                let transition = try JSONDecoder().decode(JournalTransition.self, from: payload)
                try transition.validateShape()
                transitions.append(transition)
            } catch {
                throw MirrorCheckpointError.invalidManifest
            }
            offset = payloadEnd
        }
        return transitions
    }

    private static func truncateJournal(at url: URL, to offset: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func compactJournal(in scopeDirectory: URL, through highWater: UInt64) throws {
        let retained = try readJournal(in: scopeDirectory).filter { $0.sequence > highWater }
        var data = Data()
        for transition in retained {
            data.append(frame(for: try JSONEncoder().encode(transition)))
        }
        try writeDurable(data, to: scopeDirectory.appendingPathComponent("journal.wal"))
    }

    private static func removeJournalAssets(in scopeDirectory: URL, through highWater: UInt64) throws {
        let assetRoot = scopeDirectory.appendingPathComponent("journal-assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: assetRoot.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(
            at: assetRoot,
            includingPropertiesForKeys: nil
        ) {
            guard let sequence = UInt64(child.lastPathComponent), sequence <= highWater else { continue }
            try FileManager.default.removeItem(at: child)
        }
        try synchronizeDirectory(assetRoot)
        try synchronizeDirectory(scopeDirectory)
    }

    private static func frame(for payload: Data) -> Data {
        var frame = Data()
        var length = UInt64(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(Data(SHA256.hash(data: payload)))
        frame.append(payload)
        return frame
    }

    private static func quarantine(_ scopeDirectory: URL) throws {
        let fileManager = FileManager.default
        let parent = scopeDirectory.deletingLastPathComponent()
        let quarantine = parent.appendingPathComponent("quarantine", isDirectory: true)
        try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try synchronizeDirectory(parent)
        guard fileManager.fileExists(atPath: scopeDirectory.path) else { return }
        try fileManager.moveItem(
            at: scopeDirectory,
            to: quarantine.appendingPathComponent("\(scopeDirectory.lastPathComponent)-\(UUID().uuidString)"))
        try synchronizeDirectory(quarantine)
        try synchronizeDirectory(parent)
    }

    private static func prepareScopeDirectory(_ scopeDirectory: URL) throws {
        let generations = scopeDirectory.appendingPathComponent("generations", isDirectory: true)
        try FileManager.default.createDirectory(at: generations, withIntermediateDirectories: true)
        try synchronizeDirectory(generations)
        try synchronizeDirectory(scopeDirectory)
        try synchronizeDirectory(scopeDirectory.deletingLastPathComponent())
    }

    private static func loadGeneration(at directory: URL, scope: MirrorScope) throws -> MirrorCheckpointBundle {
        let recordsData = try Data(contentsOf: directory.appendingPathComponent("records.json"))
        let stateData = try Data(contentsOf: directory.appendingPathComponent("engine-state.json"))
        let persistedManifest = try JSONDecoder().decode(
            PersistedManifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard persistedManifest.manifest.generationID == directory.lastPathComponent,
              persistedManifest.recordsFileDigest == ShadowMirrorDigest.sha256(recordsData),
              persistedManifest.stateFileDigest == ShadowMirrorDigest.sha256(stateData) else {
            throw MirrorCheckpointError.invalidManifest
        }
        let records = try JSONDecoder().decode(PersistedRecords.self, from: recordsData)
        let state = try JSONDecoder().decode(MirrorEngineState.self, from: stateData)
        let bundle = try MirrorCheckpointBundle(
            scope: persistedManifest.manifest.scope,
            generationID: persistedManifest.manifest.generationID,
            records: records.records,
            tombstones: records.tombstones,
            outbox: records.outbox,
            receipts: records.receipts,
            engineState: state,
            lastIncludedIntentSequence: persistedManifest.manifest.lastIntentSequence)
        guard bundle.manifest == persistedManifest.manifest else {
            throw MirrorCheckpointError.invalidManifest
        }
        try bundle.validate(for: scope)
        return bundle
    }

    private static func writeDurable(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try synchronizePath(url)
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    private static func installCurrent(_ generationID: String, in scopeDirectory: URL) throws {
        let pointer = scopeDirectory.appendingPathComponent("current")
        let replacement = scopeDirectory.appendingPathComponent("current-next")
        try writeDurable(Data(generationID.utf8), to: replacement)
        if FileManager.default.fileExists(atPath: pointer.path) {
            _ = try FileManager.default.replaceItemAt(pointer, withItemAt: replacement)
        } else {
            try FileManager.default.moveItem(at: replacement, to: pointer)
        }
        try synchronizeDirectory(scopeDirectory)
    }

    private static func synchronizeTree(at root: URL) throws {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            throw MirrorCheckpointError.notCacheReady("cannot enumerate generation")
        }
        var directories = [root]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isRegularFile == true {
                try synchronizePath(url)
            } else if values.isDirectory == true {
                directories.append(url)
            }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            try synchronizeDirectory(directory)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        try synchronizePath(directory)
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

private struct ShadowMirrorGenerationInput: @unchecked Sendable {
    let scope: MirrorScope
    let generationDirectory: URL
    let records: [CKRecord]
    let engineState: MirrorEngineState
    let recoveryState: ShadowMirrorCheckpointRecoveryState
    let failurePoint: ShadowMirrorCheckpointFailurePoint?
}

private struct RecoveredState {
    var bundle: MirrorCheckpointBundle?
    var hasValidatedAnchor: Bool
    var outbox: [MirrorOutboxIntent]
    var tombstones: Set<MirrorRecordIdentity>
    var lastIntentSequence: UInt64

    static let empty = Self(
        bundle: nil,
        hasValidatedAnchor: false,
        outbox: [],
        tombstones: [],
        lastIntentSequence: 0)
}

private struct JournalFrame {
    static let headerLength = 8 + 32
    static let maximumPayloadLength: UInt64 = 16 * 1024 * 1024
}

private struct JournalTransition: Codable {
    enum Kind: String, Codable {
        case mutation
        case sent
        case transientFailure
        case blockedPermanent
        case acknowledgement
    }

    let sequence: UInt64
    let kind: Kind
    let intent: MirrorOutboxIntent?
    let acknowledgedSequence: UInt64?
    let acknowledgedMutationGeneration: UInt64?
    let replacementRecord: ShadowMirrorRecordEnvelope?

    func validateShape() throws {
        guard sequence > 0 else {
            throw MirrorCheckpointError.invalidOutbox("journal transition has a zero sequence")
        }
        switch kind {
        case .mutation:
            guard let intent,
                  intent.sequence == sequence,
                  acknowledgedSequence == nil,
                  acknowledgedMutationGeneration == nil,
                  replacementRecord == nil else {
                throw MirrorCheckpointError.invalidOutbox("journal mutation is malformed")
            }
            try intent.validate()
            if let record = intent.record { _ = try record.decode() }
        case .sent, .blockedPermanent:
            guard intent == nil,
                  let acknowledgedSequence,
                  let acknowledgedMutationGeneration,
                  acknowledgedSequence > 0,
                  acknowledgedSequence < sequence,
                  acknowledgedMutationGeneration > 0,
                  replacementRecord == nil else {
                throw MirrorCheckpointError.invalidOutbox("journal delivery transition is malformed")
            }
        case .transientFailure, .acknowledgement:
            guard intent == nil,
                  let acknowledgedSequence,
                  let acknowledgedMutationGeneration,
                  acknowledgedSequence > 0,
                  acknowledgedSequence < sequence,
                  acknowledgedMutationGeneration > 0 else {
                throw MirrorCheckpointError.invalidOutbox("journal delivery transition is malformed")
            }
            if let replacementRecord { _ = try replacementRecord.decode() }
        }
    }

    static func mutation(sequence: UInt64, intent: MirrorOutboxIntent) -> Self {
        Self(
            sequence: sequence,
            kind: .mutation,
            intent: intent,
            acknowledgedSequence: nil,
            acknowledgedMutationGeneration: nil,
            replacementRecord: nil)
    }

    static func acknowledgement(
        sequence: UInt64,
        acknowledgedSequence: UInt64,
        mutationGeneration: UInt64,
        replacementRecord: ShadowMirrorRecordEnvelope?
    ) -> Self {
        Self(
            sequence: sequence,
            kind: .acknowledgement,
            intent: nil,
            acknowledgedSequence: acknowledgedSequence,
            acknowledgedMutationGeneration: mutationGeneration,
            replacementRecord: replacementRecord)
    }

    static func sent(
        sequence: UInt64,
        sentSequence: UInt64,
        mutationGeneration: UInt64
    ) -> Self {
        Self(
            sequence: sequence,
            kind: .sent,
            intent: nil,
            acknowledgedSequence: sentSequence,
            acknowledgedMutationGeneration: mutationGeneration,
            replacementRecord: nil)
    }

    static func transientFailure(
        sequence: UInt64,
        sentSequence: UInt64,
        mutationGeneration: UInt64,
        replacementRecord: ShadowMirrorRecordEnvelope?
    ) -> Self {
        Self(
            sequence: sequence,
            kind: .transientFailure,
            intent: nil,
            acknowledgedSequence: sentSequence,
            acknowledgedMutationGeneration: mutationGeneration,
            replacementRecord: replacementRecord)
    }

    static func blockedPermanent(
        sequence: UInt64,
        sentSequence: UInt64,
        mutationGeneration: UInt64
    ) -> Self {
        Self(
            sequence: sequence,
            kind: .blockedPermanent,
            intent: nil,
            acknowledgedSequence: sentSequence,
            acknowledgedMutationGeneration: mutationGeneration,
            replacementRecord: nil)
    }
}

private struct PersistedRecords: Codable {
    let records: [ShadowMirrorRecordEnvelope]
    let tombstones: [MirrorRecordIdentity]
    let outbox: [MirrorOutboxIntent]
    let receipts: MirrorReceiptIndex

    init(bundle: MirrorCheckpointBundle) {
        records = bundle.records
        tombstones = bundle.tombstones
        outbox = bundle.outbox
        receipts = bundle.receipts
    }
}

private struct PersistedManifest: Codable {
    let manifest: MirrorCheckpointManifest
    let recordsFileDigest: String
    let stateFileDigest: String
}
#endif
