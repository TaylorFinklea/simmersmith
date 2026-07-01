import Foundation
import Testing
@testable import AIProviderKit

// Phase 2a — headless tests for BYOKeyProvider's real OpenAI `streamWithTools` SSE
// override (Part 2) + the `HTTPTransport.lines(for:)` streaming seam (Part 1).
// Phase 2b adds the Anthropic `streamWithTools` SSE override alongside it. Phase 2c
// adds the open-models (GLM/Kimi/MiniMax) SSE override + reasoning capture.
//
// A `MockLinesTransport` scripts `lines(for:)` to yield fixture SSE lines (no real
// network calls); `data(for:)` is also implemented so the still-defaulting fallback
// path (which calls `chatWithTools` → `data(for:)`) is exercisable too. Verifies:
//   • content-only stream → ordered .textDelta then a terminal .turn matching what
//     parseOpenAIToolTurn would produce for the same logical response
//   • a tool call streamed incrementally (id/name first, arguments in fragments) →
//     the assembled ToolCall + finished == false + no stray textDelta
//   • two tool calls at index 0/1 assemble independently, in index order
//   • the request body carries "stream": true alongside the same shape as the
//     non-streaming chatWithToolsOpenAI body
//   • no key configured / a transport error both finish the stream by throwing
//   • an Anthropic content-only stream and an incrementally-streamed tool call
//     (named SSE events) match parseAnthropicToolTurn's assembled shape
//   • an open-models (.glm) content-only stream, an incrementally-streamed tool call,
//     and a stream carrying delta.reasoning_content fragments (concatenated into the
//     terminal turn's ReasoningTrace) match parseOpenModelsToolTurn's assembled shape —
//     MiniMax reasoning_details streaming is best-effort/device-gated, not fixture-tested
//     here (only reasoning_content is confident). `.gemini`/`.openRouter` are the only
//     vendors still on the Phase-1 default (untested here, unchanged).

// MARK: - Local doubles

private final class MockKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    func key(for provider: String) -> String? { keys[provider] }
    func setKey(_ key: String?, for provider: String) { keys[provider] = key }
}

/// Captures the last request. `lines(for:)` replays a scripted line sequence (or
/// throws `thrownError`, simulating a transport-level failure); `data(for:)` returns
/// `dataResponse` — used by the non-OpenAI fallback path, which still calls the
/// non-streaming `chatWithTools`.
private final class MockLinesTransport: HTTPTransport, @unchecked Sendable {
    var capturedRequest: URLRequest?
    private let scriptedLines: [String]
    private let dataResponse: Data
    private let thrownError: Error?

    init(lines: [String], dataResponse: Data = Data(), thrownError: Error? = nil) {
        self.scriptedLines = lines
        self.dataResponse = dataResponse
        self.thrownError = thrownError
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        let url = request.url ?? URL(string: "https://example.com")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (dataResponse, resp)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, URLResponse) {
        capturedRequest = request
        if let thrownError { throw thrownError }
        let url = request.url ?? URL(string: "https://example.com")!
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let scripted = scriptedLines
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in scripted { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, resp)
    }
}

