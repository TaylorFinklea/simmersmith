import Foundation

/// Concrete tier providers. The real model calls are SP-B — these are wired stubs
/// that throw `notWiredYet` so the seam, routing, and key storage can be built and
/// tested now without a backend.

// MARK: - HTTPTransport

/// Abstraction over `URLSession.shared` that makes `BYOKeyProvider` headlessly
/// testable — inject a `MockHTTPTransport` in tests, no real API calls needed.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// Default production transport backed by a dedicated `URLSession`.
///
/// `URLSession.shared` carries the system-default 60s request timeout, which a full
/// 21-meal week generation routinely exceeds — the model spends 60–120s composing the
/// plan before the (non-streamed) response arrives, so the idle timer fires and the
/// call fails with "The request timed out." This session raises the per-request idle
/// timeout and the overall resource ceiling so long generations complete. (The
/// reference `SimmerSmithAPIClient` uses 300/600 for the same reason.)
public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(requestTimeout: TimeInterval = 180, resourceTimeout: TimeInterval = 300) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        self.session = URLSession(configuration: config)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

public struct OnDeviceProvider: AIProvider {
    public let tier: AITier = .onDevice
    public init() {}
    public func generate(_ request: AIRequest) async throws -> AIResponse {
        // SP-B: Foundation Models framework — first-gen ~3B on iOS 26, AFM 3 20B /
        // PCC at iOS 27 GA; @Generable for structured output.
        throw AIError.notWiredYet(.onDevice)
    }
}

/// Real BYO-key provider. Calls OpenAI or Anthropic directly using the user's
/// Keychain key. Structured-output mode is requested when `request.wantsStructuredJSON`
/// is true (OpenAI: `response_format.type = "json_object"`; Anthropic: prefill `{`).
/// Provider errors are surfaced as `AIError.httpError` / `AIError.malformedResponse`.
///
/// The `transport` parameter is injectable for headless testing — pass a `MockHTTPTransport`
/// to verify request bodies without calling the real API. Production callers use the
/// default `URLSessionTransport`.
public struct BYOKeyProvider: AIProvider {
    public let tier: AITier
    private let model: CloudModel
    private let keyStore: KeyStore
    /// Model IDs to use. Callers may override; defaults are current flagship models.
    private let openAIModel: String
    private let anthropicModel: String
    /// Selected model id when `model == .openModels(...)`. Empty → the vendor's
    /// descriptor default. A single slot is fine: a provider instance is vendor-specific.
    private let openModelsModel: String
    private let transport: HTTPTransport

    public init(
        model: CloudModel,
        keyStore: KeyStore,
        openAIModel: String = "gpt-4o",
        anthropicModel: String = "claude-opus-4-5",
        openModelsModel: String = "",
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.tier = .cloudBYOKey(model)
        self.model = model
        self.keyStore = keyStore
        self.openAIModel = openAIModel
        self.anthropicModel = anthropicModel
        self.openModelsModel = openModelsModel
        self.transport = transport
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        if request.wantsWebSearch {
            switch model {
            case .openAI:
                return try await searchOpenAI(request)
            case .anthropic:
                return try await searchAnthropic(request)
            case .gemini, .openRouter, .openModels:
                // No built-in web-search tool wired for these providers — degrade with
                // a clear, typed error the UI can surface (AI-2 spec §5; open models
                // drive their own tools but have no provider-native web search).
                throw AIError.webSearchUnsupported(model)
            }
        }
        switch model {
        case .openAI:
            return try await callOpenAI(request)
        case .anthropic:
            return try await callAnthropic(request)
        case .openModels(let vendor):
            return try await callOpenModels(vendor, request)
        case .gemini, .openRouter:
            throw AIError.notWiredYet(tier)
        }
    }

    // MARK: - Open models (OpenAI-compatible /chat/completions, descriptor-driven)

