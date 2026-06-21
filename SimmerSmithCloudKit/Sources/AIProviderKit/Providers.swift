import Foundation

/// Concrete tier providers. The real model calls are SP-B — these are wired stubs
/// that throw `notWiredYet` so the seam, routing, and key storage can be built and
/// tested now without a backend.

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
/// Provider errors are surfaced as `AIError.providerError`.
public struct BYOKeyProvider: AIProvider {
    public let tier: AITier
    private let model: CloudModel
    private let keyStore: KeyStore
    /// Model IDs to use. Callers may override; defaults are current flagship models.
    private let openAIModel: String
    private let anthropicModel: String

    public init(
        model: CloudModel,
        keyStore: KeyStore,
        openAIModel: String = "gpt-4o",
        anthropicModel: String = "claude-opus-4-5"
    ) {
        self.tier = .cloudBYOKey(model)
        self.model = model
        self.keyStore = keyStore
        self.openAIModel = openAIModel
        self.anthropicModel = anthropicModel
    }

    public func generate(_ request: AIRequest) async throws -> AIResponse {
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
        var body: [String: Any] = [
            "model": openAIModel,
            "messages": [["role": "user", "content": request.prompt]]
        ]
        if request.wantsStructuredJSON {
            body["response_format"] = ["type": "json_object"]
        }
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: responseData, provider: "openai")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw AIError.malformedResponse("openai") }
        return AIResponse(text: content, tier: tier)
    }

    // MARK: - Anthropic

    private func callAnthropic(_ request: AIRequest) async throws -> AIResponse {
        guard let key = keyStore.key(for: "anthropic"), !key.isEmpty else {
            throw AIError.noKeyConfigured(.anthropic)
        }
        var messages: [[String: Any]] = [["role": "user", "content": request.prompt]]
        // Structured-output prefill: start the assistant turn with `{` so the model
        // continues as JSON. This is Anthropic's documented structured-output technique.
        if request.wantsStructuredJSON {
            messages.append(["role": "assistant", "content": "{"])
        }
        let body: [String: Any] = [
            "model": anthropicModel,
            "max_tokens": 4096,
            "messages": messages
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = data
        let (responseData, response) = try await URLSession.shared.data(for: req)
        try checkHTTP(response, data: responseData, provider: "anthropic")
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let contentArr = json["content"] as? [[String: Any]],
              let text = contentArr.first?["text"] as? String
        else { throw AIError.malformedResponse("anthropic") }
        // Re-attach the prefilled `{` when we used it.
        let result = request.wantsStructuredJSON ? "{" + text : text
        return AIResponse(text: result, tier: tier)
    }

    // MARK: - Shared

    private func checkHTTP(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "(no body)"
            throw AIError.httpError(provider: provider, statusCode: http.statusCode, body: body)
        }
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
        let (responseData, response) = try await URLSession.shared.data(for: req)
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
        let (responseData, response) = try await URLSession.shared.data(for: req)
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
