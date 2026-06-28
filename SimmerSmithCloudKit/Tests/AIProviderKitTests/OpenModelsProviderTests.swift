import Foundation
import Testing
@testable import AIProviderKit

// T3/T5 — headless tests for the open-models (GLM/Kimi/MiniMax) provider path.
// Reuses the module-internal MockHTTPTransport from BYOKeyProviderTests.swift; brings
// its own key store + helpers (those are file-private there).

private final class OMKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    func key(for provider: String) -> String? { keys[provider] }
    func setKey(_ key: String?, for provider: String) { keys[provider] = key }
}

private func omChatSuccess(content: String = #"{"day":1}"#, reasoning: String? = nil, reasoningDetails: String? = nil) -> Data {
    var message = "\"role\": \"assistant\", \"content\": \(omEscaped(content))"
    if let r = reasoning { message += ", \"reasoning_content\": \(omEscaped(r))" }
    if let d = reasoningDetails { message += ", \"reasoning_details\": \(d)" }
    let json = """
    { "choices": [ { "message": { \(message) }, "finish_reason": "stop" } ] }
    """
    return json.data(using: .utf8)!
}

private func omEscaped(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func omBody(_ transport: MockHTTPTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func openModelsProvider(_ vendor: OpenModelVendor, keychainID: String, transport: MockHTTPTransport, model: String = "") -> BYOKeyProvider {
    let ks = OMKeyStore()
    ks.setKey("sk-test", for: keychainID)
    return BYOKeyProvider(model: .openModels(vendor), keyStore: ks, openModelsModel: model, transport: transport)
}

// MARK: - T3 one-shot generate()

@Test("GLM one-shot body disables thinking, uses default model + one-shot temp, sends json_object, hits the Z.ai URL")
func glmOneShotBody() async throws {
    let transport = MockHTTPTransport(responseData: omChatSuccess())
    let provider = openModelsProvider(.glm, keychainID: "zai", transport: transport)
    _ = try await provider.generate(AIRequest(feature: .weekGen, systemPrompt: "plan", prompt: "go", wantsStructuredJSON: true))

    let body = try omBody(transport)
    #expect(body["model"] as? String == "glm-5.2")
    #expect((body["temperature"] as? Double) == 0.7)
    #expect((body["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.z.ai/api/paas/v4/chat/completions")
    #expect(transport.capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
}

@Test("Kimi one-shot uses the hard non-thinking temperature 0.6 and its own model id")
func kimiOneShotTemperature() async throws {
    let transport = MockHTTPTransport(responseData: omChatSuccess())
    let provider = openModelsProvider(.kimi, keychainID: "moonshot", transport: transport, model: "kimi-k2.6")
    _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "go", wantsStructuredJSON: true))

    let body = try omBody(transport)
    #expect((body["temperature"] as? Double) == 0.6)
    #expect(body["model"] as? String == "kimi-k2.6")
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.moonshot.ai/v1/chat/completions")
}

@Test("MiniMax one-shot extracts JSON from a reply that leaks a leading <think> block")
func minimaxOneShotStripsThink() async throws {
    let leaky = "<think>let me plan…</think>\n```json\n{\"meals\":[]}\n```"
    let transport = MockHTTPTransport(responseData: omChatSuccess(content: leaky))
    let provider = openModelsProvider(.minimax, keychainID: "minimax", transport: transport)
    let response = try await provider.generate(AIRequest(feature: .weekGen, prompt: "go", wantsStructuredJSON: true))
    #expect(response.text == #"{"meals":[]}"#)
    #expect(response.tier == .cloudBYOKey(.openModels(.minimax)))
}

@Test("missing open-models key throws noKeyConfigured for the right vendor")
func openModelsNoKey() async {
    let transport = MockHTTPTransport(responseData: omChatSuccess())
    // provider built WITHOUT setting the zai key:
    let provider = BYOKeyProvider(model: .openModels(.glm), keyStore: OMKeyStore(), transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openModels(.glm))) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "go"))
    }
}

@Test("stripThinkTags removes a leading think span and leaves clean JSON untouched")
func stripThink() {
    #expect(BYOKeyProvider.stripThinkTags("<think>reasoning</think>{\"a\":1}") == "{\"a\":1}")
    #expect(BYOKeyProvider.stripThinkTags("  <THINK>x</THINK>  {\"a\":1}") == "{\"a\":1}")
    #expect(BYOKeyProvider.stripThinkTags("{\"a\":1}") == "{\"a\":1}")
    #expect(BYOKeyProvider.extractJSONObject("<think>plan</think>\n```json\n{\"a\":1}\n```") == "{\"a\":1}")
}

// MARK: - T4 listModels + catalog

@Test("open-models listModels parses the vendor /models ids and hits the right URL")
func glmListModels() async throws {
    let data = #"{"data":[{"id":"glm-5.2"},{"id":"glm-4.6"}]}"#.data(using: .utf8)!
    let transport = MockHTTPTransport(responseData: data)
    let provider = openModelsProvider(.glm, keychainID: "zai", transport: transport)
    let models = try await provider.listModels()
    #expect(models == ["glm-5.2", "glm-4.6"])
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.z.ai/api/paas/v4/models")
}

@Test("catalog resolves open vendors by keychain id and raw value, and leaves openai/anthropic alone")
func catalogOpenVendor() {
    #expect(AIModelCatalog.defaultModel(for: "zai") == "glm-5.2")
    #expect(AIModelCatalog.defaultModel(for: "glm") == "glm-5.2")
    #expect(AIModelCatalog.defaultModel(for: "moonshot") == "kimi-k2.6")
    #expect(AIModelCatalog.fallback(for: "minimax").contains("MiniMax-M3"))

    let curated = AIModelCatalog.curatedModels(provider: "zai", rawIDs: ["foo", "glm-4.6", "glm-5.2"])
    #expect(curated.first == "glm-5.2")
    #expect(curated.contains("foo"))

    #expect(AIModelCatalog.defaultModel(for: "openai") == "gpt-4o")
    #expect(AIModelCatalog.defaultModel(for: "anthropic") == "claude-opus-4-5")
}
