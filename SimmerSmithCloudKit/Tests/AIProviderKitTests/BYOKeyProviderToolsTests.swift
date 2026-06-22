import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-5 — headless tests for BYOKeyProvider tool-use (chatWithTools).
//
// Reuses the file-internal MockHTTPTransport from BYOKeyProviderTests.swift (same test
// target). Verifies, with NO real API calls:
//   • OpenAI request body: model / messages (system + prior tool result + assistant
//     tool_call turn) / tools schema {type:function,function:{name,description,parameters}}
//   • Anthropic request body: model / max_tokens / system / tools schema
//     {name,description,input_schema} / tool_result + tool_use message encoding
//   • Parsing a tool_call response (both providers) → ToolUseTurn(finished:false)
//   • Parsing a final-text response (both providers) → ToolUseTurn(finished:true)

// MARK: - Local doubles

private final class MockKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    func key(for provider: String) -> String? { keys[provider] }
    func setKey(_ key: String?, for provider: String) { keys[provider] = key }
}

private func bodyJSON(from transport: MockHTTPTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let sampleTool = ToolSpec(
    name: "recipes_list",
    description: "List the household's recipes.",
    parametersSchemaJSON: #"{"type":"object","properties":{"query":{"type":"string"}}}"#
)

/// A conversation history that exercises the encoders: a user turn, an assistant turn
/// that requested a tool, and the tool's result threaded back in.
private func conversationWithPriorToolResult() -> [AIChatMessage] {
    [
        .text(.user, "What recipes do I have?"),
        AIChatMessage(
            role: .assistant,
            text: nil,
            toolCalls: [ToolCall(id: "call_1", name: "recipes_list", argsJSON: #"{"query":"all"}"#)]
        ),
        AIChatMessage(
            role: .tool,
            toolResults: [ToolResult(id: "call_1", resultJSON: #"{"recipes":["Tacos"]}"#)]
        ),
    ]
}

// MARK: - OpenAI request body

@Test("OpenAI tool-use body carries model, tools schema, system, and a prior tool result")
func openAIToolBody() async throws {
    let transport = MockHTTPTransport(
        responseData: #"{"choices":[{"message":{"content":"done"},"finish_reason":"stop"}]}"#.data(using: .utf8)!
    )
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore,
                                  openAIModel: "gpt-4o", transport: transport)

    _ = try await provider.chatWithTools(
        messages: conversationWithPriorToolResult(),
        tools: [sampleTool],
        systemPrompt: "You are SimmerSmith."
    )

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "gpt-4o")

    // tools: [{type:"function", function:{name, description, parameters}}]
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["type"] as? String == "function")
    let fn = try #require(tools[0]["function"] as? [String: Any])
    #expect(fn["name"] as? String == "recipes_list")
    #expect(fn["description"] as? String == "List the household's recipes.")
    let params = try #require(fn["parameters"] as? [String: Any])
    #expect(params["type"] as? String == "object")
    #expect(body["tool_choice"] as? String == "auto")

    // messages: system, user, assistant(tool_calls), tool(result)
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[0]["content"] as? String == "You are SimmerSmith.")

    let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
    let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
    #expect(calls[0]["id"] as? String == "call_1")
    #expect(calls[0]["type"] as? String == "function")
    let callFn = try #require(calls[0]["function"] as? [String: Any])
    #expect(callFn["name"] as? String == "recipes_list")
    #expect(callFn["arguments"] as? String == #"{"query":"all"}"#)

    let toolMsg = try #require(messages.first { $0["role"] as? String == "tool" })
    #expect(toolMsg["tool_call_id"] as? String == "call_1")
    #expect(toolMsg["content"] as? String == #"{"recipes":["Tacos"]}"#)
}

@Test("OpenAI tool_call response parses into ToolUseTurn (not finished)")
func openAIParseToolCall() async throws {
    let respJSON = """
    {"choices":[{"message":{"content":null,"tool_calls":[
      {"id":"call_42","type":"function","function":{"name":"weeks_get_current","arguments":"{\\"x\\":1}"}}
    ]},"finish_reason":"tool_calls"}]}
    """
    let transport = MockHTTPTransport(responseData: respJSON.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)

    let turn = try await provider.chatWithTools(messages: [.text(.user, "plan")], tools: [sampleTool])
    #expect(turn.finished == false)
    #expect(turn.toolCalls.count == 1)
    #expect(turn.toolCalls[0].id == "call_42")
    #expect(turn.toolCalls[0].name == "weeks_get_current")
    #expect(turn.toolCalls[0].argsJSON == #"{"x":1}"#)
}

@Test("OpenAI final-text response parses into ToolUseTurn (finished)")
func openAIParseFinalText() async throws {
    let respJSON = #"{"choices":[{"message":{"content":"Here are your recipes."},"finish_reason":"stop"}]}"#
    let transport = MockHTTPTransport(responseData: respJSON.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)

    let turn = try await provider.chatWithTools(messages: [.text(.user, "hi")], tools: [sampleTool])
    #expect(turn.finished == true)
    #expect(turn.toolCalls.isEmpty)
    #expect(turn.text == "Here are your recipes.")
}

@Test("OpenAI tool-use with no key throws noKeyConfigured")
func openAIToolNoKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let provider = BYOKeyProvider(model: .openAI, keyStore: MockKeyStore(), transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openAI)) {
        _ = try await provider.chatWithTools(messages: [.text(.user, "x")], tools: [])
    }
}

