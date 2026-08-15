#if canImport(CloudKit)
import CloudKit
import Foundation

/// Owns bytes received through CKSyncEngine callback-scoped CKAsset URLs for the lifetime of
/// one household engine. Every callback gets an immutable destination so later fetches cannot
/// mutate a record already held by the store, an outbound batch, or checkpoint publication.
final class HouseholdFetchedAssetStore: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?

    func rehomeAssets(in record: CKRecord) throws -> CKRecord {
        let copy = record.copy() as! CKRecord
        for fieldName in record.allKeys().sorted() {
            guard let asset = record[fieldName] as? CKAsset else { continue }
            guard let sourceURL = asset.fileURL else {
                throw ShadowMirrorRecordError.missingAsset(fieldName)
            }
            let destinationURL = try reserveDestination()
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw ShadowMirrorRecordError.unreadableAsset(fieldName)
            }
            copy[fieldName] = CKAsset(fileURL: destinationURL)
        }
        return copy
    }

    deinit {
        let ownedDirectory = lock.withLock { directory }
        if let ownedDirectory {
            try? FileManager.default.removeItem(at: ownedDirectory)
        }
    }

    private func reserveDestination() throws -> URL {
        try lock.withLock {
            let ownedDirectory: URL
            if let directory {
                ownedDirectory = directory
            } else {
                let created = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "simmersmith-fetched-assets-\(UUID().uuidString)",
                    isDirectory: true)
                try FileManager.default.createDirectory(
                    at: created,
                    withIntermediateDirectories: true)
                directory = created
                ownedDirectory = created
            }
            return ownedDirectory.appendingPathComponent(UUID().uuidString)
        }
    }
}
#endif
