#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

// SP-D 990.4.1 — RecipeMemoryImageCodec (CKAsset round-trip) + the Recipe→RecipeMemory→
// RecipeMemoryImage cascade chain. Mirrors CodecAndCascadeTests' style in the sibling
// HouseholdRecordsTests target; lives here because RecipeMemoryImageCodec and
// HouseholdLocalStore are both HouseholdSync-module types.
//
// RecipeMemory itself is built as a plain CKRecord below (no HouseholdRecords dependency
// needed) since only its `.deleteSelf` cascade shape — not its manifest field typing, which
// is pinned in HouseholdRecordsTests/CodecAndCascadeTests.swift — matters for this file.

private let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

// MARK: - Codec round-trip

@Test func recipeMemoryImageRoundTripsThroughCKAsset() throws {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let image = RecipeMemoryImage(memoryID: "mem-1", mimeType: "image/jpeg",
                                   createdAt: created, imageData: Data("photo-bytes".utf8))
    let record = try RecipeMemoryImageCodec.makeRecord(image, zoneID: zoneID)

    #expect(record.recordType == "RecipeMemoryImage")
    #expect(record.recordID.recordName == "rmemimg:mem-1")
    #expect((record["recipeMemory"] as? CKRecord.Reference)?.action == .deleteSelf)
    #expect((record["recipeMemory"] as? CKRecord.Reference)?.recordID.recordName == "mem-1")

    let decoded = try RecipeMemoryImageCodec.decode(record)
    #expect(decoded == image)
}

@Test func recipeMemoryImageDecodeThrowsMissingAssetWhenFieldAbsent() {
    let record = CKRecord(recordType: RecipeMemoryImageCodec.recordType,
                           recordID: CKRecord.ID(recordName: "rmemimg:mem-2", zoneID: zoneID))
    #expect(throws: RecipeMemoryImageCodec.CodecError.self) {
        _ = try RecipeMemoryImageCodec.decode(record)
    }
}

@Test func recipeMemoryImageDecodeThrowsEmptyAssetWhenFileIsZeroBytes() throws {
    let record = CKRecord(recordType: RecipeMemoryImageCodec.recordType,
                           recordID: CKRecord.ID(recordName: "rmemimg:mem-3", zoneID: zoneID))
    let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data().write(to: emptyURL)
    record["imageAsset"] = CKAsset(fileURL: emptyURL)

    #expect(throws: RecipeMemoryImageCodec.CodecError.self) {
        _ = try RecipeMemoryImageCodec.decode(record)
    }
}

@Test func recipeMemoryImageDecodeThrowsInvalidRecordNameWithoutPrefix() throws {
    let record = CKRecord(recordType: RecipeMemoryImageCodec.recordType,
                           recordID: CKRecord.ID(recordName: "not-the-right-prefix-mem-4", zoneID: zoneID))
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("bytes".utf8).write(to: fileURL)
    record["imageAsset"] = CKAsset(fileURL: fileURL)

    #expect(throws: RecipeMemoryImageCodec.CodecError.self) {
        _ = try RecipeMemoryImageCodec.decode(record)
    }
}

// Note: `.assetNotDownloaded` (a CKAsset present but not yet fetched to disk) is not
// constructible headlessly — that state is only ever vended by CKSyncEngine mid-fetch, and
// `CKAsset(fileURL:)`'s `fileURL` is never nil for a locally-built asset. Deferred to
// on-device verification, matching RecipeRepository.swift's existing CloudKit-account caveat.

// MARK: - Cascade chain: Recipe -> RecipeMemory -> RecipeMemoryImage

@Test func cascadeChainRecipeToMemoryToMemoryImage() throws {
    let store = HouseholdLocalStore()

    // Recipe (aggregate root) — a plain record; no ref needed for this test.
    let recipe = CKRecord(recordType: "Recipe", recordID: CKRecord.ID(recordName: "recipe-1", zoneID: zoneID))
    store.setRecord(recipe)

    // RecipeMemory cascades from Recipe via a `recipe` .deleteSelf reference — mirrors the
    // HouseholdRecordType.recipeMemory manifest ref (pinned separately in HouseholdRecordsTests).
    //
    // The memoryID must be UNIQUE across this file: `makeRecord` stages the CKAsset at a stable
    // Caches path keyed by recordName, and Swift Testing runs these tests in parallel — sharing
    // "mem-1" with the round-trip test above raced that test's 11 bytes against this one's 1,
    // failing whichever read last.
    let memoryID = "mem-cascade"
    let memory = CKRecord(recordType: "RecipeMemory", recordID: CKRecord.ID(recordName: memoryID, zoneID: zoneID))
    memory["recipe"] = CKRecord.Reference(recordID: recipe.recordID, action: .deleteSelf)
    store.setRecord(memory)

    // RecipeMemoryImage cascades from RecipeMemory via RecipeMemoryImageCodec's own `recipeMemory` ref.
    let image = try RecipeMemoryImageCodec.makeRecord(
        RecipeMemoryImage(memoryID: memoryID, createdAt: Date(), imageData: Data("x".utf8)),
        zoneID: zoneID)
    store.setRecord(image)

    // Level 1: Recipe -> RecipeMemory.
    let childrenOfRecipe = store.recordIDsCascadingFrom("recipe-1")
    #expect(childrenOfRecipe.map(\.recordName) == [memoryID])

    // Level 2: RecipeMemory -> RecipeMemoryImage. `deleteCascading` (HouseholdSyncEngine)
    // recurses through exactly this scan, so a Recipe delete sweeps the whole subtree.
    let childrenOfMemory = store.recordIDsCascadingFrom(memoryID)
    #expect(childrenOfMemory.map(\.recordName) == ["rmemimg:\(memoryID)"])
}
#endif