// MARK: - Anthropic request body

@Test("Anthropic tool-use body carries model, max_tokens, system, tools schema, and tool_result/tool_use encoding")
func anthropicToolBody() async throws {
    let transport = MockHTTPTransport(
        responseData: #"{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}"#.data(using: .utf8)!
    )
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore,
                                  anthropicModel: "claude-opus-4-5", transport: transport)

    _ = try await provider.chatWithTools(
        messages: conversationWithPriorToolResult(),
        tools: [sampleTool],
        systemPrompt: "You are SimmerSmith.",
        maxTokens: 1800
    )

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "claude-opus-4-5")
    #expect((body["max_tokens"] as? Int) == 1800)
    #expect(body["system"] as? String == "You are SimmerSmith.")

    // tools: [{name, description, input_schema}]
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "recipes_list")
    #expect(tools[0]["description"] as? String == "List the household's recipes.")
    let schema = try #require(tools[0]["input_schema"] as? [String: Any])
    #expect(schema["type"] as? String == "object")
    #expect(tools[0]["type"] == nil)  // Anthropic has no "type":"function" wrapper

    // messages: user, assistant(content blocks incl tool_use), user(tool_result)
    let messages = try #require(body["messages"] as? [[String: Any]])

    // The assistant turn's tool_use block
    let assistant = try #require(messages.first { msg in
        guard let blocks = msg["content"] as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_use" }
    })
    let aBlocks = try #require(assistant["content"] as? [[String: Any]])
    let toolUse = try #require(aBlocks.first { $0["type"] as? String == "tool_use" })
    #expect(toolUse["id"] as? String == "call_1")
    #expect(toolUse["name"] as? String == "recipes_list")
    let input = try #require(toolUse["input"] as? [String: Any])
    #expect(input["query"] as? String == "all")

    // The tool_result rides in a user-role message
    let resultMsg = try #require(messages.first { msg in
        guard let blocks = msg["content"] as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_result" }
    })
    #expect(resultMsg["role"] as? String == "user")
    let rBlocks = try #require(resultMsg["content"] as? [[String: Any]])
    let toolResult = try #require(rBlocks.first { $0["type"] as? String == "tool_result" })
    #expect(toolResult["tool_use_id"] as? String == "call_1")
    let inner = try #require(toolResult["content"] as? [[String: Any]])
    #expect(inner[0]["type"] as? String == "text")
    #expect(inner[0]["text"] as? String == #"{"recipes":["Tacos"]}"#)
}

@Test("Anthropic tool_use response parses into ToolUseTurn (not finished)")
func anthropicParseToolUse() async throws {
    let respJSON = """
    {"content":[
      {"type":"text","text":"Let me check."},
      {"type":"tool_use","id":"toolu_7","name":"weeks_get_current","input":{"x":1}}
    ],"stop_reason":"tool_use"}
    """
    let transport = MockHTTPTransport(responseData: respJSON.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)

    let turn = try await provider.chatWithTools(messages: [.text(.user, "plan")], tools: [sampleTool])
    #expect(turn.finished == false)
    #expect(turn.text == "Let me check.")
    #expect(turn.toolCalls.count == 1)
    #expect(turn.toolCalls[0].id == "toolu_7")
    #expect(turn.toolCalls[0].name == "weeks_get_current")
    // input re-encoded to a JSON string
    let parsed = try JSONSerialization.jsonObject(with: turn.toolCalls[0].argsJSON.data(using: .utf8)!) as? [String: Any]
    #expect(parsed?["x"] as? Int == 1)
}

@Test("Anthropic final-text response parses into ToolUseTurn (finished)")
func anthropicParseFinalText() async throws {
    let respJSON = #"{"content":[{"type":"text","text":"Here are your recipes."}],"stop_reason":"end_turn"}"#
    let transport = MockHTTPTransport(responseData: respJSON.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)

    let turn = try await provider.chatWithTools(messages: [.text(.user, "hi")], tools: [sampleTool])
    #expect(turn.finished == true)
    #expect(turn.toolCalls.isEmpty)
    #expect(turn.text == "Here are your recipes.")
}

@Test("Anthropic tool-use with no key throws noKeyConfigured")
func anthropicToolNoKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let provider = BYOKeyProvider(model: .anthropic, keyStore: MockKeyStore(), transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.anthropic)) {
        _ = try await provider.chatWithTools(messages: [.text(.user, "x")], tools: [])
    }
}
