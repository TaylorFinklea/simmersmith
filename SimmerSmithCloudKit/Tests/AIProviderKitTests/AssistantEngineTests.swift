import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-5 (T2) — headless tests for the assistant tool-calling loop.
//
// Drives `AssistantEngine.run` over a SCRIPTED provider (a `MockToolChat` whose
// `chatWithTools` returns a queued sequence of `ToolUseTurn`s) + a MOCK runner. No
// network, no repos. Asserts:
//   • the envelope SEQUENCE: message.created → tool_call → tool_result (+ week.updated)
//     → delta → completed
//   • the max-iteration cap (6) → a graceful completed
//   • cancellation: the loop stops and the stream finishes with no further event
//   • a thrown provider error → a single assistant.error
//   • the system prompt port (AssistantSystemPrompt)

// MARK: - Doubles

/// A scripted provider: each `chatWithTools` call dequeues the next turn. Records the
/// `messages` it was handed so the test can assert the loop threads tool results back.
private final class MockToolChat: AssistantToolChat, @unchecked Sendable {
    private var turns: [ToolUseTurn]
    private(set) var callCount = 0
    private(set) var lastMessages: [AIChatMessage] = []
    private(set) var lastSystemPrompt: String?
    /// Optional error thrown on the Nth (0-based) call.
    var throwOnCall: (index: Int, error: Error)?

    init(turns: [ToolUseTurn]) { self.turns = turns }

    func chatWithTools(
        messages: [AIChatMessage], tools: [ToolSpec], systemPrompt: String?
    ) async throws -> ToolUseTurn {
        lastMessages = messages
        lastSystemPrompt = systemPrompt
        defer { callCount += 1 }
        if let t = throwOnCall, t.index == callCount { throw t.error }
        if turns.isEmpty {
            return ToolUseTurn(text: "fallback", toolCalls: [], finished: true)
        }
        return turns.removeFirst()
    }
}

private func toolCall(_ name: String, id: String = "call_1", args: String = "{}") -> ToolCall {
    ToolCall(id: id, name: name, argsJSON: args)
}

/// Collect a stream's events; rethrows a terminal error.
private func collect(
    _ stream: AsyncThrowingStream<AssistantStreamEvent, Error>
) async throws -> [AssistantStreamEvent] {
    var out: [AssistantStreamEvent] = []
    for try await event in stream { out.append(event) }
    return out
}

private func names(_ events: [AssistantStreamEvent]) -> [String] { events.map(\.event) }

private func payload(_ event: AssistantStreamEvent) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: event.data) as? [String: Any]) ?? [:]
}

// MARK: - The happy path: tool call then final text

@Test("Loop emits message.created → tool_call → tool_result → delta → completed")
func toolThenFinalSequence() async throws {
    let provider = MockToolChat(turns: [
        // Iteration 1: ask for a tool.
        ToolUseTurn(text: nil, toolCalls: [toolCall("recipes_list")], finished: false),
        // Iteration 2: final text, no tools.
        ToolUseTurn(text: "You have 3 recipes.", toolCalls: [], finished: true),
    ])
    let runner: AssistantToolRunner = { _ in
        ToolRunResult(resultJSON: #"{"recipes":["Tacos","Soup","Salad"]}"#)
    }

    let events = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "what recipes do I have?",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    #expect(names(events) == [
        "assistant.message.created",
        "assistant.tool_call",
        "assistant.tool_result",
        "assistant.delta",
        "assistant.completed",
    ])

    // tool_call is running; tool_result is completed/ok.
    #expect(payload(events[1])["status"] as? String == "running")
    #expect(payload(events[1])["name"] as? String == "recipes_list")
    #expect(payload(events[2])["status"] as? String == "completed")
    #expect(payload(events[2])["ok"] as? Bool == true)

    // The final delta + completed carry the model's text.
    #expect(payload(events[3])["delta"] as? String == "You have 3 recipes.")
    #expect(payload(events[4])["content_markdown"] as? String == "You have 3 recipes.")
    #expect(payload(events[4])["status"] as? String == "completed")

    // Every assistant event shares the one message_id (so the UI attaches to one row).
    #expect(payload(events[0])["message_id"] as? String == "m1")
    #expect(payload(events[3])["message_id"] as? String == "m1")
    #expect(payload(events[4])["message_id"] as? String == "m1")

    // Two provider calls: the tool turn + the final turn.
    #expect(provider.callCount == 2)
}

// MARK: - T6: reasoning is threaded into the assistant history for replay

@Test("Reasoning captured on a tool-call turn is threaded into the next iteration's history")
func reasoningThreadedIntoHistory() async throws {
    let provider = MockToolChat(turns: [
        // Iteration 1: a tool call WITH a captured reasoning trace.
        ToolUseTurn(text: nil, toolCalls: [toolCall("recipes_list")], finished: false,
                    reasoning: ReasoningTrace(style: .reasoningContent, text: "thinking...")),
        // Iteration 2: terminal.
        ToolUseTurn(text: "done", toolCalls: [], finished: true),
    ])
    let runner: AssistantToolRunner = { _ in ToolRunResult(resultJSON: "{}") }
    _ = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "go",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))
    // The 2nd provider call's history must carry the assistant tool-call turn's reasoning.
    let assistantTurn = provider.lastMessages.first { $0.role == .assistant && !$0.toolCalls.isEmpty }
    #expect(assistantTurn?.reasoning?.text == "thinking...")
    #expect(assistantTurn?.reasoning?.style == .reasoningContent)
}

