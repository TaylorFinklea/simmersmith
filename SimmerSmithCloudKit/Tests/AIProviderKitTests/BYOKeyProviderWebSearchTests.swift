import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-2 — headless tests for BYOKeyProvider's web-search request mode.
//
// Mirrors the request-body + parsing tests in BYOKeyProviderTests (which cover the
// plain chat-completion path). These cover the `wantsWebSearch` path that backs
// `searchRecipeOnWeb`:
//   • OpenAI → Responses API (/v1/responses): `input`, `tools: [{type: web_search}]`,
//     no chat `messages`/`response_format`.
//   • Anthropic → Messages API: the `web_search_20250305` tool block with max_uses,
//     no structured-output prefill.
//   • Parsing the Responses / Messages payload shapes (incl. tool blocks to skip)
//     → the recipe text → RecipeAIParser.parseRecipe.
//   • A provider/key that can't run the tool degrades with a clear error.
//
// The shared MockHTTPTransport lives in BYOKeyProviderTests.swift (same test target);
// MockKeyStore + the json/body helpers are file-private there, so this file carries
// its own file-private copies.

// MARK: - File-private helpers

/// A simple KeyStore that holds one key per provider ID in memory.
private final class MockKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    func key(for provider: String) -> String? { keys[provider] }
    func setKey(_ key: String?, for provider: String) { keys[provider] = key }
}

