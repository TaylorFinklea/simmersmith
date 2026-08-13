import Foundation
import Testing
import UIKit

@testable import SimmerSmith

@MainActor
struct RecipeImageLoaderTests {
    @Test
    func nilTokenDoesNotFetch() async {
        var fetchCount = 0
        let loader = RecipeImageLoader(
            fetcher: { _ in
                fetchCount += 1
                return Data([1])
            },
            decoder: { _, _ in UIImage() }
        )

        let image = await loader.image(recipeID: "A", imageToken: nil)

        #expect(image == nil)
        #expect(fetchCount == 0)
    }

    @Test
    func validBytesDecodeOnceAndCache() async {
        var fetchCount = 0
        var decodeCount = 0
        let expected = UIImage()
        let loader = RecipeImageLoader(
            fetcher: { _ in
                fetchCount += 1
                return Data([1])
            },
            decoder: { _, maximumDimension in
                decodeCount += 1
                #expect(maximumDimension == 1024)
                return expected
            }
        )

        let first = await loader.image(recipeID: "A", imageToken: "one")
        let second = await loader.image(recipeID: "A", imageToken: "one")

        #expect(first === expected)
        #expect(second === expected)
        #expect(fetchCount == 1)
        #expect(decodeCount == 1)
        #expect(loader.cacheCountLimit == 40)
    }

    @Test
    func corruptBytesReturnNilAndAreNotCached() async {
        var fetchCount = 0
        let loader = RecipeImageLoader(fetcher: { _ in
            fetchCount += 1
            return Data("not an image".utf8)
        })

        #expect(await loader.image(recipeID: "A", imageToken: "bad") == nil)
        #expect(await loader.image(recipeID: "A", imageToken: "bad") == nil)
        #expect(fetchCount == 2)
    }

    @Test
    func concurrentRequestsShareOneFetchAndDecode() async {
        let gate = RecipeImageTestGate()
        var fetchCount = 0
        var decodeCount = 0
        let loader = RecipeImageLoader(
            fetcher: { _ in
                fetchCount += 1
                await gate.wait()
                return Data([1])
            },
            decoder: { _, _ in
                decodeCount += 1
                return UIImage()
            }
        )

        async let first = loader.image(recipeID: "A", imageToken: "shared")
        async let second = loader.image(recipeID: "A", imageToken: "shared")
        while fetchCount == 0 {
            await Task.yield()
        }
        gate.open()
        _ = await (first, second)

        #expect(fetchCount == 1)
        #expect(decodeCount == 1)
    }

    @Test
    func targetedInvalidationRefetchesOnlyOneRecipe() async {
        var fetches: [String: Int] = [:]
        let loader = RecipeImageLoader(
            fetcher: { recipeID in
                fetches[recipeID, default: 0] += 1
                return Data([1])
            },
            decoder: { _, _ in UIImage() }
        )
        _ = await loader.image(recipeID: "A", imageToken: "one")
        _ = await loader.image(recipeID: "B", imageToken: "one")

        loader.invalidate(recipeID: "A")
        _ = await loader.image(recipeID: "A", imageToken: "one")
        _ = await loader.image(recipeID: "B", imageToken: "one")

        #expect(fetches["A"] == 2)
        #expect(fetches["B"] == 1)
        #expect(loader.revision(for: "A") == 1)
        #expect(loader.revision(for: "B") == 0)
    }

    @Test
    func invalidatedCompletionCannotRepopulateTheCache() async {
        let gate = RecipeImageTestGate()
        var fetchCount = 0
        let loader = RecipeImageLoader(
            fetcher: { _ in
                fetchCount += 1
                await gate.wait()
                return Data([1])
            },
            decoder: { _, _ in UIImage() }
        )

        let staleTask = Task {
            await loader.image(recipeID: "A", imageToken: "one")
        }
        while fetchCount == 0 {
            await Task.yield()
        }
        loader.invalidate(recipeID: "A")
        gate.open()

        #expect(await staleTask.value == nil)
        #expect(await loader.image(recipeID: "A", imageToken: "one") != nil)
        #expect(fetchCount == 2)
    }

    @Test
    func stalePresentationCompletionCannotReplaceNewRequest() {
        let first = RecipeImageRequestID(recipeID: "A", imageToken: "one", loaderRevision: 0)
        let second = RecipeImageRequestID(recipeID: "A", imageToken: "two", loaderRevision: 0)
        let oldImage = UIImage()
        let newImage = UIImage()
        var state = RecipeImagePresentationState()

        let firstEpoch = state.begin(first)
        let secondEpoch = state.begin(second)
        state.complete(oldImage, requestID: first, epoch: firstEpoch)
        state.complete(newImage, requestID: second, epoch: secondEpoch)

        #expect(state.image(for: second) === newImage)
        #expect(state.shouldRetry(second) == false)
    }

    @Test
    func unresolvedPresentationRetriesButLoadedPresentationDoesNot() {
        let request = RecipeImageRequestID(recipeID: "A", imageToken: "one", loaderRevision: 0)
        var state = RecipeImagePresentationState()

        let epoch = state.begin(request)
        #expect(state.shouldRetry(request))
        state.complete(UIImage(), requestID: request, epoch: epoch)

        #expect(state.shouldRetry(request) == false)
    }

    @Test
    func productionDecoderDownsamplesLargestPixelDimension() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 2048, height: 1536),
            format: format
        )
        let data = renderer.pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2048, height: 1536))
        }

        let image = try #require(await RecipeImageDecoder.downsample(data, maximumDimension: 1024))
        let cgImage = try #require(image.cgImage)

        #expect(max(cgImage.width, cgImage.height) == 1024)
    }
}

@MainActor
private final class RecipeImageTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}
