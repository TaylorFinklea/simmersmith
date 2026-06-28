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

// MARK: - T5 tool loop: reasoning capture (A), replay (B), thinking/temperature (C)

private func toolCallJSON(_ id: String, _ name: String) -> [String: Any] {
    ["id": id, "type": "function", "function": ["name": name, "arguments": "{}"]]
}

@Test("A: parseOpenModelsToolTurn captures reasoning_content (GLM/Kimi) + tool calls")
func parseReasoningContent() throws {
    let json: [String: Any] = [
        "choices": [[
            "message": [
                "role": "assistant", "content": NSNull(),
                "reasoning_content": "step by step",
                "tool_calls": [toolCallJSON("c1", "weeks_get_current")],
            ],
            "finish_reason": "tool_calls",
        ]],
    ]
    let turn = try BYOKeyProvider.parseOpenModelsToolTurn(json, style: .reasoningContent)
    #expect(turn.reasoning?.style == .reasoningContent)
    #expect(turn.reasoning?.text == "step by step")
    #expect(turn.toolCalls.first?.name == "weeks_get_current")
    #expect(turn.finished == false)
}

@Test("A: parseOpenModelsToolTurn captures reasoning_content + reasoning_details (MiniMax)")
func parseReasoningDetails() throws {
    let details: [[String: Any]] = [["type": "reasoning.text", "text": "think A"], ["type": "reasoning.text", "text": "think B"]]
    let json: [String: Any] = [
        "choices": [[
            "message": [
                "role": "assistant", "content": "",
                "reasoning_content": "rc",
                "reasoning_details": details,
                "tool_calls": [toolCallJSON("c1", "t")],
            ],
            "finish_reason": "tool_calls",
        ]],
    ]
    let turn = try BYOKeyProvider.parseOpenModelsToolTurn(json, style: .reasoningDetails)
    #expect(turn.reasoning?.style == .reasoningDetails)
    #expect(turn.reasoning?.text == "rc")
    let dj = try #require(turn.reasoning?.detailsJSON)
    let parsed = try JSONSerialization.jsonObject(with: Data(dj.utf8)) as? [[String: Any]]
    #expect(parsed?.count == 2)
    #expect(parsed?.first?["text"] as? String == "think A")
}

@Test("A: object-shaped tool-call arguments are re-serialized, not dropped (review fix)")
func parseObjectArgs() throws {
    let json: [String: Any] = [
        "choices": [["message": [
            "role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "c1", "type": "function",
                            "function": ["name": "weeks_update_meals", "arguments": ["week_id": "w1", "n": 3]]]],
        ], "finish_reason": "tool_calls"]],
    ]
    let turn = try BYOKeyProvider.parseOpenModelsToolTurn(json, style: .reasoningContent)
    let call = try #require(turn.toolCalls.first)
    let parsed = try JSONSerialization.jsonObject(with: Data(call.argsJSON.utf8)) as? [String: Any]
    #expect(parsed?["week_id"] as? String == "w1")
    #expect(parsed?["n"] as? Int == 3)
}

@Test("A: absent reasoning leaves the turn identical to a plain parse")
func parseNoReasoning() throws {
    let json: [String: Any] = [
        "choices": [["message": ["role": "assistant", "content": "hi"], "finish_reason": "stop"]],
    ]
    let turn = try BYOKeyProvider.parseOpenModelsToolTurn(json, style: .reasoningContent)
    #expect(turn.reasoning == nil)
    #expect(turn.text == "hi")
    #expect(turn.finished == true)
}

@Test("B: encodeOpenModelsMessages replays reasoning on the same assistant object as tool_calls")
func encodeReplay() throws {
    let detailsArr: [[String: Any]] = [["text": "d1"]]
    let detailsStr = String(data: try JSONSerialization.data(withJSONObject: detailsArr), encoding: .utf8)!
    let msg = AIChatMessage(
        role: .assistant, text: "let me check",
        toolCalls: [ToolCall(id: "c1", name: "t", argsJSON: "{}")],
        reasoning: ReasoningTrace(style: .reasoningDetails, text: "rc", detailsJSON: detailsStr)
    )
    let assistant = try #require(BYOKeyProvider.encodeOpenModelsMessages([msg], systemPrompt: nil).first)
    #expect(assistant["role"] as? String == "assistant")
    #expect(assistant["tool_calls"] != nil)
    #expect(assistant["reasoning_content"] as? String == "rc")
    #expect((assistant["reasoning_details"] as? [[String: Any]])?.first?["text"] as? String == "d1")
    #expect(assistant["content"] as? String == "let me check")
}

@Test("B: reasoning round-trips capture->history->replay (reasoning_content byte-exact, details structural)")
func reasoningRoundTrip() throws {
    let details: [[String: Any]] = [["type": "reasoning.text", "text": "X"]]
    let json: [String: Any] = [
        "choices": [["message": [
            "role": "assistant", "content": NSNull(),
            "reasoning_content": "RC-verbatim",
            "reasoning_details": details,
            "tool_calls": [toolCallJSON("c1", "t")],
        ], "finish_reason": "tool_calls"]],
    ]
    let turn = try BYOKeyProvider.parseOpenModelsToolTurn(json, style: .reasoningDetails)
    let hist = AIChatMessage(role: .assistant, text: turn.text, toolCalls: turn.toolCalls, reasoning: turn.reasoning)
    let assistant = try #require(BYOKeyProvider.encodeOpenModelsMessages([hist], systemPrompt: nil).first)
    #expect(assistant["reasoning_content"] as? String == "RC-verbatim")
    let rd = assistant["reasoning_details"] as? [[String: Any]]
    #expect(rd?.first?["text"] as? String == "X")
    #expect(rd?.first?["type"] as? String == "reasoning.text")
}

@Test("C: Kimi tool-loop uses temperature 1.0 (dropping the protocol's 0.3) and keep:all")
func kimiToolLoopTemperatureViaProtocol() async throws {
    let transport = MockHTTPTransport(responseData: omChatSuccess(content: "done"))
    let provider = openModelsProvider(.kimi, keychainID: "moonshot", transport: transport)
    // Drive through the AssistantToolChat protocol method, which hardcodes temperature 0.3.
    _ = try await (provider as AssistantToolChat).chatWithTools(messages: [.text(.user, "hi")], tools: [], systemPrompt: nil)
    let body = try omBody(transport)
    #expect((body["temperature"] as? Double) == 1.0)
    #expect((body["thinking"] as? [String: Any])?["keep"] as? String == "all")
}

@Test("C: GLM tool-loop enables Preserved Thinking; MiniMax sets reasoning_split + adaptive")
func glmMinimaxToolLoopThinking() async throws {
    let glmT = MockHTTPTransport(responseData: omChatSuccess(content: "done"))
    let glm = openModelsProvider(.glm, keychainID: "zai", transport: glmT)
    _ = try await glm.chatWithTools(messages: [.text(.user, "hi")], tools: [], systemPrompt: nil, temperature: 0.3)
    #expect(((try omBody(glmT))["thinking"] as? [String: Any])?["clear_thinking"] as? Bool == false)

    let mmT = MockHTTPTransport(responseData: omChatSuccess(content: "done"))
    let mm = openModelsProvider(.minimax, keychainID: "minimax", transport: mmT)
    _ = try await mm.chatWithTools(messages: [.text(.user, "hi")], tools: [], systemPrompt: nil, temperature: 0.3)
    let mmBody = try omBody(mmT)
    #expect(mmBody["reasoning_split"] as? Bool == true)
    #expect((mmBody["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
}
