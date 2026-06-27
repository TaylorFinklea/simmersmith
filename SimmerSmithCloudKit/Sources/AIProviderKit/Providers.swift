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

/// Default production transport backed by `URLSession.shared`.
public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
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
    private let transport: HTTPTransport

    public init(
        model: CloudModel,
        keyStore: KeyStore,
        openAIModel: String = "gpt-4o",
        anthropicModel: String = "claude-opus-4-5",
        transport: HTTPTransport = URLSessionTransport()
    ) {
        self.tier = .cloudBYOKey(model)
        self.model = model
        self.keyStore = keyStore
        self.openAIModel = openAIModel
        self.anthropicModel = anthropicModel
        self.transport = transport
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
        if request.wantsWebSearch {
            switch model {
            case .openAI:
                return try await searchOpenAI(request)
            case .anthropic:
                return try await searchAnthropic(request)
            case .gemini, .openRouter:
                // No built-in web-search tool wired for these providers — degrade with
                // a clear, typed error the UI can surface (AI-2 spec §5).
                throw AIError.webSearchUnsupported(model)
            }
        }
        switch model {
        case .openAI:
            return try await callOpenAI(request)
        case .anthropic:
            return try await callAnthropic(request)
        case .gemini, .openRouter:
            throw AIError.notWiredYet(tier)
        }
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
        // Without response_format (the 400 fallback), a model may wrap JSON in a ```json
        // code fence — strip it so the downstream parser sees raw JSON. No-op on the
        // response_format path (raw JSON has no fence).
        let text = request.wantsStructuredJSON ? Self.stripCodeFence(content) : content
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
        var messages: [[String: Any]] = [["role": "user", "content": request.prompt]]
        // Structured-output prefill: start the assistant turn with `{` so the model
        // continues as JSON (Anthropic's documented technique). Only add when the text
        // doesn't already start with `{` or a code fence.
        if request.wantsStructuredJSON {
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
        // Re-attach the prefilled `{` only when the response doesn't already start with
        // it (guard against double-prepend when the model echoes the prefill back).
        let result: String
        if request.wantsStructuredJSON && !text.hasPrefix("{") && !text.hasPrefix("```") {
            result = "{" + text
        } else {
            result = text
        }
        return AIResponse(text: result, tier: tier)
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
        case .gemini, .openRouter:
            throw AIError.notWiredYet(tier)
        }
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