    /// One-shot generate() for an open vendor. Thinking is DISABLED (clean JSON; no
    /// multi-turn continuity to preserve), and the structured path keeps the proven
    /// 400-retry: if the vendor rejects `response_format`, retry without it and lean on
    /// `extractJSONObject` (which also strips a leading <think> block).
    private func callOpenModels(_ vendor: OpenModelVendor, _ request: AIRequest) async throws -> AIResponse {
        let descriptor = ProviderRegistry.descriptor(for: vendor)
        guard let key = keyStore.key(for: descriptor.keychainKeyID), !key.isEmpty else {
            throw AIError.noKeyConfigured(.openModels(vendor))
        }
        do {
            return try await postOpenModelsChat(request, descriptor: descriptor, key: key, forceJSON: request.wantsStructuredJSON)
        } catch AIError.httpError(_, 400, _) where request.wantsStructuredJSON {
            return try await postOpenModelsChat(request, descriptor: descriptor, key: key, forceJSON: false)
        }
    }

    private func postOpenModelsChat(
        _ request: AIRequest, descriptor: ProviderDescriptor, key: String, forceJSON: Bool
    ) async throws -> AIResponse {
        let modelID = openModelsModel.isEmpty ? descriptor.defaultModel : openModelsModel
        var messages: [[String: Any]] = []
        if let sys = request.systemPrompt, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": request.prompt])
        var body: [String: Any] = [
            "model": modelID,
            "messages": messages,
            "temperature": descriptor.oneShotTemperature,
        ]
        // One-shot structured calls disable thinking for every open vendor — clean JSON,
        // and nothing to preserve since there is no multi-turn tool loop here.
        descriptor.applyThinkingDisabled(&body, modelID)
        if forceJSON {
            body["response_format"] = ["type": "json_object"]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: descriptor.chatURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: descriptor.id)
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw AIError.malformedResponse(descriptor.id) }
        // Defensive for every open vendor: response_format is unreliable on some models
        // (e.g. MiniMax M3) and reasoning can leak into content. Extract the JSON object
        // (strip <think> + fence, take first { … last }) whenever JSON is expected.
        let text = request.wantsStructuredJSON ? Self.extractJSONObject(content) : content
        return AIResponse(text: text, tier: tier)
    }

    // MARK: - OpenAI

    private func callOpenAI(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyStore.key(for: "openai"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.openAI)
        }
        do {
            return try await postOpenAIChat(request, key: key, forceJSON: request.wantsStructuredJSON)
        } catch AIError.httpError(_, 400, _) where request.wantsStructuredJSON {
            // The chosen model rejected the structured request with a 400 — typically it
            // doesn't support `response_format: json_object` (some models, e.g.
            // chatgpt-4o-latest, don't), or the prompt didn't contain the literal word
            // "json". Retry once WITHOUT response_format: the prompt already asks for JSON
            // and the parser tolerates it, and the assistant tool-loop runs fine on the
            // same model without it. If even the plain retry fails, that error surfaces.
            return try await postOpenAIChat(request, key: key, forceJSON: false)
        }
    }

    private func postOpenAIChat(_ request: AIRequest, key: String, forceJSON: Bool) async throws -> AIResponse {
        // Build messages: system (if present) then user (week_planner.py:393-396).
        var messages: [[String: Any]] = []
        if let sys = request.systemPrompt, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        messages.append(["role": "user", "content": request.prompt])

        var body: [String: Any] = [
            "model": openAIModel,
            "messages": messages,
            "temperature": 0.7,         // week_planner.py:397 — default 1.0 is too erratic
        ]
        if forceJSON {
            body["response_format"] = ["type": "json_object"]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: "openai")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw AIError.malformedResponse("openai") }
        // On the no-response_format fallback (forceJSON == false) the reply may carry a
        // preamble / code fence — extract the JSON object so the parser sees raw JSON. The
        // response_format path returns raw JSON, so leave it untouched.
        let text = (request.wantsStructuredJSON && !forceJSON) ? Self.extractJSONObject(content) : content
        return AIResponse(text: text, tier: tier)
    }

    /// Remove a surrounding markdown code fence (```json … ``` or ``` … ```), if present.
    static func stripCodeFence(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        } else {
            text = String(text.dropFirst(3))
        }
        if text.hasSuffix("```") {
            text = String(text.dropLast(3))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anthropic

    private func callAnthropic(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyStore.key(for: "anthropic"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.anthropic)
        }
        do {
            return try await postAnthropicMessages(request, key: key, usePrefill: request.wantsStructuredJSON)
        } catch AIError.httpError(_, 400, _) where request.wantsStructuredJSON {
            // Some Anthropic models reject assistant-message prefill ("this model does not
            // support assistant message prefill; the conversation must end with a user
            // message"). Retry WITHOUT the prefill and extract the JSON object from the
            // (possibly prose/fenced) reply. The plain error surfaces if this also fails.
            return try await postAnthropicMessages(request, key: key, usePrefill: false)
        }
    }

    private func postAnthropicMessages(_ request: AIRequest, key: String, usePrefill: Bool) async throws -> AIResponse {
        var messages: [[String: Any]] = [["role": "user", "content": request.prompt]]
        // Structured-output prefill: start the assistant turn with `{` so the model
        // continues as JSON (Anthropic's documented technique). Skipped on the fallback.
        if usePrefill {
            messages.append(["role": "assistant", "content": "{"])
        }
        var body: [String: Any] = [
            "model": anthropicModel,
            "max_tokens": 8000,         // week_planner.py:410 — 4096 truncates a 21-meal plan
            "messages": messages,
        ]
        // System prompt via Anthropic's dedicated `system` field (week_planner.py:412).
        if let sys = request.systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = data
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: "anthropic")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]],
              let text = contentArr.first?["text"] as? String
        else { throw AIError.malformedResponse("anthropic") }

        guard request.wantsStructuredJSON else { return AIResponse(text: text, tier: tier) }
        let result: String
        if usePrefill {
            // Re-attach the prefilled `{` unless the model echoed it / used a fence.
            result = (!text.hasPrefix("{") && !text.hasPrefix("```")) ? "{" + text : text
        } else {
            // No prefill: the reply may carry a preamble / code fence — extract the JSON.
            result = Self.extractJSONObject(text)
        }
        return AIResponse(text: result, tier: tier)
    }

    /// Strip a leading `<think>…</think>` reasoning span. Some open models (notably
    /// MiniMax M3) can still leak inline thinking into `content`; removing only a LEADING
    /// block preserves a legitimate "{…}" body. Harmless for vendors that never emit it.
    static func stripThinkTags(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<think>") else { return trimmed }
        if let close = trimmed.range(of: "</think>", options: .caseInsensitive) {
            return String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Unterminated <think>: drop the opening tag and hope the JSON follows.
        return String(trimmed.dropFirst("<think>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract the outermost JSON object from a possibly prose/fenced/`<think>`-prefixed
    /// reply (used by the no-prefill / no-response_format / open-models fallbacks): strip
    /// a leading think block, strip a code fence, then take from the first "{" to last "}".
    static func extractJSONObject(_ raw: String) -> String {
        let unfenced = stripCodeFence(stripThinkTags(raw))
        guard let first = unfenced.firstIndex(of: "{"),
              let last = unfenced.lastIndex(of: "}"),
              first <= last else { return unfenced }
        return String(unfenced[first...last])
    }

    // MARK: - OpenAI web search (Responses API)

    /// Web-search mode for OpenAI: the Responses API (`/v1/responses`) with the
    /// built-in `web_search` tool. Ports `recipe_search_ai._search_openai` — the
    /// model searches the web, picks one recipe, and returns the recipe JSON as a
    /// `message` output item. The prompt (built by `RecipeAIPrompt.webSearchInput`)
    /// carries the schema; there is no `response_format` on this API surface.
    private func searchOpenAI(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyStore.key(for: "openai"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.openAI)
        }
        let body: [String: Any] = [
            "model": openAIModel,
            "input": request.prompt,
            "tools": [["type": "web_search"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: "openai")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIError.malformedResponse("openai")
        }
        let text = Self.extractOpenAIResponsesText(json)
        guard !text.isEmpty else { throw AIError.malformedResponse("openai") }
        return AIResponse(text: text, tier: tier)
    }

    /// Pull the model's text from an OpenAI Responses payload. Accepts the top-level
    /// `output_text` convenience field, else concatenates the `output_text`/`text`
    /// blocks of any `message` items (skipping `web_search_call` items). Mirrors
    /// `recipe_search_ai._extract_text_from_openai_payload`.
    static func extractOpenAIResponsesText(_ json: [String: Any]) -> String {
        if let convenience = json["output_text"] as? String, !convenience.isEmpty {
            return convenience
        }
        var chunks: [String] = []
        let output = json["output"] as? [[String: Any]] ?? []
        for item in output where item["type"] as? String == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for block in content {
                let type = block["type"] as? String
                if type == "output_text" || type == "text",
                   let text = block["text"] as? String, !text.isEmpty {
                    chunks.append(text)
                }
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anthropic web search (Messages API + web_search_20250305 tool)

    /// Web-search mode for Anthropic: the Messages API with the `web_search_20250305`
    /// server tool (`max_uses: 5` caps the search subqueries). Ports
    /// `recipe_search_ai._search_anthropic`. The structured-output `{` prefill used by
    /// the plain path is intentionally OMITTED — the web-search tool loop is
    /// incompatible with a forced assistant prefix, so the JSON contract rides in the
    /// prompt instead.
    private func searchAnthropic(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyStore.key(for: "anthropic"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.anthropic)
        }
        var body: [String: Any] = [
            "model": anthropicModel,
            // recipe_search_ai.py:247 — the server's web-search path caps at 4096
            // (one recipe fits comfortably); halve the max cost vs. the 8000 the
            // week-planner path uses for a 21-meal plan.
            "max_tokens": 4096,
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]],
            "messages": [["role": "user", "content": request.prompt]],
        ]
        if let sys = request.systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = data
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: "anthropic")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIError.malformedResponse("anthropic")
        }
        let text = Self.extractAnthropicText(json)
        guard !text.isEmpty else { throw AIError.malformedResponse("anthropic") }
        return AIResponse(text: text, tier: tier)
    }

    /// Concatenate the final-answer `text` blocks of an Anthropic Messages payload,
    /// skipping the `server_tool_use` / `web_search_tool_result` blocks the tool loop
    /// emits. Mirrors `recipe_search_ai._extract_text_from_anthropic_payload`.
    static func extractAnthropicText(_ json: [String: Any]) -> String {
        let content = json["content"] as? [[String: Any]] ?? []
        var chunks: [String] = []
        for block in content where block["type"] as? String == "text" {
            if let text = block["text"] as? String, !text.isEmpty {
                chunks.append(text)
            }
        }
        return chunks.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared

    private func checkHTTP(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            let rawBody = String(data: data, encoding: .utf8) ?? "(no body)"
            // Sanitize before storing in the error — provider 401 bodies can echo the
            // submitted key (AI-4 review fix F1, SecretSanitizer).
            let body = SecretSanitizer.redact(rawBody)
            throw AIError.httpError(provider: provider, statusCode: http.statusCode, body: body)
        }
    }

    // MARK: - Internal seams for BYOKeyProviderTools (AI-5)
    //
    // The tool-use call lives in a sibling file (BYOKeyProviderTools.swift); these
    // module-internal accessors let it reach the otherwise-private dependencies
    // without widening their visibility to the whole module's public API.

    var cloudModel: CloudModel { model }
    var transportRef: HTTPTransport { transport }
    var resolvedOpenAIModel: String { openAIModel }
    var resolvedAnthropicModel: String { anthropicModel }
    /// The selected open-models model id, or the vendor's descriptor default when unset.
    var resolvedOpenModelsModel: String {
        guard case .openModels(let vendor) = model else { return openModelsModel }
        return openModelsModel.isEmpty ? ProviderRegistry.descriptor(for: vendor).defaultModel : openModelsModel
    }
    func resolvedKey(for provider: String) -> String? { keyStore.key(for: provider) }
    func checkHTTPShared(_ response: URLResponse, data: Data, provider: String) throws {
        try checkHTTP(response, data: data, provider: provider)
    }
}

