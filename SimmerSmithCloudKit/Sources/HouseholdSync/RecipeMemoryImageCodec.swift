#if canImport(CloudKit)
import CloudKit
import Foundation

// SP-D 990.4 (990.4.1) — recipe memory photos as a CKAsset in the household zone. Mirrors
// RecipeImageCodec's pattern for the 0-or-1-per-memory optional photo (Fly
// recipe_memories.image_bytes). recordName = rmemimg:<memoryID> (DET); `recipeMemory` is the
// .deleteSelf CASCADE parent (deleting the memory removes its photo). NOT in the
// HouseholdRecordType manifest -> excluded from HouseholdBackup by construction — a deliberate
// v1 exclusion: memory photos are user family photos, not regenerable AI art (see
// phases/recipe-memories-cloudkit-spec.md).

public struct RecipeMemoryImage: Equatable {
    public let memoryID: String
    public var mimeType: String
    public var createdAt: Date
    public var imageData: Data
    public init(memoryID: String, mimeType: String = "image/jpeg", createdAt: Date, imageData: Data) {
        self.memoryID = memoryID; self.mimeType = mimeType
        self.createdAt = createdAt; self.imageData = imageData
    }
}

public enum RecipeMemoryImageCodec {
    public static let recordType = "RecipeMemoryImage"
    public static func recordName(forMemory memoryID: String) -> String { "rmemimg:\(memoryID)" }

    public enum CodecError: Error, CustomStringConvertible {
        case missingAsset            // no imageAsset field at all
        case assetNotDownloaded      // the CKAsset exists but CKSyncEngine hasn't downloaded its file yet
        case emptyAsset              // downloaded file is zero bytes (prod image_bytes is NOT NULL)
        case invalidRecordName(String)
        public var description: String {
            switch self {
            case .missingAsset: return "RecipeMemoryImage record has no imageAsset field"
            case .assetNotDownloaded: return "RecipeMemoryImage asset present but not yet downloaded (fileURL nil)"
            case .emptyAsset: return "RecipeMemoryImage asset downloaded as zero bytes"
            case .invalidRecordName(let n): return "RecipeMemoryImage recordName missing 'rmemimg:' prefix: \(n)"
            }
        }
    }

    public static func makeRecord(_ image: RecipeMemoryImage, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName(forMemory: image.memoryID), zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        try encode(image, into: record, zoneID: zoneID)
        return record
    }

    /// Stages the image bytes at a STABLE Caches path keyed by the recordName, then points a
    /// CKAsset at it. Stable (not a random temp file) so: (a) re-encodes OVERWRITE one file
    /// instead of leaking a blob per call; (b) Caches isn't OS-evicted mid-operation the way
    /// the temp dir is, so the file survives until CKSyncEngine uploads it; (c) the file persists
    /// for the serverRecordChanged rebase, which copies the CKAsset's URL forward.
    public static func encode(_ image: RecipeMemoryImage, into record: CKRecord, zoneID: CKRecordZone.ID) throws {
        record["mimeType"] = image.mimeType as CKRecordValue
        record["createdAt"] = image.createdAt as CKRecordValue
        record["recipeMemory"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: image.memoryID, zoneID: zoneID), action: .deleteSelf)
        let url = try assetStagingURL(forRecordName: record.recordID.recordName)
        try image.imageData.write(to: url, options: .atomic)
        record["imageAsset"] = CKAsset(fileURL: url)
    }

    public static func decode(_ record: CKRecord) throws -> RecipeMemoryImage {
        guard let asset = record["imageAsset"] as? CKAsset else { throw CodecError.missingAsset }
        guard let url = asset.fileURL else { throw CodecError.assetNotDownloaded }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CodecError.emptyAsset }
        let name = record.recordID.recordName
        guard name.hasPrefix("rmemimg:") else { throw CodecError.invalidRecordName(name) }
        return RecipeMemoryImage(
            memoryID: String(name.dropFirst("rmemimg:".count)),
            mimeType: record["mimeType"] as? String ?? "image/jpeg",
            createdAt: record["createdAt"] as? Date ?? Date(timeIntervalSince1970: 0),
            imageData: data)
    }

    /// A stable per-record staging file under Caches (created on demand).
    private static func assetStagingURL(forRecordName recordName: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("RecipeMemoryImageAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = recordName.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).bin")
    }
}
#endif