// MARK: - week.updated rides after a tool that changed a week

@Test("A tool result carrying a changed week emits week.updated after tool_result")
func weekUpdatedEmitted() async throws {
    let provider = MockToolChat(turns: [
        ToolUseTurn(text: nil, toolCalls: [toolCall("weeks_update_meals")], finished: false),
        ToolUseTurn(text: "Added tacos to Tuesday.", toolCalls: [], finished: true),
    ])
    let runner: AssistantToolRunner = { _ in
        ToolRunResult(
            resultJSON: #"{"ok":true}"#,
            detail: "Added 1 meal",
            weekUpdatedJSON: #"{"week":{"week_id":"w1"}}"#
        )
    }

    let events = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "add tacos to tuesday",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    #expect(names(events) == [
        "assistant.message.created",
        "assistant.tool_call",
        "assistant.tool_result",
        "week.updated",
        "assistant.delta",
        "assistant.completed",
    ])
    let week = payload(events[3])["week"] as? [String: Any]
    #expect(week?["week_id"] as? String == "w1")
}

// MARK: - First turn finishes with no tools

@Test("A first turn with no tools goes straight to delta + completed")
func noToolsFirstTurn() async throws {
    let provider = MockToolChat(turns: [
        ToolUseTurn(text: "Sear it 3 minutes a side.", toolCalls: [], finished: true),
    ])
    let runner: AssistantToolRunner = { _ in ToolRunResult(resultJSON: "{}") }

    let events = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "how do I cook a steak?",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    #expect(names(events) == [
        "assistant.message.created", "assistant.delta", "assistant.completed",
    ])
    #expect(provider.callCount == 1)
}

// MARK: - Tool results thread back into the next provider call

