import Foundation

/// SP-C AI-5 — provider-neutral tool-use types + a non-streaming tool-calling
/// call on `BYOKeyProvider`. The assistant loop (AssistantEngine, app layer) drives
/// this each iteration: it passes the running message history + the tool specs, gets
/// back the model's text and/or its requested tool calls, runs the tools, threads the
/// results back in as new `AIChatMessage`s, and calls again until `finished`.
///
/// Ports the OpenAI/Anthropic adapter shapes from `app/services/assistant_ai.py`
/// (`OpenAIAdapter` / `AnthropicAdapter`) — but NON-streaming: a single
/// `chat/completions` (OpenAI) or `messages` (Anthropic) POST per call, parsed for
/// the final text + the tool calls.

// MARK: - Provider-neutral types

/// One turn in a tool-using conversation. Provider-neutral: the encoders below map
/// it to OpenAI's `{role, content, tool_calls}` / `{role:"tool", …}` shapes or
/// Anthropic's content-block shapes.
public struct AIChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    /// The text of the turn. For an assistant turn that only requested tools this may
    /// be empty/nil; for a `.tool` turn it is unused (results ride in `toolResults`).
    public var text: String?
    /// Tool calls the model requested on an assistant turn. Empty otherwise.
    public var toolCalls: [ToolCall]
    /// Tool results to feed back. Carried on a turn (role is ignored by the encoders —
    /// OpenAI emits one `{role:"tool"}` message per result, Anthropic packs them into a
    /// single user message). Empty otherwise.
    public var toolResults: [ToolResult]
    /// The reasoning captured on an assistant tool-call turn, re-emitted verbatim by the
    /// open-models encoder on the next request (reasoning replay). Nil for every other
    /// turn and for providers without reasoning capture (OpenAI/Anthropic paths).
    public var reasoning: ReasoningTrace?

    public init(
        role: Role,
        text: String? = nil,
        toolCalls: [ToolCall] = [],
        toolResults: [ToolResult] = [],
        reasoning: ReasoningTrace? = nil
    ) {
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.toolResults = toolResults
        self.reasoning = reasoning
    }

    /// A plain text turn (system / user / assistant).
    public static func text(_ role: Role, _ text: String) -> AIChatMessage {
        AIChatMessage(role: role, text: text)
    }
}

/// A tool the model may call: name + human description + a JSON-Schema object
/// describing its parameters. `parametersSchema` is a JSON object (the `{"type":
/// "object", "properties": {…}}` shape), passed through verbatim to the provider.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    /// JSON-Schema for the tool's arguments, as a JSON-encoded string. Decoded and
    /// re-embedded into the request body so the schema can be authored as raw JSON.
    public var parametersSchemaJSON: String

    public init(name: String, description: String, parametersSchemaJSON: String) {
        self.name = name
        self.description = description
        self.parametersSchemaJSON = parametersSchemaJSON
    }

    /// The schema decoded to a Foundation JSON object (`[String: Any]`). Falls back to
    /// an empty object schema if the string isn't valid JSON.
    var parametersObject: [String: Any] {
        guard let data = parametersSchemaJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["type": "object", "properties": [:]] }
        return obj
    }
}

/// A tool call the model emitted: a provider-assigned `id`, the tool `name`, and the
/// arguments as a JSON string (OpenAI's `function.arguments`; Anthropic's `input`
/// re-encoded to JSON for a uniform shape).
public struct ToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var argsJSON: String

    public init(id: String, name: String, argsJSON: String) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
    }
}

/// The outcome of running a tool, to thread back into the next provider call. `id`
/// MUST match the originating `ToolCall.id` (OpenAI `tool_call_id` / Anthropic
/// `tool_use_id`). `resultJSON` is the tool's return value, JSON-encoded.
public struct ToolResult: Sendable, Equatable {
    public var id: String
    public var resultJSON: String

    public init(id: String, resultJSON: String) {
        self.id = id
        self.resultJSON = resultJSON
    }
}

/// One provider turn's outcome: the model's text (if any), the tool calls it wants
/// run, and whether the turn is terminal (`finish_reason=="stop"` /
/// `stop_reason=="end_turn"`). When `toolCalls` is non-empty the loop runs them and
/// calls again; when `finished` is true the loop stops and surfaces `text`.
public struct ToolUseTurn: Sendable, Equatable {
    public var text: String?
    public var toolCalls: [ToolCall]
    public var finished: Bool
    /// Reasoning captured from this turn (open-models tool loop), to carry onto the
    /// assistant history message so the next iteration can replay it. Nil otherwise.
    public var reasoning: ReasoningTrace?

    public init(text: String?, toolCalls: [ToolCall], finished: Bool, reasoning: ReasoningTrace? = nil) {
        self.text = text
        self.toolCalls = toolCalls
        self.finished = finished
        self.reasoning = reasoning
    }
}

