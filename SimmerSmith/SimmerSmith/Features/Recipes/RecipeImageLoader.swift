import Foundation
import ImageIO
import Observation
import UIKit

struct RecipeImageRequestID: Hashable {
    let recipeID: String
    let imageToken: String
    let loaderRevision: Int
}

struct RecipeImagePresentationState {
    private var requestID: RecipeImageRequestID?
    private var epoch = 0
    private var image: UIImage?

    mutating func begin(_ requestID: RecipeImageRequestID?) -> Int {
        epoch &+= 1
        self.requestID = requestID
        image = nil
        return epoch
    }

    mutating func complete(
        _ image: UIImage?,
        requestID: RecipeImageRequestID,
        epoch: Int
    ) {
        guard self.epoch == epoch, self.requestID == requestID else { return }
        self.image = image
    }

    func image(for requestID: RecipeImageRequestID?) -> UIImage? {
        self.requestID == requestID ? image : nil
    }

    func shouldRetry(_ requestID: RecipeImageRequestID?) -> Bool {
        requestID != nil && self.requestID == requestID && image == nil
    }
}

@MainActor
@Observable
final class RecipeImageLoader {
    typealias Fetcher = @MainActor (String) async throws -> Data
    typealias Decoder = @MainActor (Data, CGFloat) async -> UIImage?

    @ObservationIgnored private let fetcher: Fetcher
    @ObservationIgnored private let decoder: Decoder
    @ObservationIgnored private let cache = NSCache<NSString, UIImage>()
    @ObservationIgnored private var inFlight: [RecipeImageRequestID: Task<UIImage?, Never>] = [:]
    @ObservationIgnored private var cachedKeys: [String: Set<NSString>] = [:]
    private var revisions: [String: Int] = [:]

    init(
        fetcher: @escaping Fetcher,
        decoder: @escaping Decoder = RecipeImageDecoder.downsample
    ) {
        self.fetcher = fetcher
        self.decoder = decoder
        cache.countLimit = 40
    }

    var cacheCountLimit: Int {
        cache.countLimit
    }

    func revision(for recipeID: String) -> Int {
        revisions[recipeID, default: 0]
    }

    func image(recipeID: String, imageToken: String?) async -> UIImage? {
        guard let imageToken else { return nil }
        let requestID = RecipeImageRequestID(
            recipeID: recipeID,
            imageToken: imageToken,
            loaderRevision: revision(for: recipeID)
        )
        let cacheKey = cacheKey(for: requestID)
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if let existing = inFlight[requestID] {
            return await existing.value
        }

        let task: Task<UIImage?, Never> = Task { [fetcher, decoder] in
            do {
                let bytes = try await fetcher(recipeID)
                guard !Task.isCancelled else { return nil }
                let image = await decoder(bytes, 1024)
                guard !Task.isCancelled else { return nil }
                return image
            } catch {
                return nil
            }
        }
        inFlight[requestID] = task
        let decoded = await task.value
        inFlight[requestID] = nil

        guard requestID.loaderRevision == revision(for: recipeID) else { return nil }
        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: cacheKey)
        cachedKeys[recipeID, default: []].insert(cacheKey)
        return decoded
    }

    func invalidate(recipeID: String) {
        revisions[recipeID, default: 0] &+= 1
        let staleRequests = inFlight.keys.filter { $0.recipeID == recipeID }
        for requestID in staleRequests {
            inFlight.removeValue(forKey: requestID)?.cancel()
        }
        for key in cachedKeys.removeValue(forKey: recipeID) ?? [] {
            cache.removeObject(forKey: key)
        }
    }

    private func cacheKey(for requestID: RecipeImageRequestID) -> NSString {
        "\(requestID.recipeID)|\(requestID.imageToken)|\(requestID.loaderRevision)" as NSString
    }
}

enum RecipeImageDecoder {
    static func downsample(_ data: Data, maximumDimension: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: image)
        }.value
    }
}
