#if canImport(CloudKit)
import CloudKit
import CoreLocation
import Foundation
import Testing
@testable import HouseholdSync

private let checkpointZone = CKRecordZone.ID(
    zoneName: "household-shadow",
    ownerName: CKCurrentUserDefaultName)

private func checkpointRecord() -> CKRecord {
    let record = CKRecord(
        recordType: "Recipe",
        recordID: CKRecord.ID(recordName: "recipe-shadow", zoneID: checkpointZone))
    record["name"] = "Tomato soup" as CKRecordValue
    record["servings"] = 4 as CKRecordValue
    record["updatedAt"] = Date(timeIntervalSince1970: 123) as CKRecordValue
    record["source"] = CKRecord.Reference(
        recordID: CKRecord.ID(recordName: "source-1", zoneID: checkpointZone), action: .none)
    return record
}

private func checkpointDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("shadow-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("scope identity distinguishes account, zone, role, and database")
func scopeIdentityIsExact() {
    let owner = MirrorScope(
        accountRecordName: "user-a", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .owner, databaseScope: .private)
    let participant = MirrorScope(
        accountRecordName: "user-b", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .participant, databaseScope: .shared)

    #expect(owner != participant)
    #expect(owner.matches(owner))
    #expect(!owner.matches(participant))
    #expect(owner.cacheKey != participant.cacheKey)
}

@Test("clearing a parked scope removes its adoption marker")
func clearingParkedScopeDoesNotBlockAReplacementScope() throws {
    let root = try checkpointDirectory()
    let scope = checkpointScope()
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)

    try writer.fenceAndPersistParkingSynchronously()
    try writer.fenceAndClearSynchronously()

    _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
}

@Test("adoption parking reports an injected persistence failure")
func adoptionParkingReportsPersistenceFailure() throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(),
        rootDirectory: root,
        failurePoint: .beforeParkingPersistence)

    #expect(throws: ShadowMirrorCheckpointWriterError.self) {
        try writer.fenceAndPersistParkingSynchronously()
    }
}

@Test("quarantining a parked scope removes its adoption marker")
func quarantiningParkedScopeDoesNotBlockAReplacementScope() throws {
    let root = try checkpointDirectory()
    let scope = checkpointScope()
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)

    try writer.fenceAndPersistParkingSynchronously()
    try writer.fenceAndQuarantineSynchronously()

    _ = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
}

@Test("secure archive round-trips full CKRecord state and changed keys")
func secureRecordArchivePreservesCloudKitState() throws {
    let record = checkpointRecord()
    let directory = try checkpointDirectory()
    let envelope = try ShadowMirrorRecordEnvelope.archive(record, in: directory)
    let restored = try envelope.decode()

    #expect(restored.recordID == record.recordID)
    #expect(restored.recordType == record.recordType)
    #expect(restored["name"] as? String == "Tomato soup")
    #expect(restored["source"] as? CKRecord.Reference == record["source"] as? CKRecord.Reference)
    #expect(restored.recordChangeTag == record.recordChangeTag)
    #expect(restored.creationDate == record.creationDate)
    #expect(restored.modificationDate == record.modificationDate)
    #expect(restored.creatorUserRecordID == record.creatorUserRecordID)
    #expect(restored.lastModifiedUserRecordID == record.lastModifiedUserRecordID)
    #expect(restored.parent == record.parent)
    #expect(restored.share == record.share)
    #expect(Set(restored.changedKeys()) == Set(record.changedKeys()))
}

@Test("asset archive rebinds CKAsset to generation-local durable bytes")
func assetArchiveRebindsToDurableGenerationFile() throws {
    let sourceDirectory = try checkpointDirectory()
    let sourceURL = sourceDirectory.appendingPathComponent("source-image.bin")
    try Data("image-bytes".utf8).write(to: sourceURL)
    let record = checkpointRecord()
    record["imageAsset"] = CKAsset(fileURL: sourceURL)

    let generationDirectory = sourceDirectory.appendingPathComponent("generation", isDirectory: true)
    try FileManager.default.createDirectory(at: generationDirectory, withIntermediateDirectories: true)
    let envelope = try ShadowMirrorRecordEnvelope.archive(record, in: generationDirectory)
    let restored = try envelope.decode()
    let asset = try #require(restored["imageAsset"] as? CKAsset)
    let durableURL = try #require(asset.fileURL)

    #expect(durableURL.path.hasPrefix(generationDirectory.path))
    #expect(try Data(contentsOf: durableURL) == Data("image-bytes".utf8))
    #expect(envelope.assets.first?.sha256 == ShadowMirrorDigest.sha256(Data("image-bytes".utf8)))
}

@Test("missing asset is rejected before a checkpoint can publish")
func missingAssetCannotPublish() throws {
    let record = checkpointRecord()
    record["imageAsset"] = CKAsset(fileURL: URL(fileURLWithPath: "/does/not/exist"))
    let directory = try checkpointDirectory()

    #expect(throws: ShadowMirrorRecordError.self) {
        try ShadowMirrorRecordEnvelope.archive(record, in: directory)
    }
}

@Test("logical digest is independent of keyed archive bytes")
func logicalDigestIsStableAcrossArchiveRoundTrip() throws {
    let record = checkpointRecord()
    let directory = try checkpointDirectory()
    let envelope = try ShadowMirrorRecordEnvelope.archive(record, in: directory)
    let restored = try envelope.decode()

    let originalDigest = try ShadowMirrorCanonicalDigest.record(record)
    let restoredDigest = try ShadowMirrorCanonicalDigest.record(restored)
    #expect(originalDigest == restoredDigest)
    #expect(envelope.archiveData != Data())
}

