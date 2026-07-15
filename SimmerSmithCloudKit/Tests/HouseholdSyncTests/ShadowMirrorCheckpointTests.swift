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

private func checkpointScope() -> MirrorScope {
    MirrorScope(
        accountRecordName: "user-a", zoneOwnerName: "user-a", zoneName: "household",
        householdID: "household-a", role: .owner, databaseScope: .private)
}
#endif
