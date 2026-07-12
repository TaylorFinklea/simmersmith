import Foundation
import Testing
@testable import SimmerSmithKit

/// Bead simmersmith-990.4.3 — the migration loader distinguishes 404
/// ("no memories route / vanished recipe" → safe empty) from real failures
/// (→ receipt withheld, retry next launch). That split only works if
/// `fetchRecipeMemories` surfaces 404 as `.notFound` like its sibling M15
/// endpoints, instead of the generic `.server(...)` mapping. These tests pin
/// that contract with a stubbed URLSession.
private final class StubURLProtocol: URLProtocol {
    /// (status, body) per request path; set before each test.
    nonisolated(unsafe) static var responses: [String: (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let (status, body) = Self.responses[path] ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedClient() -> SimmerSmithAPIClient {
    let suiteName = "RecipeMemoriesNotFoundTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set("http://stub.test", forKey: ConnectionSettingsStore.Keys.serverURL)
    let keychain = KeychainStore(service: "RecipeMemoriesNotFoundTests-\(UUID().uuidString)")
    let settings = ConnectionSettingsStore(defaults: defaults, keychain: keychain)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return SimmerSmithAPIClient(settingsStore: settings, session: URLSession(configuration: config))
}

@Suite(.serialized)  // StubURLProtocol.responses is shared static state
struct RecipeMemoriesNotFoundTests {
    @Test
    func a404SurfacesAsNotFound() async {
        StubURLProtocol.responses = ["/api/recipes/rmem-404/memories": (404, Data())]
        let client = makeStubbedClient()
        do {
            _ = try await client.fetchRecipeMemories(recipeID: "rmem-404")
            Issue.record("expected a throw")
        } catch SimmerSmithAPIError.notFound {
            // The contract the migration loader depends on.
        } catch {
            Issue.record("404 surfaced as \(error) instead of SimmerSmithAPIError.notFound")
        }
    }

    @Test
    func aServerErrorStaysAServerError() async throws {
        StubURLProtocol.responses = ["/api/recipes/rmem-500/memories": (500, Data())]
        let client = makeStubbedClient()
        do {
            _ = try await client.fetchRecipeMemories(recipeID: "rmem-500")
            Issue.record("expected a throw")
        } catch SimmerSmithAPIError.notFound {
            Issue.record("500 must not map to .notFound — the migration would treat a real failure as 'no memories' and stamp its receipt over lost data")
        } catch is SimmerSmithAPIError {
            // .server(...) — the correct shape.
        }
    }

    @Test
    func aSuccessDecodesTheList() async throws {
        let json = """
        [{"id": "rmem-ok-1", "body": "note", "created_at": "2026-03-23T19:30:00Z", "photo_url": null}]
        """
        StubURLProtocol.responses = ["/api/recipes/rmem-ok/memories": (200, Data(json.utf8))]
        let client = makeStubbedClient()
        let memories = try await client.fetchRecipeMemories(recipeID: "rmem-ok")
        #expect(memories.map(\.id) == ["rmem-ok-1"])
        #expect(memories.first?.photoUrl == nil)
    }
}