@Test("outbox preserves explicit clears and exact delivery generation")
func outboxPreservesMutationIntent() throws {
    let directory = try checkpointDirectory()
    let envelope = try ShadowMirrorRecordEnvelope.archive(checkpointRecord(), in: directory)
    let intent = MirrorOutboxIntent(
        sequence: 7,
        mutationGeneration: 2,
        operation: .save,
        record: envelope,
        changedFields: ["name"],
        clearedFields: ["notes"],
        delivery: .sent(sequence: 7, generation: 2))
    let data = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(MirrorOutboxIntent.self, from: data)

    #expect(decoded == intent)
    #expect(decoded.clearedFields == ["notes"])
    #expect(decoded.delivery == .sent(sequence: 7, generation: 2))
}

@Test("logical bundle digest ignores archive bytes and asset directory paths in outbox payloads")
func outboxLogicalDigestIsArchiveIndependent() throws {
    let sourceDirectory = try checkpointDirectory()
    let sourceURL = sourceDirectory.appendingPathComponent("source-image.bin")
    try Data("same-image".utf8).write(to: sourceURL)
    let record = checkpointRecord()
    record["imageAsset"] = CKAsset(fileURL: sourceURL)
    let first = try ShadowMirrorRecordEnvelope.archive(
        record, in: sourceDirectory.appendingPathComponent("generation-a", isDirectory: true))
    let second = try ShadowMirrorRecordEnvelope.archive(
        record, in: sourceDirectory.appendingPathComponent("generation-b", isDirectory: true))
    let firstIntent = MirrorOutboxIntent(
        sequence: 1, mutationGeneration: 1, operation: .save, record: first,
        changedFields: ["imageAsset"], delivery: .pending)
    let secondIntent = MirrorOutboxIntent(
        sequence: 1, mutationGeneration: 1, operation: .save, record: second,
        changedFields: ["imageAsset"], delivery: .pending)

    #expect(first.archiveData != second.archiveData)
    #expect(try ShadowMirrorCanonicalDigest.bundle(
        records: [], tombstones: [], outbox: [firstIntent], receipts: .init(receipts: []))
        == ShadowMirrorCanonicalDigest.bundle(
            records: [], tombstones: [], outbox: [secondIntent], receipts: .init(receipts: [])))
}

@Test("canonical record digest supports location values and distinguishes their fixed-width coordinates")
func canonicalDigestSupportsLocations() throws {
    let first = checkpointRecord()
    first["location"] = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 41.8781, longitude: -87.6298),
        altitude: 181, horizontalAccuracy: 3, verticalAccuracy: 4,
        timestamp: Date(timeIntervalSince1970: 456))
    let same = first.copy() as! CKRecord
    let different = checkpointRecord()
    different["location"] = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 41.8782, longitude: -87.6298),
        altitude: 181, horizontalAccuracy: 3, verticalAccuracy: 4,
        timestamp: Date(timeIntervalSince1970: 456))

    #expect(try ShadowMirrorCanonicalDigest.record(first) == ShadowMirrorCanonicalDigest.record(same))
    #expect(try ShadowMirrorCanonicalDigest.record(first) != ShadowMirrorCanonicalDigest.record(different))
}

@Test("receipt index only validates receipts present in the same record snapshot")
func receiptIndexRequiresReceiptRecord() throws {
    let record = CKRecord(
        recordType: "MigrationReceipt",
        recordID: CKRecord.ID(recordName: "receipt-1", zoneID: checkpointZone))
    let identity = MirrorRecordIdentity(record)
    let index = MirrorReceiptIndex(receipts: [identity])

    #expect(try index.validated(by: [record]))
    #expect(throws: MirrorCheckpointError.self) {
        try index.validated(by: [])
    }
    #expect(throws: MirrorCheckpointError.self) {
        try MirrorReceiptIndex(receipts: []).validated(by: [record])
    }
}

@Test("manifest keeps an explicit journal high-water after acknowledged intents leave the outbox")
func checkpointManifestKeepsJournalHighWater() throws {
    let directory = try checkpointDirectory()
    let envelope = try ShadowMirrorRecordEnvelope.archive(checkpointRecord(), in: directory)
    let intent = MirrorOutboxIntent(
        sequence: 7, mutationGeneration: 3, operation: .save, record: envelope,
        changedFields: ["name"])
    let bundle = try MirrorCheckpointBundle(
        scope: checkpointScope(), generationID: "generation-high-water", records: [envelope],
        outbox: [intent], engineState: MirrorEngineState(
            serialization: Data([1]), coverageRevision: 1, zoneEnsured: true),
        lastIncludedIntentSequence: 11)

    #expect(bundle.manifest.lastIntentSequence == 11)
    try bundle.validate(for: checkpointScope())
}

@Test("checkpoint rejects malformed save payloads and mismatched delivery stamps")
func checkpointRejectsMalformedOutbox() throws {
    let engineState = MirrorEngineState(serialization: Data([1]), coverageRevision: 1, zoneEnsured: true)
    let missingRecord = MirrorOutboxIntent(
        sequence: 1, mutationGeneration: 1, operation: .save)
    let mismatchedDelivery = MirrorOutboxIntent(
        sequence: 2, mutationGeneration: 2, operation: .delete,
        tombstone: MirrorRecordIdentity(
            recordType: "Recipe", recordName: "gone", zoneOwnerName: checkpointZone.ownerName,
            zoneName: checkpointZone.zoneName),
        delivery: .sent(sequence: 1, generation: 2))

    #expect(throws: MirrorCheckpointError.self) {
        try MirrorCheckpointBundle(
            scope: checkpointScope(), generationID: "invalid-save", records: [],
            outbox: [missingRecord], engineState: engineState, lastIncludedIntentSequence: 1)
    }
    #expect(throws: MirrorCheckpointError.self) {
        try MirrorCheckpointBundle(
            scope: checkpointScope(), generationID: "invalid-delivery", records: [],
            outbox: [mismatchedDelivery], engineState: engineState, lastIncludedIntentSequence: 2)
    }
}