private func bodyJSON(from transport: MockLinesTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Build one SSE `data:` line from a `choices[0]` shape — a `delta` object and an
/// optional `finish_reason`. Using JSONSerialization means fragment strings (which may
/// contain raw quotes) get escaped correctly without hand-written JSON.
private func chunkLine(delta: [String: Any], finishReason: String? = nil) -> String {
    var choice: [String: Any] = ["delta": delta]
    if let finishReason { choice["finish_reason"] = finishReason }
    let json: [String: Any] = ["choices": [choice]]
    let data = try! JSONSerialization.data(withJSONObject: json)
    return "data: \(String(data: data, encoding: .utf8)!)"
}

/// Frame a sequence of `data:` line contents as SSE: a blank line dispatches each.
private func sseFrame(_ dataLines: [String]) -> [String] {
    dataLines.flatMap { [$0, ""] }
}

private func collectStream(
    _ stream: AsyncThrowingStream<ToolUseStreamEvent, Error>
) async throws -> [ToolUseStreamEvent] {
    var events: [ToolUseStreamEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

// MARK: - Content-only stream

@Test("Content-only OpenAI SSE stream yields ordered textDeltas then a matching terminal turn")
func openAIStreamContentOnly() async throws {
    let lines = sseFrame([
        chunkLine(delta: ["content": "Hel"]),
        chunkLine(delta: ["content": "lo"]),
        chunkLine(delta: [:], finishReason: "stop"),
        "data: [DONE]",
    ])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .textDelta("Hel"),
        .textDelta("lo"),
        .turn(ToolUseTurn(text: "Hello", toolCalls: [], finished: true)),
    ])
}

@Test("OpenAI stream request body carries stream:true plus the same shape as chatWithToolsOpenAI")
func openAIStreamRequestBody() async throws {
    let lines = sseFrame([chunkLine(delta: [:], finishReason: "stop"), "data: [DONE]"])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, openAIModel: "gpt-4o", transport: transport)
    let tool = ToolSpec(
        name: "recipes_list", description: "List recipes.",
        parametersSchemaJSON: #"{"type":"object","properties":{}}"#
    )

    _ = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [tool], systemPrompt: "sys"
    ))

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "gpt-4o")
    #expect(body["stream"] as? Bool == true)
    #expect((body["temperature"] as? Double) == 0.3)
    #expect(body["tool_choice"] as? String == "auto")
    let tools = try #require(body["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    let fn = try #require(tools[0]["function"] as? [String: Any])
    #expect(fn["name"] as? String == "recipes_list")
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[0]["content"] as? String == "sys")
}

// MARK: - Incremental tool call

@Test("A tool call streamed incrementally assembles id/name + concatenated argument fragments")
func openAIStreamToolCallIncremental() async throws {
    let fullArgs = #"{"location":"x"}"#
    let splitIndex = fullArgs.index(fullArgs.startIndex, offsetBy: 4)
    let frag1 = String(fullArgs[..<splitIndex])  // `{"lo`
    let frag2 = String(fullArgs[splitIndex...])  // `cation":"x"}`

    let lines = sseFrame([
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "id": "call_abc", "function": ["name": "get_weather", "arguments": ""]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "function": ["arguments": frag1]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "function": ["arguments": frag2]],
        ]]),
        chunkLine(delta: [:], finishReason: "tool_calls"),
        "data: [DONE]",
    ])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "weather?")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .turn(ToolUseTurn(
            text: nil,
            toolCalls: [ToolCall(id: "call_abc", name: "get_weather", argsJSON: fullArgs)],
            finished: false
        )),
    ])
}

@Test("Two tool calls at different indices assemble independently, in index order")
func openAIStreamTwoToolCalls() async throws {
    let lines = sseFrame([
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "id": "call_0", "function": ["name": "tool_a", "arguments": "{\"a\":"]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 1, "id": "call_1", "function": ["name": "tool_b", "arguments": "{\"b\":"]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "function": ["arguments": "1}"]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 1, "function": ["arguments": "2}"]],
        ]]),
        chunkLine(delta: [:], finishReason: "tool_calls"),
        "data: [DONE]",
    ])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "go")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .turn(ToolUseTurn(
            text: nil,
            toolCalls: [
                ToolCall(id: "call_0", name: "tool_a", argsJSON: #"{"a":1}"#),
                ToolCall(id: "call_1", name: "tool_b", argsJSON: #"{"b":2}"#),
            ],
            finished: false
        )),
    ])
}

// MARK: - Anthropic streaming (Phase 2b)

/// Frame one named Anthropic SSE event: `event: <name>` then `data: <json>` then a
/// blank line to dispatch. Using JSONSerialization means fragment strings (which may
/// contain raw quotes) get escaped correctly without hand-written JSON.
private func anthropicEvent(_ name: String, _ data: [String: Any]) -> [String] {
    let json = try! JSONSerialization.data(withJSONObject: data)
    return ["event: \(name)", "data: \(String(data: json, encoding: .utf8)!)", ""]
}