@Test("Tool results are appended to the running messages for the next iteration")
func threadsToolResultsBack() async throws {
    let provider = MockToolChat(turns: [
        ToolUseTurn(text: nil, toolCalls: [toolCall("recipes_list", id: "c1")], finished: false),
        ToolUseTurn(text: "Done.", toolCalls: [], finished: true),
    ])
    let runner: AssistantToolRunner = { _ in ToolRunResult(resultJSON: #"{"n":2}"#) }

    _ = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [.text(.user, "earlier")], userText: "now",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    // On the SECOND provider call, the running history must include: prior user turn,
    // the new user turn, the assistant tool-call turn, and the tool-result turn.
    let m = provider.lastMessages
    #expect(m.contains { $0.role == .assistant && !$0.toolCalls.isEmpty })
    let toolTurn = m.first { $0.role == .tool }
    #expect(toolTurn?.toolResults.first?.id == "c1")
    #expect(toolTurn?.toolResults.first?.resultJSON == #"{"n":2}"#)
}

// MARK: - Max-iteration cap

@Test("The loop caps at 6 iterations and still emits a graceful completed")
func maxIterationCap() async throws {
    // Every turn asks for another tool and never finishes — the cap must stop it.
    let provider = MockToolChat(turns: Array(repeating:
        ToolUseTurn(text: nil, toolCalls: [toolCall("recipes_list")], finished: false),
        count: 20
    ))
    let runner: AssistantToolRunner = { _ in ToolRunResult(resultJSON: "{}") }

    let events = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "loop forever",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    // Exactly maxToolIterations provider calls, never more.
    #expect(provider.callCount == AssistantEngine.maxToolIterations)
    // Still ends gracefully with a completed (not an error / not a hang).
    #expect(names(events).last == "assistant.completed")
    #expect(payload(events.last!)["status"] as? String == "completed")
    // 6 tool_call + 6 tool_result events.
    #expect(names(events).filter { $0 == "assistant.tool_call" }.count == 6)
    #expect(names(events).filter { $0 == "assistant.tool_result" }.count == 6)
}

// MARK: - Cancellation

@Test("Cancelling the consuming task stops the loop with no further event")
func cancellationStopsLoop() async throws {
    // The runner blocks long enough for the test to cancel mid-tool.
    let started = AsyncStream<Void>.makeStream()
    let provider = MockToolChat(turns: Array(repeating:
        ToolUseTurn(text: nil, toolCalls: [toolCall("slow_tool")], finished: false),
        count: 20
    ))
    let runner: AssistantToolRunner = { _ in
        started.continuation.yield()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return ToolRunResult(resultJSON: "{}")
    }

    let stream = AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "go",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    )

    let consumer = Task { () -> [AssistantStreamEvent] in
        var out: [AssistantStreamEvent] = []
        for try await event in stream { out.append(event) }
        return out
    }

    // Wait until the first tool is running, then cancel.
    var it = started.stream.makeAsyncIterator()
    _ = await it.next()
    consumer.cancel()

    let events = try await consumer.value
    // The stream finishes (no hang). Whatever arrived, it never reached completed —
    // cancellation emits NOTHING further (no completed, no error).
    #expect(!names(events).contains("assistant.completed"))
    #expect(!names(events).contains("assistant.error"))
}

// MARK: - I1: cancelling mid-tool emits no spurious failed tool_result

@Test("A tool cancelled mid-run does NOT emit a failed tool_result card")
func cancelMidToolNoFailureCard() async throws {
    // The runner is non-throwing: when the task is cancelled mid-tool it returns an
    // ok:false ToolRunResult (the ToolRegistry maps CancellationError to a failure).
    // The engine must check cancellation BEFORE emitting and bail — no "failed" card.
    let started = AsyncStream<Void>.makeStream()
    let provider = MockToolChat(turns: Array(repeating:
        ToolUseTurn(text: nil, toolCalls: [toolCall("weeks_apply_ai_draft")], finished: false),
        count: 20
    ))
    let runner: AssistantToolRunner = { _ in
        started.continuation.yield()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        // Mirror ToolRegistry's behavior: a cancelled tool returns an ok:false result.
        return ToolRunResult(resultJSON: #"{"ok":false}"#, ok: false, detail: "cancelled")
    }

    let stream = AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "plan my whole week",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    )

    let consumer = Task { () -> [AssistantStreamEvent] in
        var out: [AssistantStreamEvent] = []
        for try await event in stream { out.append(event) }
        return out
    }

    var it = started.stream.makeAsyncIterator()
    _ = await it.next()
    consumer.cancel()

    let events = try await consumer.value
    // The tool_call (running) may have been emitted, but NO tool_result — and
    // certainly none with status "failed" — because the engine checks cancellation
    // after the runner returns and bails before emitting the result.
    let failedResults = events.filter {
        $0.event == "assistant.tool_result" && (payload($0)["status"] as? String == "failed")
    }
    #expect(failedResults.isEmpty)
    #expect(!names(events).contains("assistant.tool_result"))
    #expect(!names(events).contains("assistant.completed"))
    #expect(!names(events).contains("assistant.error"))
}

// MARK: - Error mapping

@Test("A thrown provider error is mapped to a single assistant.error")
func providerErrorMapped() async throws {
    let provider = MockToolChat(turns: [])
    provider.throwOnCall = (index: 0, error: AIError.httpError(provider: "openai", statusCode: 429, body: "rate limited"))
    let runner: AssistantToolRunner = { _ in ToolRunResult(resultJSON: "{}") }

    let events = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "go",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    // message.created seeded, then a single error — never a completed.
    #expect(names(events) == ["assistant.message.created", "assistant.error"])
    let detail = payload(events[1])["detail"] as? String
    #expect(detail == "The assistant AI provider is temporarily unavailable. Please try again.")
    // The raw 401-style body must NOT leak into the surfaced detail.
    #expect(detail?.contains("rate limited") == false)
}

@Test("A no-key error maps to the setup prompt, not a crash")
func noKeyErrorMapped() async throws {
    let provider = MockToolChat(turns: [])
    provider.throwOnCall = (index: 0, error: AIError.noKeyConfigured(.openAI))
    let runner: AssistantToolRunner = { _ in ToolRunResult(resultJSON: "{}") }

    let events = try await collect(AssistantEngine.run(
        systemPrompt: "sys", history: [], userText: "go",
        tools: [], messageId: "m1", threadId: "t1",
        provider: provider, runner: runner
    ))

    #expect(names(events).last == "assistant.error")
    #expect((payload(events.last!)["detail"] as? String)?.contains("Settings") == true)
}

// MARK: - System prompt port

@Test("The assistant system prompt ports the key directives from assistant_ai.py")
func systemPromptPort() {
    let prompt = AssistantSystemPrompt.build(threadTitle: "Dinner this week", unitSystem: .us)
    #expect(prompt.contains("SimmerSmith's Planning Assistant"))
    #expect(prompt.contains("CALL THE TOOL rather than describing"))
    #expect(prompt.contains("ok=false"))
    #expect(prompt.contains("Prefer small edits"))
    #expect(prompt.contains("Thread: Dinner this week"))
    // The units directive is injected near the top.
    #expect(prompt.contains("US CUSTOMARY"))
    // I1 (review): the prompt must reference tools that ACTUALLY exist in the curated
    // v1 toolset — not a phantom `generate_week_plan` / `generate_*` tool.
    #expect(prompt.contains("weeks_update_meals"))
    #expect(prompt.contains("weeks_apply_ai_draft"))
    #expect(!prompt.contains("generate_week_plan"))
}

@Test("An empty thread title defaults to Weekly Planning")
func systemPromptDefaultTitle() {
    let prompt = AssistantSystemPrompt.build(threadTitle: "   ")
    #expect(prompt.contains("Thread: Weekly Planning"))
}