@Test("checkpoint manifest validates its exact scope and logical digest")
func checkpointManifestIsBoundToScope() throws {
    let directory = try checkpointDirectory()
    let scope = checkpointScope()
    let bundle = try MirrorCheckpointBundle.capture(
        scope: scope,
        generationID: "generation-1",
        records: [checkpointRecord()],
        in: directory,
        engineState: MirrorEngineState(serialization: Data([1, 2, 3]), coverageRevision: 4, zoneEnsured: true),
        lastIncludedIntentSequence: 0)

    try bundle.validate(for: scope)
    let otherScope = MirrorScope(
        accountRecordName: "user-b", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .participant, databaseScope: .shared)
    #expect(throws: MirrorCheckpointError.self) {
        try bundle.validate(for: otherScope)
    }
}

@Test("checkpoint validation detects extra integrity entries and engine companion tampering")
func checkpointValidationBindsWholeManifestAndEngineState() throws {
    let bundle = try MirrorCheckpointBundle.capture(
        scope: checkpointScope(), generationID: "generation-integrity",
        records: [checkpointRecord()], in: checkpointDirectory(),
        engineState: MirrorEngineState(
            serialization: Data([9, 8, 7]), coverageRevision: 5, zoneEnsured: true),
        lastIncludedIntentSequence: 0)
    let encoded = try JSONEncoder().encode(bundle)
    var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var manifest = try #require(root["manifest"] as? [String: Any])
    var archives = try #require(manifest["recordArchiveDigests"] as? [String: Any])
    archives["unindexed-extra-record"] = String(repeating: "0", count: 64)
    manifest["recordArchiveDigests"] = archives
    root["manifest"] = manifest
    let extraIndex = try JSONDecoder().decode(
        MirrorCheckpointBundle.self,
        from: JSONSerialization.data(withJSONObject: root))

    #expect(throws: MirrorCheckpointError.self) {
        try extraIndex.validate(for: checkpointScope())
    }

    root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var engineState = try #require(root["engineState"] as? [String: Any])
    engineState["zoneEnsured"] = false
    root["engineState"] = engineState
    let alteredCompanion = try JSONDecoder().decode(
        MirrorCheckpointBundle.self,
        from: JSONSerialization.data(withJSONObject: root))

    #expect(throws: MirrorCheckpointError.self) {
        try alteredCompanion.validate(for: checkpointScope())
    }
}

@Test("checkpoint writer publishes a complete generation through current")
func checkpointWriterPublishesCompleteGeneration() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let state = MirrorEngineState(
        serialization: Data([4, 2]), coverageRevision: 1, zoneEnsured: true)

    try await writer.publish(records: [checkpointRecord()], engineState: state)

    let bundle = try #require(await writer.loadCurrent())
    #expect(bundle.manifest.scope == checkpointScope())
    #expect(bundle.engineState == state)
    #expect(bundle.records.count == 1)
    #expect(FileManager.default.fileExists(
        atPath: root.appendingPathComponent(checkpointScope().cacheKey)
            .appendingPathComponent("current").path))

    let newer = checkpointRecord()
    newer["name"] = "Newer soup" as CKRecordValue
    try await writer.publish(
        records: [newer],
        engineState: MirrorEngineState(
            serialization: Data([5]), coverageRevision: 2, zoneEnsured: true))
    let replaced = try #require(await writer.loadCurrent())
    #expect(replaced.engineState.coverageRevision == 2)
    #expect(try replaced.records.first?.decode()["name"] as? String == "Newer soup")
}

@Test("published outbox assets are generation-local and survive journal asset cleanup")
func publishedOutboxAssetsAreSelfContained() async throws {
    let root = try checkpointDirectory()
    let sourceURL = root.appendingPathComponent("source-image.bin")
    try Data("outbox-image".utf8).write(to: sourceURL)
    let record = checkpointRecord()
    record["imageAsset"] = CKAsset(fileURL: sourceURL)
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    _ = try await writer.appendSave(
        record, mutationGeneration: 1, changedFields: ["imageAsset"])
    try await writer.publish(
        records: [record],
        engineState: MirrorEngineState(
            serialization: Data([1]), coverageRevision: 1, zoneEnsured: true))

    let scopeDirectory = checkpointScopeDirectory(in: root)
    let journalAssets = scopeDirectory.appendingPathComponent("journal-assets", isDirectory: true)
    try FileManager.default.removeItem(at: journalAssets)
    let bundle = try #require(await writer.loadCurrent())
    let restored = try #require(try bundle.outbox.first?.record?.decode())
    let restoredAsset = try #require(restored["imageAsset"] as? CKAsset)
    let restoredURL = try #require(restoredAsset.fileURL)

    #expect(restoredURL.path.contains("/generations/"))
    #expect(restoredURL.path.contains("/outbox-assets/1/"))
    #expect(try Data(contentsOf: restoredURL) == Data("outbox-image".utf8))
}