@Test("Content-only Anthropic SSE stream yields ordered textDeltas then a matching terminal turn")
func anthropicStreamContentOnly() async throws {
    var lines: [String] = []
    lines += anthropicEvent("message_start", ["type": "message_start"])
    lines += anthropicEvent("content_block_start", [
        "type": "content_block_start", "index": 0,
        "content_block": ["type": "text", "text": ""],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": "Hel"],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": "lo"],
    ])
    lines += anthropicEvent("content_block_stop", ["type": "content_block_stop", "index": 0])
    lines += anthropicEvent("message_delta", [
        "type": "message_delta", "delta": ["stop_reason": "end_turn"],
    ])
    lines += anthropicEvent("message_stop", ["type": "message_stop"])

    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .textDelta("Hel"),
        .textDelta("lo"),
        .turn(ToolUseTurn(text: "Hello", toolCalls: [], finished: true)),
    ])
}

@Test("Two Anthropic text blocks stream a single \"\\n\" separator between them, matching parseAnthropicToolTurn's join")
func anthropicStreamMultipleTextBlocks() async throws {
    // A single Anthropic message can carry >1 text content block. The non-streaming
    // parseAnthropicToolTurn joins them with "\n"; the live stream must emit that same
    // separator ONCE at the block boundary (not per-delta, not omitted) so the streamed
    // content_markdown equals the assembled turn's text.
    var lines: [String] = []
    lines += anthropicEvent("message_start", ["type": "message_start"])
    // Text block 0, streamed across two deltas.
    lines += anthropicEvent("content_block_start", [
        "type": "content_block_start", "index": 0,
        "content_block": ["type": "text", "text": ""],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": "Hel"],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "text_delta", "text": "lo"],
    ])
    lines += anthropicEvent("content_block_stop", ["type": "content_block_stop", "index": 0])
    // Text block 1, also streamed across two deltas.
    lines += anthropicEvent("content_block_start", [
        "type": "content_block_start", "index": 1,
        "content_block": ["type": "text", "text": ""],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 1,
        "delta": ["type": "text_delta", "text": "Wor"],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 1,
        "delta": ["type": "text_delta", "text": "ld"],
    ])
    lines += anthropicEvent("content_block_stop", ["type": "content_block_stop", "index": 1])
    lines += anthropicEvent("message_delta", [
        "type": "message_delta", "delta": ["stop_reason": "end_turn"],
    ])
    lines += anthropicEvent("message_stop", ["type": "message_stop"])

    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
    ))

    // The "\n" fires exactly once (at the 0→1 boundary), never per-delta, and the
    // terminal turn's text matches parseAnthropicToolTurn's "\n"-join.
    #expect(events == [
        .textDelta("Hel"),
        .textDelta("lo"),
        .textDelta("\n"),
        .textDelta("Wor"),
        .textDelta("ld"),
        .turn(ToolUseTurn(text: "Hello\nWorld", toolCalls: [], finished: true)),
    ])
}

@Test("An Anthropic tool call streamed incrementally assembles id/name + concatenated input-json fragments")
func anthropicStreamToolCallIncremental() async throws {
    let fullArgs = #"{"location":"x"}"#
    let splitIndex = fullArgs.index(fullArgs.startIndex, offsetBy: 4)
    let frag1 = String(fullArgs[..<splitIndex])  // `{"lo`
    let frag2 = String(fullArgs[splitIndex...])  // `cation":"x"}`

    var lines: [String] = []
    lines += anthropicEvent("content_block_start", [
        "type": "content_block_start", "index": 0,
        "content_block": ["type": "tool_use", "id": "toolu_01", "name": "get_weather", "input": [String: Any]()],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "input_json_delta", "partial_json": frag1],
    ])
    lines += anthropicEvent("content_block_delta", [
        "type": "content_block_delta", "index": 0,
        "delta": ["type": "input_json_delta", "partial_json": frag2],
    ])
    lines += anthropicEvent("content_block_stop", ["type": "content_block_stop", "index": 0])
    lines += anthropicEvent("message_delta", [
        "type": "message_delta", "delta": ["stop_reason": "tool_use"],
    ])

    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "weather?")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .turn(ToolUseTurn(
            text: nil,
            toolCalls: [ToolCall(id: "toolu_01", name: "get_weather", argsJSON: fullArgs)],
            finished: false
        )),
    ])
}

// MARK: - Errors + fallback