private func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func bodyJSON(from transport: MockHTTPTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - OpenAI Responses payload helpers

/// A minimal OpenAI Responses payload: a `web_search_call` item (skipped) followed by
/// a `message` item whose content carries the recipe JSON as an `output_text` block.
private func openAIResponsesData(recipeJSON: String) -> Data {
    let json = """
    {
      "output": [
        {"type": "web_search_call", "id": "ws_1", "status": "completed"},
        {"type": "message", "role": "assistant",
         "content": [{"type": "output_text", "text": \(jsonString(recipeJSON))}]}
      ]
    }
    """
    return json.data(using: .utf8)!
}

/// An Anthropic Messages payload with the web_search tool blocks before the final text.
private func anthropicWebSearchData(recipeJSON: String) -> Data {
    let json = """
    {
      "content": [
        {"type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search",
         "input": {"query": "best crispy waffles"}},
        {"type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": []},
        {"type": "text", "text": \(jsonString(recipeJSON))}
      ]
    }
    """
    return json.data(using: .utf8)!
}

private let sampleRecipeJSON = #"""
{"name": "Yeast-Raised Waffles", "source_url": "https://www.seriouseats.com/waffles", "source_label": "Serious Eats", "ingredients": [{"ingredient_name": "flour", "quantity": 2, "unit": "cup"}], "steps": [{"instruction": "Mix and rest overnight."}], "notes": "Crispest edges."}
"""#

// MARK: - OpenAI web-search request body

@Test("OpenAI web search posts to the Responses API with the web_search tool and input")
func openAIWebSearchRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: openAIResponsesData(recipeJSON: sampleRecipeJSON))
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore,
                                  openAIModel: "gpt-4o", transport: transport)
    let request = AIRequest(
        feature: .weekGen,
        prompt: RecipeAIPrompt.webSearchInput(query: "best crispy waffles"),
        wantsWebSearch: true
    )
    _ = try await provider.generate(request)

    // Hits the Responses endpoint, not chat/completions.
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.openai.com/v1/responses")

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "gpt-4o")
    // Responses API uses `input`, not chat `messages`.
    let input = body["input"] as? String
    #expect(input?.contains("best crispy waffles") == true)
    #expect(body["messages"] == nil)
    #expect(body["response_format"] == nil)
    // The web_search tool block.
    let tools = body["tools"] as? [[String: Any]]
    #expect(tools?.count == 1)
    #expect(tools?.first?["type"] as? String == "web_search")
}

@Test("OpenAI web search parses the Responses payload into the recipe text")
func openAIWebSearchResponseParsing() async throws {
    let transport = MockHTTPTransport(responseData: openAIResponsesData(recipeJSON: sampleRecipeJSON))
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    let response = try await provider.generate(
        AIRequest(feature: .weekGen, prompt: "find waffles", wantsWebSearch: true)
    )
    // The web_search_call item is skipped; only the message text survives.
    let recipe = try RecipeAIParser.parseRecipe(response.text)
    #expect(recipe.name == "Yeast-Raised Waffles")
    #expect(recipe.sourceUrl == "https://www.seriouseats.com/waffles")
}

@Test("OpenAI web search also accepts a top-level output_text convenience field")
func openAIWebSearchOutputTextField() async throws {
    let json = """
    {"output_text": \(jsonString(sampleRecipeJSON)), "output": []}
    """
    let transport = MockHTTPTransport(responseData: json.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    let response = try await provider.generate(
        AIRequest(feature: .weekGen, prompt: "x", wantsWebSearch: true)
    )
    #expect(try RecipeAIParser.parseRecipe(response.text).name == "Yeast-Raised Waffles")
}

@Test("OpenAI web search 401 throws AIError.httpError")
func openAIWebSearch401() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"invalid_api_key"}"#.data(using: .utf8)!,
        responseStatus: 401
    )
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-bad", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.httpError(provider: "openai", statusCode: 401, body: #"{"error":"invalid_api_key"}"#)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x", wantsWebSearch: true))
    }
}

@Test("OpenAI web search missing key throws AIError.noKeyConfigured")
func openAIWebSearchMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = MockKeyStore()
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openAI)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x", wantsWebSearch: true))
    }
}

// MARK: - Anthropic web-search request body

@Test("Anthropic web search carries the web_search_20250305 tool with max_uses and no prefill")
func anthropicWebSearchRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: anthropicWebSearchData(recipeJSON: sampleRecipeJSON))
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore,
                                  anthropicModel: "claude-opus-4-5", transport: transport)
    let request = AIRequest(
        feature: .weekGen,
        prompt: RecipeAIPrompt.webSearchInput(query: "best crispy waffles"),
        // A web-search request asks for JSON too; the provider must NOT add a chat
        // prefill (incompatible with the tool loop) — it relies on the prompt instead.
        wantsStructuredJSON: true,
        wantsWebSearch: true
    )
    _ = try await provider.generate(request)

    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.anthropic.com/v1/messages")

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "claude-opus-4-5")
    // SP-C AI-2 review I3: the web-search path caps at 4096 (recipe_search_ai.py:247),
    // not the 8000 the week-planner path uses — one recipe fits, halving the max cost.
    #expect(body["max_tokens"] as? Int == 4096)

    let tools = body["tools"] as? [[String: Any]]
    let tool = tools?.first
    #expect(tool?["type"] as? String == "web_search_20250305")
    #expect(tool?["name"] as? String == "web_search")
    #expect(tool?["max_uses"] as? Int == 5)

    // Only the user message — no assistant `{` prefill (the tool loop forbids it).
    let messages = body["messages"] as? [[String: Any]]
    #expect(messages?.count == 1)
    #expect(messages?.first?["role"] as? String == "user")
    #expect(messages?.contains(where: { $0["role"] as? String == "assistant" }) == false)
}

@Test("Anthropic web search skips tool blocks and parses the final text into a recipe")
func anthropicWebSearchResponseParsing() async throws {
    let transport = MockHTTPTransport(responseData: anthropicWebSearchData(recipeJSON: sampleRecipeJSON))
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    let response = try await provider.generate(
        AIRequest(feature: .weekGen, prompt: "find waffles", wantsWebSearch: true)
    )
    let recipe = try RecipeAIParser.parseRecipe(response.text)
    #expect(recipe.name == "Yeast-Raised Waffles")
    #expect(recipe.sourceLabel == "Serious Eats")
}

@Test("Anthropic web search 401 throws AIError.httpError")
func anthropicWebSearch401() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"auth"}"#.data(using: .utf8)!,
        responseStatus: 401
    )
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-bad", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.httpError(provider: "anthropic", statusCode: 401, body: #"{"error":"auth"}"#)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x", wantsWebSearch: true))
    }
}

@Test("Anthropic web search missing key throws AIError.noKeyConfigured")
func anthropicWebSearchMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = MockKeyStore()
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.anthropic)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x", wantsWebSearch: true))
    }
}

// MARK: - Graceful degradation

@Test("web search on a provider without the tool degrades with webSearchUnsupported")
func webSearchUnsupportedProvider() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = MockKeyStore()
    keyStore.setKey("g-test", for: "gemini")
    let provider = BYOKeyProvider(model: .gemini, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.webSearchUnsupported(.gemini)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x", wantsWebSearch: true))
    }
}

// MARK: - The non-web-search path is unchanged

@Test("a plain (non-web-search) OpenAI request still hits chat/completions")
func plainRequestStillUsesChatCompletions() async throws {
    let chatJSON = """
    {"choices": [{"message": {"role": "assistant", "content": \(jsonString(#"{"ok":1}"#))}}]}
    """
    let transport = MockHTTPTransport(responseData: chatJSON.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x"))
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
}
