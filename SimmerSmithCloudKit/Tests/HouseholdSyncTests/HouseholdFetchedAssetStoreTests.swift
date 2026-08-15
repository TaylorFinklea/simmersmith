#if canImport(CloudKit)
import CloudKit
import Foundation
import Testing
@testable import HouseholdSync

@Test("fetched CKAsset bytes survive after the callback source expires")
func fetchedAssetBytesOutliveCallbackSource() throws {
    let sourceDirectory = try fetchedAssetTestDirectory()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let sourceURL = sourceDirectory.appendingPathComponent("callback-photo")
    let expected = Data("callback-owned-photo".utf8)
    try expected.write(to: sourceURL)
    let record = fetchedAssetRecord()
    record["imageAsset"] = CKAsset(fileURL: sourceURL)
    let store = HouseholdFetchedAssetStore()

    let owned = try store.rehomeAssets(in: record)
    try FileManager.default.removeItem(at: sourceURL)

    let asset = try #require(owned["imageAsset"] as? CKAsset)
    let ownedURL = try #require(asset.fileURL)
    #expect(ownedURL != sourceURL)
    #expect(try Data(contentsOf: ownedURL) == expected)
}

@Test("successive fetched assets use immutable paths")
func successiveFetchedAssetsDoNotOverwriteEarlierBytes() throws {
    let sourceDirectory = try fetchedAssetTestDirectory()
    defer { try? FileManager.default.removeItem(at: sourceDirectory) }
    let sourceURL = sourceDirectory.appendingPathComponent("callback-photo")
    let firstBytes = Data("first-photo".utf8)
    let secondBytes = Data("second-photo".utf8)
    let store = HouseholdFetchedAssetStore()
    let record = fetchedAssetRecord()

    try firstBytes.write(to: sourceURL)
    record["imageAsset"] = CKAsset(fileURL: sourceURL)
    let first = try store.rehomeAssets(in: record)
    try secondBytes.write(to: sourceURL, options: .atomic)
    record["imageAsset"] = CKAsset(fileURL: sourceURL)
    let second = try store.rehomeAssets(in: record)

    let firstURL = try #require((first["imageAsset"] as? CKAsset)?.fileURL)
    let secondURL = try #require((second["imageAsset"] as? CKAsset)?.fileURL)
    #expect(firstURL != secondURL)
    #expect(try Data(contentsOf: firstURL) == firstBytes)
    #expect(try Data(contentsOf: secondURL) == secondBytes)
}

private func fetchedAssetTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "simmersmith-fetched-assets-test-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func fetchedAssetRecord() -> CKRecord {
    CKRecord(
        recordType: "RecipeImage",
        recordID: CKRecord.ID(
            recordName: "rimg:test-recipe",
            zoneID: CKRecordZone.ID(zoneName: "household-test", ownerName: "owner-test")))
}
#endif