// MARK: - chatWithTools

extension BYOKeyProvider {
    /// A non-streaming tool-use call. Sends `messages` + the `tools` to the configured
    /// provider and returns the model's text and/or its requested tool calls plus a
    /// `finished` flag. The assistant loop calls this per iteration.
    ///
    /// Provider routing follows `BYOKeyProvider.model`: `.openAI` →
    /// `chat/completions`; `.anthropic` → `messages`. `.gemini` / `.openRouter` aren't
    /// wired for tool-use (throws `notWiredYet`).
    public func chatWithTools(
        messages: [AIChatMessage],
        tools: [ToolSpec],
        systemPrompt: String? = nil,
        temperature: Double = 0.3,
        maxTokens: Int = 1800
    ) async throws -> ToolUseTurn {
        switch cloudModel {
        case .openAI:
            return try await chatWithToolsOpenAI(
                messages: messages, tools: tools,
                systemPrompt: systemPrompt, temperature: temperature
            )
        case .anthropic:
            return try await chatWithToolsAnthropic(
                messages: messages, tools: tools,
                systemPrompt: systemPrompt, maxTokens: maxTokens
            )
        case .openModels:
            // T5 replaces this placeholder with chatWithToolsOpenModels (reasoning replay).
            throw AIError.notWiredYet(tier)
        case .gemini, .openRouter:
            throw AIError.notWiredYet(tier)
        }
    }

    // MARK: OpenAI tool-use (chat/completions)