@Test("journal assets survive their source and corruption quarantines the scope")
func journalAssetsAreDurableAndValidatedDuringReplay() async throws {
    let root = try checkpointDirectory()
    let sourceURL = root.appendingPathComponent("journal-source.bin")
    try Data("journal-image".utf8).write(to: sourceURL)
    let record = checkpointRecord()
    record["imageAsset"] = CKAsset(fileURL: sourceURL)
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    _ = try await writer.appendSave(
        record, mutationGeneration: 1, changedFields: ["imageAsset"])
    try FileManager.default.removeItem(at: sourceURL)

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let durableRecord = try #require(
        try await recovered.recoveryState().outbox.first?.record?.decode())
    let durableAsset = try #require(durableRecord["imageAsset"] as? CKAsset)
    #expect(try Data(contentsOf: #require(durableAsset.fileURL)) == Data("journal-image".utf8))

    let assetDirectory = checkpointScopeDirectory(in: root)
        .appendingPathComponent("journal-assets/1", isDirectory: true)
    let assetURL = try #require(
        FileManager.default.contentsOfDirectory(
            at: assetDirectory, includingPropertiesForKeys: nil).first)
    try Data("corrupt".utf8).write(to: assetURL, options: .atomic)
    let quarantined = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    #expect(await quarantined.recoveryState().outbox.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("writer derives a complete receipt index from the same record snapshot")
func checkpointWriterPersistsCompleteReceiptIndex() async throws {
    let receipt = CKRecord(
        recordType: "MigrationReceipt",
        recordID: CKRecord.ID(recordName: "receipt-writer", zoneID: checkpointZone))
    let writer = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: checkpointDirectory())

    try await writer.publish(
        records: [checkpointRecord(), receipt],
        engineState: MirrorEngineState(
            serialization: Data([1]), coverageRevision: 1, zoneEnsured: true))

    let bundle = try #require(await writer.loadCurrent())
    #expect(bundle.receipts.receipts == [MirrorRecordIdentity(receipt)])
}

@Test("every pre-pointer publication failure leaves the prior generation current")
func failedPublicationKeepsPriorGeneration() async throws {
    for _ in 0..<2 {
        for failurePoint in [
            ShadowMirrorCheckpointFailurePoint.afterRecordsWrite,
            .afterStateWrite,
            .afterManifestWrite,
        ] {
            let root = try checkpointDirectory()
            let prior = checkpointRecord()
            prior["name"] = "Prior soup" as CKRecordValue
            let stableWriter = try ShadowMirrorCheckpointWriter(
                scope: checkpointScope(), rootDirectory: root)
            try await stableWriter.publish(
                records: [prior],
                engineState: MirrorEngineState(
                    serialization: Data([1]), coverageRevision: 1, zoneEnsured: true))

            let candidate = checkpointRecord()
            candidate["name"] = "Candidate soup" as CKRecordValue
            let failingWriter = try ShadowMirrorCheckpointWriter(
                scope: checkpointScope(), rootDirectory: root, failurePoint: failurePoint)
            do {
                try await failingWriter.publish(
                    records: [candidate],
                    engineState: MirrorEngineState(
                        serialization: Data([2]), coverageRevision: 2, zoneEnsured: true))
                Issue.record("Expected deterministic checkpoint failure at \(failurePoint)")
            } catch let error as ShadowMirrorCheckpointWriterError {
                #expect(error == .injectedFailure(failurePoint))
            }

            let recovered = try #require(await stableWriter.loadCurrent())
            let record = try #require(try recovered.records.first?.decode())
            #expect(record["name"] as? String == "Prior soup")
            #expect(recovered.engineState.coverageRevision == 1)
            let expectedDigest = try ShadowMirrorCanonicalDigest.bundle(
                records: [prior], tombstones: [], outbox: [], receipts: .init(receipts: []))
            #expect(recovered.manifest.logicalDigest == expectedDigest)
        }
    }
}

@Test("journal recovery preserves a delete tombstone after an uncheckpointed save")
func journalRecoveryPreservesSaveThenDelete() async throws {
    let root = try checkpointDirectory()
    let record = checkpointRecord()
    let identity = MirrorRecordIdentity(record)
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    _ = try await writer.appendSave(
        record,
        mutationGeneration: 1,
        changedFields: ["name"])
    _ = try await writer.appendDelete(identity, mutationGeneration: 2)

    let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let recovery = await recoveredWriter.recoveryState()
    #expect(recovery.tombstones == [identity])
    #expect(recovery.outbox.map(\.operation) == [.delete])
    #expect(recovery.lastIntentSequence == 2)
}

@Test("acknowledgement removes the exact sent mutation and durably rebases a newer edit")
func acknowledgementRebasesNewerMutation() async throws {
    let root = try checkpointDirectory()
    let first = checkpointRecord()
    first["name"] = "First edit" as CKRecordValue
    let second = checkpointRecord()
    second["name"] = "Second edit" as CKRecordValue
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    let firstSequence = try await writer.appendSave(
        first, mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: firstSequence, mutationGeneration: 1)
    let secondSequence = try await writer.appendSave(
        second, mutationGeneration: 2, changedFields: ["name"])
    let rebased = second.copy() as! CKRecord
    rebased["serverMarker"] = "system fields rebased" as CKRecordValue
    await #expect(throws: MirrorCheckpointError.self) {
        _ = try await writer.acknowledge(
            sequence: firstSequence, mutationGeneration: 1)
    }
    let acknowledgementSequence = try await writer.acknowledge(
        sequence: firstSequence, mutationGeneration: 1, rebasedRecord: rebased)

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let recovery = await recovered.recoveryState()
    #expect(recovery.outbox.map(\.sequence) == [secondSequence])
    #expect(acknowledgementSequence == 4)
    #expect(recovery.outbox.first?.delivery == .pending)
    #expect(try recovery.outbox.first?.record?.decode()["serverMarker"] as? String
        == "system fields rebased")
}

