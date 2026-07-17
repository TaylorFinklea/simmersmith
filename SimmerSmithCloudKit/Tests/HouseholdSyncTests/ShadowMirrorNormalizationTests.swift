#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

// e0a P2 spec §3.2 restart normalization: per CKRecord.ID the latest effective mutation wins,
// older sent intents are durably superseded, a latest sent intent gets a durable restart-retry
// back to pending, and every transition is WAL-appended and fsynced before the in-memory apply.

private let normalizationZone = CKRecordZone.ID(
    zoneName: "household",
    ownerName: "user-a")

private func normalizationScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "user-a", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .owner, databaseScope: .private)
}

private func normalizationRecord(_ name: String, value: String = "v1") -> CKRecord {
    let record = CKRecord(
        recordType: "Recipe",
        recordID: CKRecord.ID(recordName: name, zoneID: normalizationZone))
    record["name"] = value as CKRecordValue
    return record
}

private func normalizationIdentity(_ name: String) -> MirrorRecordIdentity {
    MirrorRecordIdentity(
        recordType: "Recipe",
        recordName: name,
        zoneOwnerName: normalizationZone.ownerName,
        zoneName: normalizationZone.zoneName)
}

private func normalizationRoot() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shadow-normalization-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeWriter(
    root: URL,
    failurePoint: ShadowMirrorCheckpointFailurePoint? = nil
) throws -> ShadowMirrorCheckpointWriter {
    try ShadowMirrorCheckpointWriter(
        scope: normalizationScope(), rootDirectory: root, failurePoint: failurePoint)
}

@Test("a latest sent intent receives a durable restart-retry back to pending")
func latestSentIntentReturnsToPendingDurably() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let sequence = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)

    let restarted = try makeWriter(root: root)
    let normalized = try restarted.normalizeForBootstrapSynchronously()

    #expect(normalized.snapshot.recoveryState.outbox.map(\.delivery.state) == [.pending])
    #expect(normalized.removalProofs.isEmpty)

    // Durable: a later restart without normalizing again already sees the retried state.
    let recovered = try makeWriter(root: root)
    let replayed = try recovered.recoveredCheckpointSynchronously()
    #expect(replayed.recoveryState.outbox.map(\.delivery.state) == [.pending])

    // Idempotent: normalizing an already-normalized journal appends nothing.
    let again = try recovered.normalizeForBootstrapSynchronously()
    #expect(again.snapshot.recoveryState.lastIntentSequence
        == normalized.snapshot.recoveryState.lastIntentSequence)
}

@Test(
    "an older sent intent is durably superseded by every newer mutation shape",
    arguments: [
        (MirrorOutboxIntent.Operation.save, MirrorOutboxIntent.Operation.save),
        (MirrorOutboxIntent.Operation.save, MirrorOutboxIntent.Operation.delete),
        (MirrorOutboxIntent.Operation.delete, MirrorOutboxIntent.Operation.save),
        (MirrorOutboxIntent.Operation.delete, MirrorOutboxIntent.Operation.delete),
    ])
