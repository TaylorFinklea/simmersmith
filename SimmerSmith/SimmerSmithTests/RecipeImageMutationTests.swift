import CloudKit
import Foundation
import HouseholdSync
import SimmerSmithKit
import Testing
import UIKit

@testable import SimmerSmith

@MainActor
@Suite(.serialized)
struct RecipeImageMutationTests {
    @Test
    func successfulLegacyImageMutationsInvalidateTheRecipe() async throws {
        let fixture = try RecipeImageMutationFixture(statusCode: 200)

        try await fixture.appState.regenerateRecipeImage(recipeID: "R1")
        #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 1)
        try await fixture.appState.uploadRecipeImage(recipeID: "R1", imageData: Data([1]))
        #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 2)
        try await fixture.appState.deleteRecipeImage(recipeID: "R1")

        #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 3)
        #expect(fixture.appState.recipeImageLoader.revision(for: "R2") == 0)
    }

    @Test
    func failedLegacyImageMutationDoesNotInvalidate() async throws {
        let fixture = try RecipeImageMutationFixture(statusCode: 500)

        await #expect(throws: (any Error).self) {
            try await fixture.appState.uploadRecipeImage(
                recipeID: "R1",
                imageData: Data([1])
            )
        }

        #expect(fixture.appState.recipeImageLoader.revision(for: "R1") == 0)
    }

    @Test
    func successfulCloudKitImageMutationsInvalidateTheRecipe() async throws {
        let suite = "RecipeImageMutationCloudKitTests-\(UUID().uuidString)"
        let settings = ConnectionSettingsStore(
            defaults: try #require(UserDefaults(suiteName: suite)),
            keychain: KeychainStore(service: suite)
        )
        let appState = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            settingsStore: settings
        )
        let session = HouseholdSession(householdID: suite)
        let repository = RecipeRepository(session: session)
        appState.recipeRepository = repository
        let recipeID = "cloudkit-image-\(UUID().uuidString)"
        try repository.save(RecipeDraft(recipeId: recipeID, name: "CloudKit Image"))

        let original = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01])
        let replacement = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02])
        try await appState.uploadRecipeImage(recipeID: recipeID, imageData: original)
        #expect(appState.recipeImageLoader.revision(for: recipeID) == 1)
        try await appState.uploadRecipeImage(recipeID: recipeID, imageData: replacement)

        #expect(appState.recipeImageLoader.revision(for: recipeID) == 2)
        #expect(try await appState.fetchRecipeImageBytes(recipeID: recipeID) == replacement)

        #expect(session.promoteCachedAuthority())
        try await appState.deleteRecipeImage(recipeID: recipeID)
        #expect(appState.recipeImageLoader.revision(for: recipeID) == 3)
    }

    @Test
    func rejectedCloudKitImageMutationDoesNotReportSuccessOrInvalidate() async throws {
        let suite = "RecipeImageMutationRejectedCloudKitTests-\(UUID().uuidString)"
        let settings = ConnectionSettingsStore(
            defaults: try #require(UserDefaults(suiteName: suite)),
            keychain: KeychainStore(service: suite)
        )
        let appState = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            settingsStore: settings
        )
        let session = HouseholdSession(householdID: suite)
        let repository = RecipeRepository(session: session)
        appState.recipeRepository = repository
        let recipeID = "cloudkit-image-rejected-\(UUID().uuidString)"
        try repository.save(RecipeDraft(recipeId: recipeID, name: "Rejected CloudKit Image"))
        session.detach()

        await #expect(throws: HouseholdDataPlaneResult.notAuthoritative) {
            try await appState.uploadRecipeImage(
                recipeID: recipeID,
                imageData: Data([0xFF, 0xD8, 0xFF, 0xE0])
            )
        }
        #expect(appState.recipeImageLoader.revision(for: recipeID) == 0)
    }
}

private final class RecipeImageMutationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let expectedRequests: Set<String> = [
            "POST /api/recipes/R1/image/regenerate",
            "PUT /api/recipes/R1/image",
            "DELETE /api/recipes/R1/image",
        ]
        let status = expectedRequests.contains("\(method) \(path)") ? Self.statusCode : 404
        let body = Data(
            """
            {
              "recipe_id": "R1",
              "name": "Recipe One",
              "updated_at": "2026-08-12T00:00:00Z",
              "image_url": "legacy://R1?revision=updated"
            }
            """.utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
private final class RecipeImageMutationFixture {
    let appState: AppState
    private let lifecycleDirectory: URL

    init(statusCode: Int) throws {
        RecipeImageMutationURLProtocol.statusCode = statusCode
        let suite = "RecipeImageMutationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(
            "http://recipe-image-mutation.test",
            forKey: ConnectionSettingsStore.Keys.serverURL
        )
        let settings = ConnectionSettingsStore(
            defaults: defaults,
            keychain: KeychainStore(service: suite)
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecipeImageMutationURLProtocol.self]
        let client = SimmerSmithAPIClient(
            settingsStore: settings,
            session: URLSession(configuration: configuration)
        )
        lifecycleDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-image-mutation-\(UUID().uuidString)")
        appState = AppState(
            modelContainer: try makeSimmerSmithModelContainer(inMemory: true),
            settingsStore: settings,
            apiClient: client,
            householdLifecycleDirectoryURL: lifecycleDirectory
        )
        appState.recipeImageLoader = RecipeImageLoader(
            fetcher: { _ in Data() },
            decoder: { _, _ in UIImage() }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: lifecycleDirectory)
    }
}