@Test("acknowledging an older delete preserves a newer save without a delete rebase")
func deleteAcknowledgementPreservesNewerSave() async throws {
    let root = try checkpointDirectory()
    let record = checkpointRecord()
    let identity = MirrorRecordIdentity(record)
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    let deleteSequence = try await writer.appendDelete(identity, mutationGeneration: 1)
    _ = try await writer.markSent(sequence: deleteSequence, mutationGeneration: 1)
    let saveSequence = try await writer.appendSave(
        record, mutationGeneration: 2, changedFields: ["name"])
    _ = try await writer.acknowledge(sequence: deleteSequence, mutationGeneration: 1)

    let recovery = await writer.recoveryState()
    #expect(recovery.outbox.map(\.sequence) == [saveSequence])
    #expect(recovery.outbox.map(\.operation) == [.save])
    #expect(recovery.tombstones.isEmpty)
}

@Test("a later user transition supersedes pending and permanently blocked intents")
func laterMutationSupersedesUnsentIntents() async throws {
    let root = try checkpointDirectory()
    let first = checkpointRecord()
    first["name"] = "First edit" as CKRecordValue
    let second = checkpointRecord()
    second["name"] = "Second edit" as CKRecordValue
    let third = checkpointRecord()
    third["name"] = "Third edit" as CKRecordValue
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    let firstSequence = try await writer.appendSave(
        first, mutationGeneration: 1, changedFields: ["name"])
    let secondSequence = try await writer.appendSave(
        second, mutationGeneration: 2, changedFields: ["name"])
    #expect(await writer.recoveryState().outbox.map(\.sequence) == [secondSequence])
    _ = try await writer.markSent(sequence: secondSequence, mutationGeneration: 2)
    _ = try await writer.markBlockedPermanent(sequence: secondSequence, mutationGeneration: 2)
    let thirdSequence = try await writer.appendSave(
        third, mutationGeneration: 3, changedFields: ["name"])

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(firstSequence == 1)
    #expect(await recovered.recoveryState().outbox.map(\.sequence) == [thirdSequence])
    #expect(await recovered.recoveryState().outbox.first?.delivery == .pending)
}

@Test("transient failure returns the exact sent intent to pending; permanent failure stays blocked")
func deliveryFailuresRemainDurable() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let sequence = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    let rebased = checkpointRecord()
    rebased["name"] = "Retry with server fields" as CKRecordValue
    _ = try await writer.markTransientFailure(
        sequence: sequence, mutationGeneration: 1, rebasedRecord: rebased)
    #expect(await writer.recoveryState().outbox.first?.delivery == .pending)
    #expect(try await writer.recoveryState().outbox.first?.record?.decode()["name"] as? String
        == "Retry with server fields")

    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    _ = try await writer.markBlockedPermanent(sequence: sequence, mutationGeneration: 1)
    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(await recovered.recoveryState().outbox.first?.delivery
        == .blockedPermanent(sequence: sequence, generation: 1))
}

@Test("a rejected transition never poisons the durable journal or consumes a sequence")
func invalidTransitionDoesNotReachJournal() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    await #expect(throws: MirrorCheckpointError.self) {
        _ = try await writer.appendSave(
            checkpointRecord(), mutationGeneration: 0, changedFields: ["name"])
    }
    let sequence = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    await #expect(throws: MirrorCheckpointError.self) {
        _ = try await writer.markSent(sequence: sequence, mutationGeneration: 999)
    }
    let sentTransition = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    #expect(sequence == 1)
    #expect(sentTransition == 2)
    #expect(await recovered.recoveryState().outbox.map(\.sequence) == [1])
}

@Test("post-pointer crash keeps journal entries at manifest high-water from replaying twice")
func postPointerCrashDoesNotReplayIncludedJournalEntry() async throws {
    for _ in 0..<2 {
        let root = try checkpointDirectory()
        let record = checkpointRecord()
        let initialWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
        let sequence = try await initialWriter.appendSave(
            record, mutationGeneration: 1, changedFields: ["name"])
        let crashingWriter = try ShadowMirrorCheckpointWriter(
            scope: checkpointScope(), rootDirectory: root, failurePoint: .afterPointerPublication)

        do {
            try await crashingWriter.publish(
                records: [record],
                engineState: MirrorEngineState(
                    serialization: Data([3]), coverageRevision: 1, zoneEnsured: true))
            Issue.record("Expected deterministic post-pointer failure")
        } catch ShadowMirrorCheckpointWriterError.injectedFailure(.afterPointerPublication) {}

        let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
        let recovery = await recoveredWriter.recoveryState()
        #expect(recovery.outbox.map(\.sequence) == [sequence])
        #expect(recovery.lastIntentSequence == sequence)
    }
}