/// Provider capable of listing available models — used by the "Test key" button
/// to validate a key cheaply without a generation call.
extension BYOKeyProvider {
    /// Returns a non-empty list of model IDs if the key is valid, throws otherwise.
    public func listModels() async throws -> [String] {
        switch model {
        case .openAI:
            return try await listOpenAIModels()
        case .anthropic:
            return try await listAnthropicModels()
        case .openModels(let vendor):
            return try await listOpenModelsModels(vendor)
        case .gemini, .openRouter:
            throw AIError.notWiredYet(tier)
        }
    }

    /// List an open vendor's models from its `/models` endpoint. If the endpoint is
    /// absent (no `modelsURL`, or it 404s), validate the key with a REAL authenticated
    /// probe before returning the static fallback — so "Test key" never false-positives.
    private func listOpenModelsModels(_ vendor: OpenModelVendor) async throws -> [String] {
        let descriptor = ProviderRegistry.descriptor(for: vendor)
        guard let key = keyStore.key(for: descriptor.keychainKeyID), !key.isEmpty else {
            throw AIError.noKeyConfigured(.openModels(vendor))
        }
        if let modelsURL = descriptor.modelsURL {
            do {
                var req = URLRequest(url: URL(string: modelsURL)!)
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                let (responseData, response) = try await transport.data(for: req)
                try checkHTTP(response, data: responseData, provider: descriptor.id)
                guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                      let data = json["data"] as? [[String: Any]]
                else { throw AIError.malformedResponse(descriptor.id) }
                let ids = data.compactMap { $0["id"] as? String }
                return ids.isEmpty ? descriptor.fallbackModels : ids
            } catch AIError.httpError(_, 404, _) {
                // /models not on this host — validate the key with a real probe, then fall back.
                try await probeOpenModelsKey(descriptor: descriptor, key: key)
                return descriptor.fallbackModels
            }
        }
        try await probeOpenModelsKey(descriptor: descriptor, key: key)
        return descriptor.fallbackModels
    }

