import Foundation

/// SP-C AI-5 — the on-device assistant tool-calling loop.
///
/// `AssistantEngine.run(...)` is the device-side replacement for the Fly assistant
/// SSE endpoint. It ports `app/services/assistant_ai.py`'s `_run_provider_tool_loop`
/// (the OpenAI/Anthropic tool-use loop, capped at `MAX_TOOL_ITERATIONS == 6`) to a
/// `BYOKeyProvider.chatWithTools` (AI-5 T1) call per iteration, and emits the exact
/// stream events the existing iOS assistant UI already handles
/// (`applyAssistantStreamEvent`): `assistant.message.created`, `assistant.tool_call`
/// (running) → `assistant.tool_result` (+ `week.updated` when a tool changed a week),
/// then a single `assistant.delta` with the final text and `assistant.completed`.
///
/// ## The envelope type
/// The UI consumes `SimmerSmithKit.AssistantStreamEnvelope` — `{event: String,
/// data: Data}`. That type lives in the app's package, which `AIProviderKit` cannot
/// import (AIProviderKit is a leaf module so it stays headlessly unit-testable). So
/// the engine emits `AssistantStreamEvent` — a STRUCTURAL MIRROR of the UI envelope
/// (same `event` + `data` fields, same snake_case JSON payloads the server emits).
/// The app's `AppState+Assistant` rewire (T5) maps it 1:1 to `AssistantStreamEnvelope`
/// and forwards it into the unchanged `applyAssistantStreamEvent`. This mirrors the
/// AI-1 seam (the engine produces provider-neutral output; the app bridges it).
///
/// ## Payload encoding
/// The UI decodes each event's `data` with `convertFromSnakeCase`, so the engine
/// builds raw snake_case JSON dictionaries (`call_id`, `tool_call_id`, `message_id`,
/// `started_at`, …) byte-for-byte like `assistant_ai.py`'s `_emit(...)` payloads —
/// NOT the iOS Codable types (which are in the other package).

// MARK: - Stream event (mirror of SimmerSmithKit.AssistantStreamEnvelope)

/// One assistant stream event: an event name + a JSON payload. Structurally identical
/// to `SimmerSmithKit.AssistantStreamEnvelope` so the app can map it 1:1 without the
/// engine importing the app package.
public struct AssistantStreamEvent: Sendable, Equatable {
    public let event: String
    public let data: Data

    public init(event: String, data: Data) {
        self.event = event
        self.data = data
    }
}

// MARK: - Tool runner contract

/// The outcome of running one assistant tool. Mirrors the server's
/// `AssistantToolResult` (`ok` / `detail` / `result` / `week`): `resultJSON` is fed
/// back into the next provider call as the tool result; `ok`/`detail` annotate the
/// emitted `assistant.tool_result` card; `weekJSON`, when present, is a changed-week
/// payload emitted as a `week.updated` event (encoded by the app, which owns
/// `WeekSnapshot`). `dataJSON` carries an optional structured `data` blob (e.g. a
/// proposed-change card) surfaced verbatim on the tool_result.
public struct ToolRunResult: Sendable, Equatable {
    public var resultJSON: String
    public var ok: Bool
    public var detail: String
    /// A changed-week payload `{"week": …}` (already snake_case JSON), or nil. When
    /// present the engine emits it as a `week.updated` event after the tool_result.
    public var weekUpdatedJSON: String?
    /// An optional structured `data` blob to surface on the tool_result card, or nil.
    public var dataJSON: String?

    public init(
        resultJSON: String,
        ok: Bool = true,
        detail: String = "",
        weekUpdatedJSON: String? = nil,
        dataJSON: String? = nil
    ) {
        self.resultJSON = resultJSON
        self.ok = ok
        self.detail = detail
        self.weekUpdatedJSON = weekUpdatedJSON
        self.dataJSON = dataJSON
    }
}

/// Runs one tool call and returns its result. The app's `ToolRegistry` (T3) supplies
/// this — it dispatches by `call.name`, decodes `call.argsJSON`, executes against the
/// CloudKit repos `@MainActor`, and projects the result back to a `ToolRunResult`.
public typealias AssistantToolRunner = @Sendable (_ call: ToolCall) async -> ToolRunResult