@Test("a duplicate complete stale journal frame quarantines after a post-pointer crash")
func duplicateStaleJournalFrameQuarantinesAfterPostPointerCrash() async throws {
    let root = try checkpointDirectory()
    let record = checkpointRecord()
    let initialWriter = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: root)
    _ = try await initialWriter.appendSave(
        record, mutationGeneration: 1, changedFields: ["name"])
    let crashingWriter = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: root, failurePoint: .afterPointerPublication)

    do {
        try await crashingWriter.publish(
            records: [record],
            engineState: MirrorEngineState(
                serialization: Data([3]), coverageRevision: 1, zoneEnsured: true))
        Issue.record("Expected deterministic post-pointer failure")
    } catch ShadowMirrorCheckpointWriterError.injectedFailure(.afterPointerPublication) {}

    let journalURL = checkpointScopeDirectory(in: root).appendingPathComponent("journal.wal")
    let frame = try Data(contentsOf: journalURL)
    var duplicatedJournal = frame
    duplicatedJournal.append(frame)
    try duplicatedJournal.write(to: journalURL, options: .atomic)

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(await recovered.recoveryState().outbox.isEmpty)
    #expect(await recovered.recoveryState().lastIntentSequence == 0)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("a durable acknowledgement survives an interrupted checkpoint without reviving the intent")
func interruptedAckCheckpointDoesNotReviveIntent() async throws {
    let root = try checkpointDirectory()
    let record = checkpointRecord()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let sequence = try await writer.appendSave(
        record, mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.markSent(sequence: sequence, mutationGeneration: 1)
    _ = try await writer.acknowledge(sequence: sequence, mutationGeneration: 1)
    let crashingWriter = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: root, failurePoint: .afterPointerPublication)

    do {
        try await crashingWriter.publish(
            records: [record],
            engineState: MirrorEngineState(
                serialization: Data([3]), coverageRevision: 1, zoneEnsured: true))
        Issue.record("Expected deterministic post-pointer failure")
    } catch ShadowMirrorCheckpointWriterError.injectedFailure(.afterPointerPublication) {}

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(await recovered.recoveryState().outbox.isEmpty)
    #expect(await recovered.recoveryState().lastIntentSequence == 3)
}

@Test("scope anchor is durable and exact before its first journal transition")
func scopeAnchorPrecedesFirstJournalTransition() async throws {
    let root = try checkpointDirectory()
    let scope = checkpointScope()
    let writer = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)

    _ = try await writer.appendDelete(MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)

    let anchorURL = checkpointScopeDirectory(in: root).appendingPathComponent("scope.anchor")
    let anchor = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: anchorURL)) as? [String: Any])
    let anchoredScope = try #require(anchor["scope"] as? [String: Any])
    #expect(anchor["formatVersion"] as? Int == 1)
    #expect(anchor["cacheKey"] as? String == scope.cacheKey)
    #expect(anchoredScope["accountRecordName"] as? String == scope.accountRecordName)
    #expect(anchoredScope["zoneOwnerName"] as? String == scope.zoneOwnerName)
    #expect((anchor["integrityDigest"] as? String)?.count == 64)
}

@Test("anchor failure before the first journal append leaves an empty recovered snapshot")
func anchorFailureBeforeFirstJournalAppendLeavesEmptyRecoveredSnapshot() async throws {
    let root = try checkpointDirectory()
    let scope = checkpointScope()
    let scopeDirectory = root.appendingPathComponent(scope.cacheKey, isDirectory: true)
    let failingWriter = try ShadowMirrorCheckpointWriter(
        scope: scope,
        rootDirectory: root,
        failurePoint: .afterScopeAnchorWrite)

    do {
        _ = try await failingWriter.appendDelete(
            MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)
        Issue.record("Expected deterministic post-anchor failure")
    } catch ShadowMirrorCheckpointWriterError.injectedFailure(.afterScopeAnchorWrite) {}

    let anchorURL = scopeDirectory.appendingPathComponent("scope.anchor")
    let anchor = try JSONDecoder().decode(
        MirrorScopeAnchor.self, from: Data(contentsOf: anchorURL))
    try anchor.validate(for: scope, in: scopeDirectory)
    #expect(!FileManager.default.fileExists(
        atPath: scopeDirectory.appendingPathComponent("journal.wal").path))

    let recovered = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let snapshot = await recovered.recoveredCheckpoint()
    #expect(snapshot.hasValidatedAnchor)
    #expect(snapshot.current == nil)
    #expect(snapshot.recoveryState.outbox.isEmpty)
    #expect(snapshot.recoveryState.tombstones.isEmpty)
    #expect(snapshot.recoveryState.lastIntentSequence == 0)
}

@Test("reopening an anchored writer skips the first-anchor failure point")
func reopeningAnchoredWriterSkipsFirstAnchorFailurePoint() async throws {
    let root = try checkpointDirectory()
    let scope = checkpointScope()
    let firstWriter = try ShadowMirrorCheckpointWriter(scope: scope, rootDirectory: root)
    let firstSequence = try await firstWriter.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)

    let reopenedWriter = try ShadowMirrorCheckpointWriter(
        scope: scope,
        rootDirectory: root,
        failurePoint: .afterScopeAnchorWrite)
    let secondSequence = try await reopenedWriter.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 2)

    #expect(firstSequence == 1)
    #expect(secondSequence == 2)
    #expect(await reopenedWriter.recoveryState().lastIntentSequence == secondSequence)
}

