#if canImport(CloudKit)
import CloudKit
import Foundation

// SP-A Phase 3 — recipe imagery as a CKAsset in the household zone. The 1:1 recipe header image
// (prod recipe_images.image_bytes, a LargeBinary that can exceed 1 MB) maps to a CKAsset; the
// CKSyncEngine uploads/downloads the asset as part of the record. recordName = rimg:<recipeID>
// (DET); `recipe` is the .deleteSelf CASCADE parent (deleting the recipe removes its image).

public struct RecipeImage: Equatable {
    public let recipeID: String
    public var mimeType: String
    public var prompt: String
    public var generatedAt: Date
    public var imageData: Data
    public init(recipeID: String, mimeType: String = "image/png", prompt: String = "",
                generatedAt: Date, imageData: Data) {
        self.recipeID = recipeID; self.mimeType = mimeType; self.prompt = prompt
        self.generatedAt = generatedAt; self.imageData = imageData
    }
}

public enum RecipeImageCodec {
    public static let recordType = "RecipeImage"
    public static func recordName(forRecipe recipeID: String) -> String { "rimg:\(recipeID)" }

    public enum CodecError: Error, CustomStringConvertible {
        case missingAsset            // no imageAsset field at all
        case assetNotDownloaded      // the CKAsset exists but CKSyncEngine hasn't downloaded its file yet
        case emptyAsset              // downloaded file is zero bytes (prod image_bytes is NOT NULL)
        case invalidRecordName(String)
        public var description: String {
            switch self {
            case .missingAsset: return "RecipeImage record has no imageAsset field"
            case .assetNotDownloaded: return "RecipeImage asset present but not yet downloaded (fileURL nil)"
            case .emptyAsset: return "RecipeImage asset downloaded as zero bytes"
            case .invalidRecordName(let n): return "RecipeImage recordName missing 'rimg:' prefix: \(n)"
            }
        }
    }

    public static func makeRecord(_ image: RecipeImage, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let recordID = CKRecord.ID(recordName: recordName(forRecipe: image.recipeID), zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        try encode(image, into: record, zoneID: zoneID)
        return record
    }

    /// Stages the image bytes at a STABLE Caches path keyed by the recordName, then points a
    /// CKAsset at it. Stable (not a random temp file) so: (a) re-encodes OVERWRITE one file
    /// instead of leaking a blob per call; (b) Caches isn't OS-evicted mid-operation the way
    /// the temp dir is, so the file survives until CKSyncEngine uploads it; (c) the file persists
    /// for the serverRecordChanged rebase, which copies the CKAsset's URL forward.
    public static func encode(_ image: RecipeImage, into record: CKRecord, zoneID: CKRecordZone.ID) throws {
        record["mimeType"] = image.mimeType as CKRecordValue
        record["prompt"] = image.prompt as CKRecordValue
        record["generatedAt"] = image.generatedAt as CKRecordValue
        record["recipe"] = CKRecord.Reference(
            recordID: CKRecord.ID(recordName: image.recipeID, zoneID: zoneID), action: .deleteSelf)
        let url = try assetStagingURL(forRecordName: record.recordID.recordName)
        try image.imageData.write(to: url, options: .atomic)
        record["imageAsset"] = CKAsset(fileURL: url)
    }

    public static func decode(_ record: CKRecord) throws -> RecipeImage {
        guard let asset = record["imageAsset"] as? CKAsset else { throw CodecError.missingAsset }
        guard let url = asset.fileURL else { throw CodecError.assetNotDownloaded }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw CodecError.emptyAsset }
        let name = record.recordID.recordName
        guard name.hasPrefix("rimg:") else { throw CodecError.invalidRecordName(name) }
        return RecipeImage(
            recipeID: String(name.dropFirst("rimg:".count)),
            mimeType: record["mimeType"] as? String ?? "image/png",
            prompt: record["prompt"] as? String ?? "",
            generatedAt: record["generatedAt"] as? Date ?? Date(timeIntervalSince1970: 0),
            imageData: data)
    }

    /// A stable per-record staging file under Caches (created on demand).
    private static func assetStagingURL(forRecordName recordName: String) throws -> URL {
        let caches = try FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent("RecipeImageAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = recordName.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).bin")
    }
}
#endif