@Test("OpenAI stream with no key throws noKeyConfigured")
func openAIStreamNoKey() async {
    let transport = MockLinesTransport(lines: [])
    let provider = BYOKeyProvider(model: .openAI, keyStore: MockKeyStore(), transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openAI)) {
        _ = try await collectStream(provider.streamWithTools(
            messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
        ))
    }
}

@Test("A transport error finishes the OpenAI stream by throwing the same AIError")
func openAIStreamTransportError() async {
    let expectedError = AIError.httpError(provider: "openai", statusCode: 401, body: "unauthorized")
    let transport = MockLinesTransport(lines: [], thrownError: expectedError)
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    await #expect(throws: expectedError) {
        _ = try await collectStream(provider.streamWithTools(
            messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
        ))
    }
}

// MARK: - Open-models streaming (Phase 2c)
//
// Open-models (GLM/Kimi/MiniMax) are OpenAI-compatible chat/completions SSE, so these
// reuse `chunkLine`/`sseFrame` from the OpenAI section above. `reasoning_content`
// (GLM/Kimi) is fixture-tested (confident); MiniMax `reasoning_details` streaming is
// best-effort + device-gated per the spec — no fixture asserts a guessed shape here.

@Test("Content-only open-models SSE stream yields ordered textDeltas then a matching terminal turn")
func openModelsStreamContentOnly() async throws {
    let lines = sseFrame([
        chunkLine(delta: ["content": "Hel"]),
        chunkLine(delta: ["content": "lo"]),
        chunkLine(delta: [:], finishReason: "stop"),
        "data: [DONE]",
    ])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("zai-test", for: "zai")
    let provider = BYOKeyProvider(model: .openModels(.glm), keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .textDelta("Hel"),
        .textDelta("lo"),
        .turn(ToolUseTurn(text: "Hello", toolCalls: [], finished: true)),
    ])
    // Real streaming as of Phase 2c: lines(for:) was used, not the non-streaming data(for:).
    #expect(transport.capturedRequest?.url?.absoluteString.contains("z.ai") == true)
}

@Test("An open-models tool call streamed incrementally assembles id/name + concatenated argument fragments")
func openModelsStreamToolCallIncremental() async throws {
    let fullArgs = #"{"location":"x"}"#
    let splitIndex = fullArgs.index(fullArgs.startIndex, offsetBy: 4)
    let frag1 = String(fullArgs[..<splitIndex])  // `{"lo`
    let frag2 = String(fullArgs[splitIndex...])  // `cation":"x"}`

    let lines = sseFrame([
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "id": "call_abc", "function": ["name": "get_weather", "arguments": ""]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "function": ["arguments": frag1]],
        ]]),
        chunkLine(delta: ["tool_calls": [
            ["index": 0, "function": ["arguments": frag2]],
        ]]),
        chunkLine(delta: [:], finishReason: "tool_calls"),
        "data: [DONE]",
    ])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("zai-test", for: "zai")
    let provider = BYOKeyProvider(model: .openModels(.glm), keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "weather?")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .turn(ToolUseTurn(
            text: nil,
            toolCalls: [ToolCall(id: "call_abc", name: "get_weather", argsJSON: fullArgs)],
            finished: false
        )),
    ])
}

@Test("A .glm stream carrying delta.reasoning_content fragments concatenates into the terminal turn's reasoning")
func openModelsStreamReasoningContent() async throws {
    let lines = sseFrame([
        chunkLine(delta: ["reasoning_content": "Think"]),
        chunkLine(delta: ["reasoning_content": "ing...", "content": "Hi"]),
        chunkLine(delta: [:], finishReason: "stop"),
        "data: [DONE]",
    ])
    let transport = MockLinesTransport(lines: lines)
    let keyStore = MockKeyStore()
    keyStore.setKey("zai-test", for: "zai")
    let provider = BYOKeyProvider(model: .openModels(.glm), keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
    ))

    #expect(events == [
        .textDelta("Hi"),
        .turn(ToolUseTurn(
            text: "Hi", toolCalls: [], finished: true,
            reasoning: ReasoningTrace(style: .reasoningContent, text: "Thinking...")
        )),
    ])
}