    private func chatWithToolsOpenAI(
        messages: [AIChatMessage],
        tools: [ToolSpec],
        systemPrompt: String?,
        temperature: Double
    ) async throws -> ToolUseTurn {
        guard let key = resolvedKey(for: "openai"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.openAI)
        }
        let encoded = Self.encodeOpenAIMessages(messages, systemPrompt: systemPrompt)
        let toolSpecs: [[String: Any]] = tools.map { spec in
            ["type": "function",
             "function": [
                "name": spec.name,
                "description": spec.description,
                "parameters": spec.parametersObject,
             ]]
        }
        var body: [String: Any] = [
            "model": resolvedOpenAIModel,
            "messages": encoded,
            "temperature": temperature,
        ]
        if !toolSpecs.isEmpty {
            body["tools"] = toolSpecs
            body["tool_choice"] = "auto"
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (responseData, response) = try await transportRef.data(for: req)
        try checkHTTPShared(response, data: responseData, provider: "openai")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIError.malformedResponse("openai")
        }
        return try Self.parseOpenAIToolTurn(json)
    }

    /// Build OpenAI's `messages` array from the provider-neutral history. Mirrors
    /// `OpenAIAdapter._init_messages` / `record_assistant_turn` / `record_tool_results`:
    /// - system prompt → leading `{role:"system"}`
    /// - assistant turn with tool calls →
    ///   `{role:"assistant", content, tool_calls:[{id, type:"function", function:{name, arguments}}]}`
    /// - tool results → one `{role:"tool", tool_call_id, content}` per result
    static func encodeOpenAIMessages(
        _ messages: [AIChatMessage], systemPrompt: String?
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            out.append(["role": "system", "content": sys])
        }
        for msg in messages {
            if !msg.toolResults.isEmpty {
                for result in msg.toolResults {
                    out.append([
                        "role": "tool",
                        "tool_call_id": result.id,
                        "content": result.resultJSON,
                    ])
                }
                continue
            }
            if msg.role == .assistant, !msg.toolCalls.isEmpty {
                let calls: [[String: Any]] = msg.toolCalls.map { call in
                    ["id": call.id,
                     "type": "function",
                     "function": ["name": call.name, "arguments": call.argsJSON]]
                }
                var entry: [String: Any] = ["role": "assistant", "tool_calls": calls]
                // OpenAI accepts content == null on a tool-call turn; omit when empty.
                if let text = msg.text, !text.isEmpty { entry["content"] = text }
                else { entry["content"] = NSNull() }
                out.append(entry)
                continue
            }
            out.append([
                "role": msg.role.rawValue,
                "content": msg.text ?? "",
            ])
        }
        return out
    }

    /// Parse an OpenAI `chat/completions` response into a `ToolUseTurn`. Reads
    /// `choices[0].message.content` + `.tool_calls[].{id, function.{name, arguments}}`;
    /// `finish_reason == "stop"` is terminal, `"tool_calls"` is not.
    static func parseOpenAIToolTurn(_ json: [String: Any]) throws -> ToolUseTurn {
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first
        else { throw AIError.malformedResponse("openai") }
        let message = choice["message"] as? [String: Any] ?? [:]
        let text = message["content"] as? String
        var calls: [ToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let fn = raw["function"] as? [String: Any],
                      let name = fn["name"] as? String
                else { continue }
                let args = fn["arguments"] as? String ?? "{}"
                calls.append(ToolCall(id: id, name: name, argsJSON: args))
            }
        }
        let finishReason = choice["finish_reason"] as? String
        // Terminal when the model stopped; not terminal when it wants tools. Treat a
        // present tool_calls list as non-terminal even if finish_reason is missing.
        let finished = calls.isEmpty && finishReason != "tool_calls"
        return ToolUseTurn(text: text, toolCalls: calls, finished: finished)
    }

    // MARK: Anthropic tool-use (messages)

    private func chatWithToolsAnthropic(
        messages: [AIChatMessage],
        tools: [ToolSpec],
        systemPrompt: String?,
        maxTokens: Int
    ) async throws -> ToolUseTurn {
        guard let key = resolvedKey(for: "anthropic"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.anthropic)
        }
        let encoded = Self.encodeAnthropicMessages(messages)
        let toolSpecs: [[String: Any]] = tools.map { spec in
            ["name": spec.name,
             "description": spec.description,
             "input_schema": spec.parametersObject]
        }
        var body: [String: Any] = [
            "model": resolvedAnthropicModel,
            "max_tokens": maxTokens,
            "messages": encoded,
        ]
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        if !toolSpecs.isEmpty {
            body["tools"] = toolSpecs
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = data
        let (responseData, response) = try await transportRef.data(for: req)
        try checkHTTPShared(response, data: responseData, provider: "anthropic")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIError.malformedResponse("anthropic")
        }
        return try Self.parseAnthropicToolTurn(json)
    }

    /// Build Anthropic's `messages` from the provider-neutral history. Mirrors
    /// `AnthropicAdapter.record_assistant_turn` / `record_tool_results`:
    /// - an assistant turn with tool calls → content blocks
    ///   `[{type:"text",…}?, {type:"tool_use", id, name, input}…]`
    /// - tool results → a single `{role:"user", content:[{type:"tool_result",
    ///   tool_use_id, content:[{type:"text", text}]}…]}` message
    /// - plain text turns → `{role, content:"…"}` (string content)
    static func encodeAnthropicMessages(_ messages: [AIChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in messages {
            if !msg.toolResults.isEmpty {
                let blocks: [[String: Any]] = msg.toolResults.map { result in
                    ["type": "tool_result",
                     "tool_use_id": result.id,
                     "content": [["type": "text", "text": result.resultJSON]]]
                }
                out.append(["role": "user", "content": blocks])
                continue
            }
            if msg.role == .assistant, !msg.toolCalls.isEmpty {
                var blocks: [[String: Any]] = []
                if let text = msg.text, !text.isEmpty {
                    blocks.append(["type": "text", "text": text])
                }
                for call in msg.toolCalls {
                    blocks.append([
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": Self.jsonObject(call.argsJSON),
                    ])
                }
                out.append(["role": "assistant", "content": blocks])
                continue
            }
            // Anthropic has no system role in `messages` — system rides the top-level
            // `system` field. Map any stray system turn to user to stay valid.
            let role = (msg.role == .assistant) ? "assistant" : "user"
            out.append(["role": role, "content": msg.text ?? ""])
        }
        return out
    }

    /// Parse an Anthropic `messages` response into a `ToolUseTurn`. Concatenates
    /// `text` content blocks and collects `tool_use` blocks `{id, name, input}`;
    /// `stop_reason == "end_turn"` is terminal, `"tool_use"` is not.
    static func parseAnthropicToolTurn(_ json: [String: Any]) throws -> ToolUseTurn {
        guard let content = json["content"] as? [[String: Any]] else {
            throw AIError.malformedResponse("anthropic")
        }
        var textChunks: [String] = []
        var calls: [ToolCall] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, !text.isEmpty {
                    textChunks.append(text)
                }
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String
                else { continue }
                let input = block["input"] as? [String: Any] ?? [:]
                let argsJSON = Self.jsonString(input)
                calls.append(ToolCall(id: id, name: name, argsJSON: argsJSON))
            default:
                break
            }
        }
        let stopReason = json["stop_reason"] as? String
        let finished = calls.isEmpty && stopReason != "tool_use"
        let text = textChunks.isEmpty ? nil : textChunks.joined(separator: "\n")
        return ToolUseTurn(text: text, toolCalls: calls, finished: finished)
    }

    // MARK: JSON helpers

    /// Decode a JSON-object string to `[String: Any]`; empty object on failure.
    /// Used to re-embed OpenAI-style `arguments` strings as Anthropic `input` objects.
    static func jsonObject(_ jsonString: String) -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    /// Encode a JSON object to a string; `"{}"` on failure. Used to normalize
    /// Anthropic `input` objects to a uniform `ToolCall.argsJSON` string.
    static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }
}
