import Foundation
import Testing
@testable import AIProviderKit

// Phase 2a — headless tests for BYOKeyProvider's real OpenAI `streamWithTools` SSE
// override (Part 2) + the `HTTPTransport.lines(for:)` streaming seam (Part 1).
//
// A `MockLinesTransport` scripts `lines(for:)` to yield fixture SSE lines (no real
// network calls); `data(for:)` is also implemented so the non-OpenAI fallback path
// (which still calls `chatWithTools` → `data(for:)`) is exercisable too. Verifies:
//   • content-only stream → ordered .textDelta then a terminal .turn matching what
//     parseOpenAIToolTurn would produce for the same logical response
//   • a tool call streamed incrementally (id/name first, arguments in fragments) →
//     the assembled ToolCall + finished == false + no stray textDelta
//   • two tool calls at index 0/1 assemble independently, in index order
//   • the request body carries "stream": true alongside the same shape as the
//     non-streaming chatWithToolsOpenAI body
//   • no key configured / a transport error both finish the stream by throwing
//   • non-OpenAI models keep using the Phase-1 default (wraps chatWithTools)

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

@Test("Anthropic streamWithTools falls back to the Phase-1 default (wraps chatWithTools, one turn, no deltas)")
func anthropicStreamFallsBackToDefault() async throws {
    let respJSON = #"{"content":[{"type":"text","text":"Here are your recipes."}],"stop_reason":"end_turn"}"#
    let transport = MockLinesTransport(lines: [], dataResponse: respJSON.data(using: .utf8)!)
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)

    let events = try await collectStream(provider.streamWithTools(
        messages: [.text(.user, "hi")], tools: [], systemPrompt: nil
    ))

    #expect(events == [.turn(ToolUseTurn(text: "Here are your recipes.", toolCalls: [], finished: true))])
    // The non-streaming data(for:) path was used, not lines(for:).
    #expect(transport.capturedRequest?.url?.absoluteString.contains("anthropic.com") == true)
}