    /// A minimal authenticated chat completion used purely to validate a key when no
    /// `/models` listing is available. A 200 means the key works; a 401 surfaces as the
    /// normal httpError. Prevents a static-list return from masquerading as validation.
    private func probeOpenModelsKey(descriptor: ProviderDescriptor, key: String) async throws {
        let modelID = openModelsModel.isEmpty ? descriptor.defaultModel : openModelsModel
        var body: [String: Any] = [
            "model": modelID,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
            "temperature": descriptor.oneShotTemperature,
        ]
        descriptor.applyThinkingDisabled(&body, modelID)
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: descriptor.chatURL)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: descriptor.id)
    }

    private func listOpenAIModels() async throws -> [String] {
        guard let key = keyStore.key(for: "openai"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.openAI)
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: "openai")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let data = json["data"] as? [[String: Any]]
        else { throw AIError.malformedResponse("openai") }
        return data.compactMap { $0["id"] as? String }
    }

    private func listAnthropicModels() async throws -> [String] {
        guard let key = keyStore.key(for: "anthropic"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.anthropic)
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (responseData, response) = try await transport.data(for: req)
        try checkHTTP(response, data: responseData, provider: "anthropic")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let data = json["data"] as? [[String: Any]]
        else { throw AIError.malformedResponse("anthropic") }
        return data.compactMap { $0["id"] as? String }
    }
}

public struct CreditsGatewayProvider: AIProvider {
    public let tier: AITier = .creditsGateway
    public init() {}
    public func generate(_ request: AIRequest) async throws -> AIResponse {
        // SP-E: metered gateway holding our key + a credit ledger.
        throw AIError.notWiredYet(.creditsGateway)
    }
}

/// The single AI call site. Resolves a tier via the router, then dispatches to the
/// matching provider. Provider lookup is injectable so SP-B (and tests) can supply
/// real or fake backends without changing callers.
public struct AIClient: Sendable {
    public var router: ProviderRouter
    private let providerFor: @Sendable (AITier) -> AIProvider?

    public init(router: ProviderRouter, providerFor: @escaping @Sendable (AITier) -> AIProvider?) {
        self.router = router; self.providerFor = providerFor
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        guard let tier = router.tier(for: request.feature) else {
            throw AIError.noProviderAvailable(request.feature)
        }
        guard let provider = providerFor(tier) else {
            throw AIError.noProviderAvailable(request.feature)
        }
        return try await provider.generate(request)
    }
}