// MARK: - Provider contract

/// The single provider capability the loop needs: a non-streaming tool-use turn. The
/// real implementation is `BYOKeyProvider.chatWithTools` (AI-5 T1); tests inject a
/// scripted double so the loop can be verified without a network call.
public protocol AssistantToolChat: Sendable {
    func chatWithTools(
        messages: [AIChatMessage],
        tools: [ToolSpec],
        systemPrompt: String?
    ) async throws -> ToolUseTurn
}

extension BYOKeyProvider: AssistantToolChat {
    public func chatWithTools(
        messages: [AIChatMessage],
        tools: [ToolSpec],
        systemPrompt: String?
    ) async throws -> ToolUseTurn {
        try await chatWithTools(
            messages: messages,
            tools: tools,
            systemPrompt: systemPrompt,
            temperature: 0.3,
            maxTokens: 1800
        )
    }
}

// MARK: - AssistantEngine

public enum AssistantEngine {
    /// Hard cap on tool-call iterations. Ports `MAX_TOOL_ITERATIONS` from
    /// `app/services/assistant_tools.py` — each iteration is one BYO-key provider call,
    /// so the cap bounds both runaway loops and cost.
    public static let maxToolIterations = 6

    /// The default text surfaced when the loop hits the iteration cap before the model
    /// produced a terminal turn. Ports `assistant_ai.py`'s same-shaped fallback.
    static let iterationLimitText =
        "I hit a tool-call limit before I could finish. Can you try again?"