func olderSentIntentIsSupersededByNewerMutation(
    older: MirrorOutboxIntent.Operation,
    newer: MirrorOutboxIntent.Operation
) async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let identity = normalizationIdentity("recipe-1")

    let olderSequence: UInt64
    switch older {
    case .save:
        olderSequence = try await writer.appendSave(
            normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    case .delete:
        olderSequence = try await writer.appendDelete(identity, mutationGeneration: 1)
    }
    _ = try await writer.markSent(sequence: olderSequence, mutationGeneration: 1)
    switch newer {
    case .save:
        _ = try await writer.appendSave(
            normalizationRecord("recipe-1", value: "v2"), mutationGeneration: 2,
            changedFields: ["name"])
    case .delete:
        _ = try await writer.appendDelete(identity, mutationGeneration: 2)
    }

    let restarted = try makeWriter(root: root)
    let normalized = try restarted.normalizeForBootstrapSynchronously()
    let outbox = normalized.snapshot.recoveryState.outbox

    #expect(outbox.count == 1)
    #expect(outbox.first?.operation == newer)
    #expect(outbox.first?.delivery == .pending)
    #expect(normalized.removalProofs == [
        MirrorOutboxRemovalProof(
            identity: identity,
            operation: older,
            sequence: olderSequence,
            mutationGeneration: 1,
            reason: .supersededByNewerMutation),
    ])
    // Tombstone state reflects only the newest effective mutation.
    let tombstones = normalized.snapshot.recoveryState.tombstones
    #expect(tombstones.contains(identity) == (newer == .delete))

    // Durable and idempotent across another restart.
    let recovered = try makeWriter(root: root)
    let replayed = try recovered.normalizeForBootstrapSynchronously()
    #expect(replayed.snapshot.recoveryState.outbox == outbox)
    #expect(replayed.removalProofs == normalized.removalProofs)
}

@Test("an old acknowledgement after a newer delete removes the exact row with a durable proof")
func oldAcknowledgementAfterNewerDeleteLeavesProof() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let identity = normalizationIdentity("recipe-1")
    let saveSequence = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: saveSequence, mutationGeneration: 1)
    _ = try await writer.appendDelete(identity, mutationGeneration: 2)
    _ = try await writer.acknowledge(sequence: saveSequence, mutationGeneration: 1)

    let restarted = try makeWriter(root: root)
    let normalized = try restarted.normalizeForBootstrapSynchronously()

    #expect(normalized.snapshot.recoveryState.outbox.map(\.operation) == [.delete])
    #expect(normalized.snapshot.recoveryState.outbox.map(\.delivery.state) == [.pending])
    #expect(normalized.removalProofs.contains(MirrorOutboxRemovalProof(
        identity: identity,
        operation: .save,
        sequence: saveSequence,
        mutationGeneration: 1,
        reason: .acknowledged)))
}

@Test("a permanently blocked intent stays terminal through normalization with a proof")
func blockedPermanentStaysTerminalThroughNormalization() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let sequence = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    _ = try await writer.markBlockedPermanent(sequence: sequence, mutationGeneration: 1)

    let restarted = try makeWriter(root: root)
    let normalized = try restarted.normalizeForBootstrapSynchronously()

    #expect(normalized.snapshot.recoveryState.outbox.map(\.delivery.state) == [.blockedPermanent])
    #expect(normalized.removalProofs.contains(MirrorOutboxRemovalProof(
        identity: normalizationIdentity("recipe-1"),
        operation: .save,
        sequence: sequence,
        mutationGeneration: 1,
        reason: .terminalFailure)))
    // No restart-retry was appended for the terminal row.
    #expect(normalized.snapshot.recoveryState.lastIntentSequence == 3)
}

@Test("remote-delete supersession is a separate terminal state that keeps the save payload")
func remoteDeleteSupersessionIsTerminalAndRetainsPayload() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let sequence = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    _ = try await writer.markSupersededByRemoteDelete(sequence: sequence, mutationGeneration: 1)

    let restarted = try makeWriter(root: root)
    let normalized = try restarted.normalizeForBootstrapSynchronously()
    let row = try #require(normalized.snapshot.recoveryState.outbox.first)

    #expect(row.delivery.state == .supersededByRemoteDelete)
    #expect(try row.record?.decode()["name"] as? String == "v1")
    #expect(normalized.removalProofs.contains(MirrorOutboxRemovalProof(
        identity: normalizationIdentity("recipe-1"),
        operation: .save,
        sequence: sequence,
        mutationGeneration: 1,
        reason: .remoteDeleteSupersession)))
    // Terminal: no restart-retry transition was appended for it.
    #expect(normalized.snapshot.recoveryState.lastIntentSequence == 3)
}