@Test("scope anchor rejects tampering and mismatched scopes")
func scopeAnchorRejectsTamperingAndMismatchedScopes() async throws {
    let tamperedRoot = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: tamperedRoot)
    _ = try await writer.appendDelete(MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)
    let anchorURL = checkpointScopeDirectory(in: tamperedRoot).appendingPathComponent("scope.anchor")
    var anchor = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: anchorURL)) as? [String: Any])
    anchor["integrityDigest"] = String(repeating: "0", count: 64)
    try JSONSerialization.data(withJSONObject: anchor).write(to: anchorURL, options: .atomic)

    let quarantined = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: tamperedRoot)
    #expect(await quarantined.recoveryState().outbox.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: tamperedRoot.appendingPathComponent("quarantine").path))

    let mismatchRoot = try checkpointDirectory()
    let owner = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: mismatchRoot)
    _ = try await owner.appendDelete(MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)
    let participantScope = MirrorScope(
        accountRecordName: "user-b", zoneOwnerName: checkpointZone.ownerName,
        zoneName: checkpointZone.zoneName, householdID: "household-a",
        role: .participant, databaseScope: .shared)
    let participant = try ShadowMirrorCheckpointWriter(
        scope: participantScope, rootDirectory: mismatchRoot)
    _ = try await participant.appendDelete(MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)
    let participantAnchor = mismatchRoot.appendingPathComponent(participantScope.cacheKey)
        .appendingPathComponent("scope.anchor")
    let ownerAnchor = checkpointScopeDirectory(in: mismatchRoot).appendingPathComponent("scope.anchor")
    try FileManager.default.removeItem(at: ownerAnchor)
    try FileManager.default.copyItem(at: participantAnchor, to: ownerAnchor)

    let mismatched = try ShadowMirrorCheckpointWriter(
        scope: checkpointScope(), rootDirectory: mismatchRoot)
    #expect(await mismatched.recoveryState().outbox.isEmpty)
    #expect(FileManager.default.fileExists(
        atPath: mismatchRoot.appendingPathComponent("quarantine").path))
}

@Test("checkpoint recovery replays the contiguous suffix above its manifest high-water")
func checkpointRecoveryReplaysJournalSuffix() async throws {
    let root = try checkpointDirectory()
    let record = checkpointRecord()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    _ = try await writer.appendSave(record, mutationGeneration: 1, changedFields: ["name"])
    try await writer.publish(
        records: [record],
        engineState: MirrorEngineState(
            serialization: Data([1]), coverageRevision: 1, zoneEnsured: true))
    let deleteSequence = try await writer.appendDelete(
        MirrorRecordIdentity(record), mutationGeneration: 2)

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let state = await recovered.recoveryState()
    #expect(try await recovered.loadCurrent() != nil)
    #expect(state.lastIntentSequence == deleteSequence)
    #expect(state.outbox.map(\.operation) == [.delete])
    #expect(state.tombstones == [MirrorRecordIdentity(record)])
}

@Test("anchored journal without current recovers only durable intents")
func anchoredJournalWithoutCurrentRecoversDurableIntents() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let sequence = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let state = await recovered.recoveryState()
    #expect(FileManager.default.fileExists(
        atPath: checkpointScopeDirectory(in: root).appendingPathComponent("scope.anchor").path))
    #expect(try await recovered.loadCurrent() == nil)
    #expect(state.lastIntentSequence == sequence)
    #expect(state.outbox.map(\.sequence) == [sequence])
}

@Test("recovered checkpoint snapshot exposes a read-only recovery-only plan")
func recoveredCheckpointSnapshotExposesRecoveryOnlyPlan() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let sequence = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])

    let snapshot = await writer.recoveredCheckpoint()
    #expect(snapshot.scope == checkpointScope())
    #expect(snapshot.current == nil)
    #expect(snapshot.hasValidatedAnchor)
    #expect(snapshot.isRecoveryOnly)
    #expect(snapshot.recoveryState.lastIntentSequence == sequence)
    #expect(snapshot.recoveryState.outbox.map(\.sequence) == [sequence])
}

@Test("known scope recovers legacy unanchored journal without selecting anonymous bytes")
func knownScopeRecoversLegacyUnanchoredJournal() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let sequence = try await writer.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)
    try FileManager.default.removeItem(
        at: checkpointScopeDirectory(in: root).appendingPathComponent("scope.anchor"))

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let snapshot = await recovered.recoveredCheckpoint()
    #expect(!snapshot.hasValidatedAnchor)
    #expect(snapshot.isRecoveryOnly)
    #expect(try await recovered.loadCurrent() == nil)
    #expect(snapshot.recoveryState.lastIntentSequence == sequence)
    #expect(snapshot.recoveryState.outbox.map(\.operation) == [.delete])
}

@Test("a journal append failure fences the writer before later transitions")
func journalAppendFailureFencesWriter() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let firstSequence = try await writer.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 1)
    let journalURL = checkpointScopeDirectory(in: root).appendingPathComponent("journal.wal")
    let journalBeforeFailure = try Data(contentsOf: journalURL)

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o400], ofItemAtPath: journalURL.path)
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }

    await #expect(throws: (any Error).self) {
        _ = try await writer.appendDelete(
            MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 2)
    }

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    await #expect(throws: ShadowMirrorCheckpointWriterError.fenced) {
        _ = try await writer.appendDelete(
            MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 3)
    }

    #expect(try Data(contentsOf: journalURL) == journalBeforeFailure)
    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(await recovered.recoveryState().lastIntentSequence == firstSequence)
}

@Test("recovery truncates a torn tail before a later append")
func recoveryTruncatesTornTailBeforeLaterAppend() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let saveSequence = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    let journalURL = checkpointScopeDirectory(in: root).appendingPathComponent("journal.wal")
    let handle = try FileHandle(forWritingTo: journalURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data([0, 0, 0]))
    try handle.synchronize()
    try handle.close()

    let repaired = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let deleteSequence = try await repaired.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 2)
    let restarted = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let state = await restarted.recoveryState()
    #expect(saveSequence == 1)
    #expect(deleteSequence == 2)
    #expect(state.lastIntentSequence == deleteSequence)
    #expect(state.outbox.map(\.operation) == [.delete])
}