    /// Run the assistant tool-calling loop and emit the UI's stream events.
    ///
    /// Loop (port of `_run_provider_tool_loop`): build messages (history + the new user
    /// turn) → `chatWithTools` → if the turn requested tools, emit a running
    /// `assistant.tool_call` per call, run the runner, emit `assistant.tool_result`
    /// (+ `week.updated` if the result carried a changed week), append the assistant
    /// turn + the tool results to the running messages, and loop; if the turn finished
    /// (no tools / terminal), emit the final text as one `assistant.delta` and an
    /// `assistant.completed`, then stop. Capped at `maxToolIterations`; on the cap a
    /// graceful `assistant.completed` with `iterationLimitText` is emitted.
    ///
    /// Cancellation: the stream honors Swift `Task` cancellation. When the consuming
    /// task is cancelled (e.g. the assistant sheet is dismissed) the loop stops and the
    /// stream finishes WITHOUT emitting anything further — no `completed`, no `error`.
    ///
    /// Errors: a thrown provider/runner error is mapped to a single `assistant.error`
    /// event and the stream finishes.
    ///
    /// - Parameters:
    ///   - systemPrompt: the assistant system prompt (see `AssistantSystemPrompt`).
    ///   - history: prior turns in the thread (already projected to `AIChatMessage`).
    ///   - userText: the new user message.
    ///   - tools: the curated tool specs the model may call (T3).
    ///   - messageId: the id used on every emitted assistant event so the UI attaches
    ///     deltas/tool-calls/the completed message to one row. Defaults to a fresh UUID.
    ///   - threadId: the thread the assistant message belongs to.
    ///   - provider: the tool-use provider (`BYOKeyProvider`, or a test double).
    ///   - runner: executes a tool call against the repos.
    public static func run(
        systemPrompt: String,
        history: [AIChatMessage],
        userText: String,
        tools: [ToolSpec],
        messageId: String = UUID().uuidString,
        threadId: String,
        provider: any AssistantToolChat,
        runner: @escaping AssistantToolRunner
    ) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await drive(
                        systemPrompt: systemPrompt,
                        history: history,
                        userText: userText,
                        tools: tools,
                        messageId: messageId,
                        threadId: threadId,
                        provider: provider,
                        runner: runner,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch is CancellationError {
                    // User cancelled (sheet dismissed). Stop the loop and finish the
                    // stream WITHOUT a further event — the app marks the in-flight row
                    // cancelled locally (it owns the socket close).
                    continuation.finish()
                } catch {
                    emitError(error, messageId: messageId, into: continuation)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Loop body

    private static func drive(
        systemPrompt: String,
        history: [AIChatMessage],
        userText: String,
        tools: [ToolSpec],
        messageId: String,
        threadId: String,
        provider: any AssistantToolChat,
        runner: @escaping AssistantToolRunner,
        emit: (AssistantStreamEvent) -> Void
    ) async throws {
        // Seed the assistant row so tool_call / delta events have an anchor to attach
        // to (mirrors the server's `assistant.message.created`).
        emit(messageCreatedEvent(messageId: messageId, threadId: threadId))

        // The running message history fed to the provider each iteration. Starts with
        // the prior turns + the new user message; grows by the assistant tool-call turn
        // and the tool results as the loop proceeds (port of the adapter's `messages`).
        var messages = history
        messages.append(.text(.user, userText))

        var accumulatedText = ""

        for _ in 0..<maxToolIterations {
            try Task.checkCancellation()

            let turn = try await provider.chatWithTools(
                messages: messages, tools: tools, systemPrompt: systemPrompt
            )
            if let text = turn.text, !text.isEmpty {
                accumulatedText += (accumulatedText.isEmpty ? "" : "\n") + text
            }

            // No tools requested → terminal. Surface the accumulated text and stop.
            if turn.toolCalls.isEmpty {
                finish(
                    text: accumulatedText, messageId: messageId, threadId: threadId,
                    emit: emit
                )
                return
            }

            // Append the assistant tool-call turn to the running history so the next
            // provider call sees what it asked for (port of `record_assistant_turn`).
            // Carry the captured reasoning so the open-models encoder can replay it next
            // iteration — load-bearing for GLM/Kimi/MiniMax (nil for OpenAI/Anthropic).
            messages.append(
                AIChatMessage(role: .assistant, text: turn.text, toolCalls: turn.toolCalls, reasoning: turn.reasoning)
            )

            // Run each requested tool, emitting running → result (+ week.updated).
            var results: [ToolResult] = []
            for call in turn.toolCalls {
                try Task.checkCancellation()

                let startedAt = ISO8601DateFormatter().string(from: Date())
                emit(toolCallEvent(call: call, startedAt: startedAt))

                let outcome = await runner(call)

                // I1 (review): the runner is non-throwing, so a tool cancelled mid-run
                // (e.g. a long weeks_apply_ai_draft when the user dismisses the sheet)
                // surfaces as an `ok:false` ToolRunResult. Emitting it would paint a
                // spurious "failed" tool_result card on what is really a clean cancel.
                // Check cancellation BEFORE emitting and bail out — `run`'s outer
                // CancellationError catch then finishes the stream with no further event.
                try Task.checkCancellation()

                let completedAt = ISO8601DateFormatter().string(from: Date())
                emit(toolResultEvent(
                    call: call, outcome: outcome,
                    startedAt: startedAt, completedAt: completedAt
                ))
                if let weekJSON = outcome.weekUpdatedJSON {
                    emit(rawEvent("week.updated", json: weekJSON))
                }

                results.append(ToolResult(id: call.id, resultJSON: outcome.resultJSON))
            }

            // Thread the tool results back in for the next iteration (port of
            // `record_tool_results`).
            messages.append(AIChatMessage(role: .tool, toolResults: results))

            // Anthropic/OpenAI signalled a terminal turn alongside its tool calls
            // (stop_reason end_turn / finish_reason stop) — surface what we have.
            if turn.finished {
                finish(
                    text: accumulatedText, messageId: messageId, threadId: threadId,
                    emit: emit
                )
                return
            }
        }

        // Cap reached without a terminal turn — graceful completed (port of the
        // `for…else` warning + fallback text).
        let text = accumulatedText.isEmpty ? iterationLimitText : accumulatedText
        finish(text: text, messageId: messageId, threadId: threadId, emit: emit)
    }

    /// Emit the final text as a single `assistant.delta` then `assistant.completed`.
    /// v1 is non-streaming: the whole reply rides in one delta (the UI already supports
    /// incremental deltas, so token streaming is a drop-in refinement later).
    private static func finish(
        text: String, messageId: String, threadId: String,
        emit: (AssistantStreamEvent) -> Void
    ) {
        let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = finalText.isEmpty ? "Done." : finalText
        emit(deltaEvent(messageId: messageId, delta: body))
        emit(completedEvent(messageId: messageId, threadId: threadId, content: body))
    }

    // MARK: - Event builders (snake_case JSON payloads — match assistant_ai.py)

    private static func messageCreatedEvent(messageId: String, threadId: String) -> AssistantStreamEvent {
        let now = ISO8601DateFormatter().string(from: Date())
        return jsonEvent("assistant.message.created", [
            "message_id": messageId,
            "thread_id": threadId,
            "role": "assistant",
            "status": "streaming",
            "content_markdown": "",
            "tool_calls": [],
            "created_at": now,
            "error": "",
        ])
    }

    private static func toolCallEvent(call: ToolCall, startedAt: String) -> AssistantStreamEvent {
        jsonEvent("assistant.tool_call", [
            "call_id": call.id,
            "name": call.name,
            "arguments": jsonObject(call.argsJSON),
            "status": "running",
            "started_at": startedAt,
        ])
    }

    private static func toolResultEvent(
        call: ToolCall, outcome: ToolRunResult, startedAt: String, completedAt: String
    ) -> AssistantStreamEvent {
        var payload: [String: Any] = [
            "call_id": call.id,
            "name": call.name,
            "arguments": jsonObject(call.argsJSON),
            "ok": outcome.ok,
            "detail": outcome.detail,
            "status": outcome.ok ? "completed" : "failed",
            "started_at": startedAt,
            "completed_at": completedAt,
        ]
        if let dataJSON = outcome.dataJSON, !dataJSON.isEmpty {
            payload["data"] = jsonObject(dataJSON)
        }
        return jsonEvent("assistant.tool_result", payload)
    }

    private static func deltaEvent(messageId: String, delta: String) -> AssistantStreamEvent {
        jsonEvent("assistant.delta", ["message_id": messageId, "delta": delta])
    }

    private static func completedEvent(
        messageId: String, threadId: String, content: String
    ) -> AssistantStreamEvent {
        let now = ISO8601DateFormatter().string(from: Date())
        return jsonEvent("assistant.completed", [
            "message_id": messageId,
            "thread_id": threadId,
            "role": "assistant",
            "status": "completed",
            "content_markdown": content,
            "tool_calls": [],
            "created_at": now,
            "completed_at": now,
            "error": "",
        ])
    }

    private static func emitError(
        _ error: Error, messageId: String,
        into continuation: AsyncThrowingStream<AssistantStreamEvent, Error>.Continuation
    ) {
        let detail = (error as? AIError).map(describe) ?? error.localizedDescription
        continuation.yield(jsonEvent("assistant.error", [
            "message_id": messageId,
            "detail": detail,
        ]))
    }

    /// A clean, user-facing message for the provider/loop errors the engine can throw.
    /// Mirrors the server's "temporarily unavailable" framing — never leaks a raw key.
    static func describe(_ error: AIError) -> String {
        switch error {
        case .noKeyConfigured:
            return "No AI key is configured. Add your provider key in Settings to use the assistant."
        case .httpError, .malformedResponse:
            return "The assistant AI provider is temporarily unavailable. Please try again."
        case .notWiredYet, .webSearchUnsupported:
            return "The assistant isn't available for this provider yet."
        case .noProviderAvailable:
            return "No AI provider is available for the assistant."
        case .imageGenFailed(_, _, let detail):
            return detail
        }
    }

    // MARK: - JSON helpers

    private static func jsonEvent(_ event: String, _ payload: [String: Any]) -> AssistantStreamEvent {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return AssistantStreamEvent(event: event, data: data)
    }

    /// Wrap a pre-encoded JSON STRING (e.g. the app-built `{"week": …}`) as an event
    /// without re-serializing — used for `week.updated`, whose payload the app encodes
    /// from `WeekSnapshot` with the SimmerSmith coder.
    private static func rawEvent(_ event: String, json: String) -> AssistantStreamEvent {
        AssistantStreamEvent(event: event, data: Data(json.utf8))
    }

    /// Decode a JSON-object string to `[String: Any]` for re-embedding (tool arguments,
    /// tool `data`). Empty object on failure.
    private static func jsonObject(_ jsonString: String) -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}