@Test("remote-delete supersession applies to a pending save but never to a delete intent")
func remoteDeleteSupersessionRules() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let pendingSave = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSupersededByRemoteDelete(sequence: pendingSave, mutationGeneration: 1)
    let state = try writer.recoveredCheckpointSynchronously()
    #expect(state.recoveryState.outbox.first?.delivery.state == .supersededByRemoteDelete)

    let deleteSequence = try await writer.appendDelete(
        normalizationIdentity("recipe-2"), mutationGeneration: 2)
    await #expect(throws: MirrorCheckpointError.self) {
        _ = try await writer.markSupersededByRemoteDelete(
            sequence: deleteSequence, mutationGeneration: 2)
    }
}

@Test("a crash before the normalization append leaves journal and state untouched")
func crashBeforeNormalizationAppendChangesNothing() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let sequence = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)

    let failing = try makeWriter(root: root, failurePoint: .beforeNormalizationAppend)
    #expect(throws: ShadowMirrorCheckpointWriterError.injectedFailure(.beforeNormalizationAppend)) {
        try failing.normalizeForBootstrapSynchronously()
    }

    // Nothing was appended and nothing was applied: a fresh writer still sees the sent row.
    let recovered = try makeWriter(root: root)
    let replayed = try recovered.recoveredCheckpointSynchronously()
    #expect(replayed.recoveryState.outbox.map(\.delivery.state) == [.sent])
    #expect(replayed.recoveryState.lastIntentSequence == 2)
}

@Test("a crash after the durable normalization append replays the transition exactly once")
func crashAfterNormalizationAppendReplaysExactlyOnce() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let sequence = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)

    let failing = try makeWriter(root: root, failurePoint: .afterNormalizationAppend)
    #expect(throws: ShadowMirrorCheckpointWriterError.injectedFailure(.afterNormalizationAppend)) {
        try failing.normalizeForBootstrapSynchronously()
    }
    // The failed writer is fenced: its in-memory state lags the durable journal.
    #expect(throws: ShadowMirrorCheckpointWriterError.fenced) {
        _ = try failing.appendSaveSynchronously(
            normalizationRecord("recipe-2"), mutationGeneration: 2, changedFields: ["name"])
    }

    // Restart replays the durable retry exactly once; normalization has nothing left to do.
    let recovered = try makeWriter(root: root)
    let normalized = try recovered.normalizeForBootstrapSynchronously()
    #expect(normalized.snapshot.recoveryState.outbox.map(\.delivery.state) == [.pending])
    #expect(normalized.snapshot.recoveryState.lastIntentSequence == 3)
}

@Test("normalization output has no sent rows and one retryable change per record identity")
func normalizationPostconditionsHold() async throws {
    let root = try normalizationRoot()
    let writer = try makeWriter(root: root)
    let first = try await writer.appendSave(
        normalizationRecord("recipe-1"), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: first, mutationGeneration: 1)
    let second = try await writer.appendSave(
        normalizationRecord("recipe-1", value: "v2"), mutationGeneration: 2,
        changedFields: ["name"])
    _ = try await writer.markSent(sequence: second, mutationGeneration: 2)
    let otherSent = try await writer.appendSave(
        normalizationRecord("recipe-2"), mutationGeneration: 3, changedFields: ["name"])
    _ = try await writer.markSent(sequence: otherSent, mutationGeneration: 3)
    _ = try await writer.appendDelete(normalizationIdentity("recipe-3"), mutationGeneration: 4)

    let restarted = try makeWriter(root: root)
    let normalized = try restarted.normalizeForBootstrapSynchronously()
    let outbox = normalized.snapshot.recoveryState.outbox

    #expect(!outbox.contains { $0.delivery.state == .sent })
    let retryableByIdentity = Dictionary(
        grouping: outbox.filter { $0.delivery.state == .pending },
        by: { $0.record?.identity ?? $0.tombstone! })
    #expect(retryableByIdentity.values.allSatisfy { $0.count == 1 })
    #expect(retryableByIdentity.count == 3)
}
#endif