@Test("torn final journal frame is ignored during recovery")
func tornFinalJournalFrameIsIgnored() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let sequence = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    let journalURL = root.appendingPathComponent(checkpointScope().cacheKey)
        .appendingPathComponent("journal.wal")
    let handle = try FileHandle(forWritingTo: journalURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    handle.write(Data([0, 0, 0]))
    try handle.synchronize()

    let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let recovery = await recoveredWriter.recoveryState()
    #expect(recovery.outbox.map(\.sequence) == [sequence])
}

@Test("a complete checksum-corrupt final journal frame quarantines instead of disappearing")
func corruptCompleteFinalJournalFrameQuarantines() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    _ = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    let journalURL = checkpointScopeDirectory(in: root).appendingPathComponent("journal.wal")
    var journal = try Data(contentsOf: journalURL)
    journal[JournalFrameLength.header + 1] ^= 0x01
    try journal.write(to: journalURL, options: .atomic)

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    #expect(await recovered.recoveryState().outbox.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("invalid interior journal frame quarantines the scope")
func invalidInteriorJournalFrameQuarantinesScope() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    _ = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 2)
    let journalURL = root.appendingPathComponent(checkpointScope().cacheKey)
        .appendingPathComponent("journal.wal")
    var journal = try Data(contentsOf: journalURL)
    journal[JournalFrameLength.header + 1] ^= 0x01
    try journal.write(to: journalURL, options: .atomic)

    let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    let recovery = await recoveredWriter.recoveryState()
    #expect(recovery.outbox.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("a missing journal frame above checkpoint high-water quarantines the scope")
func journalSequenceGapQuarantinesScope() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    _ = try await writer.appendSave(
        checkpointRecord(), mutationGeneration: 1, changedFields: ["name"])
    _ = try await writer.appendDelete(
        MirrorRecordIdentity(checkpointRecord()), mutationGeneration: 2)
    let journalURL = checkpointScopeDirectory(in: root).appendingPathComponent("journal.wal")
    let journal = try Data(contentsOf: journalURL)
    let firstPayloadLength = journal.prefix(8).reduce(UInt64(0)) {
        ($0 << 8) | UInt64($1)
    }
    let firstFrameLength = JournalFrameLength.header + Int(firstPayloadLength)
    try Data(journal.dropFirst(firstFrameLength)).write(to: journalURL, options: .atomic)

    let recovered = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)

    #expect(await recovered.recoveryState().outbox.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("records-only current generation is quarantined instead of selected")
func recordsOnlyGenerationIsQuarantined() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    try await writer.publish(
        records: [checkpointRecord()],
        engineState: MirrorEngineState(
            serialization: Data([8]), coverageRevision: 1, zoneEnsured: true))
    let scopeDirectory = root.appendingPathComponent(checkpointScope().cacheKey)
    let generationID = try String(
        contentsOf: scopeDirectory.appendingPathComponent("current"),
        encoding: .utf8)
    try FileManager.default.removeItem(
        at: scopeDirectory.appendingPathComponent("generations")
            .appendingPathComponent(generationID)
            .appendingPathComponent("engine-state.json"))

    let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(try await recoveredWriter.loadCurrent() == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("state-only current generation is quarantined instead of selected")
func stateOnlyGenerationIsQuarantined() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    try await writer.publish(
        records: [checkpointRecord()],
        engineState: MirrorEngineState(
            serialization: Data([8]), coverageRevision: 1, zoneEnsured: true))
    let scopeDirectory = checkpointScopeDirectory(in: root)
    let generationID = try String(
        contentsOf: scopeDirectory.appendingPathComponent("current"), encoding: .utf8)
    try FileManager.default.removeItem(
        at: scopeDirectory.appendingPathComponent("generations")
            .appendingPathComponent(generationID)
            .appendingPathComponent("records.json"))

    let recoveredWriter = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    #expect(try await recoveredWriter.loadCurrent() == nil)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("quarantine").path))
}

@Test("current pointer rejects a generation whose manifest names a different directory")
func currentPointerBindsGenerationDirectory() async throws {
    let root = try checkpointDirectory()
    let writer = try ShadowMirrorCheckpointWriter(scope: checkpointScope(), rootDirectory: root)
    try await writer.publish(
        records: [checkpointRecord()],
        engineState: MirrorEngineState(
            serialization: Data([1]), coverageRevision: 1, zoneEnsured: true))
    let scopeDirectory = checkpointScopeDirectory(in: root)
    let generationID = try String(
        contentsOf: scopeDirectory.appendingPathComponent("current"), encoding: .utf8)
    let manifestURL = scopeDirectory.appendingPathComponent("generations")
        .appendingPathComponent(generationID).appendingPathComponent("manifest.json")
    var rootObject = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    var manifest = try #require(rootObject["manifest"] as? [String: Any])
    manifest["generationID"] = UUID().uuidString
    rootObject["manifest"] = manifest
    try JSONSerialization.data(withJSONObject: rootObject).write(to: manifestURL, options: .atomic)

    await #expect(throws: MirrorCheckpointError.self) {
        _ = try await writer.loadCurrent()
    }
}

private func checkpointScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "user-a", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .owner, databaseScope: .private)
}

private func checkpointScopeDirectory(in root: URL) -> URL {
    root.appendingPathComponent(checkpointScope().cacheKey, isDirectory: true)
}

private enum JournalFrameLength {
    static let header = 40
}
#endif
