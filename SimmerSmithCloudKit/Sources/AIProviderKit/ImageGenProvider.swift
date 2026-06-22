import Foundation

// SP-C AI-4 — BYO-key recipe image generation.
//
// Ports the transport + request/response shapes of
// `app/services/recipe_image_ai.py` (`_generate_via_openai` / `_generate_via_gemini`
// + `_extract_openai_image` / `_extract_gemini_image`) to a BYO-key Swift path.
// The HTTPTransport is injected exactly like `BYOKeyProvider`, so the request
// bodies and the b64/inlineData decode are verifiable headlessly with a
// MockHTTPTransport — no real image API calls.
//
// The failover decision (OpenAI→Gemini on a transient error) lives one layer up
// in AIService (it owns both keys + the `image_provider` setting); this layer
// just maps a single provider's failures to `AIError.imageGenFailed(transient:)`.

/// Which API to call for image generation. (A subset of `CloudModel` — Anthropic
/// has no image-gen, OpenRouter isn't wired for images.)
public enum ImageProvider: String, Sendable, Equatable {
    case openAI = "openai"
    case gemini = "gemini"
}

/// Generates recipe header images via the user's own key. The HTTPTransport is
/// injectable (mirrors `BYOKeyProvider`) so tests verify request bodies + parsing
/// without hitting the network. Default model strings match the server's
/// `gpt-image-1` / `gemini-2.5-flash-image-preview`.
public struct ImageGenProvider: Sendable {
    public static let defaultOpenAIModel = "gpt-image-1"
    public static let defaultGeminiModel = "gemini-2.5-flash-image-preview"

    /// PNG is the default for both providers; used before the response shape is read.
    static let defaultMIME = "image/png"

    /// HTTP statuses that suggest a transient provider hiccup (retry / failover
    /// worthwhile). Permanent 4xx (400 bad prompt, 401 bad key, 403 content
    /// policy) are deliberately excluded — another provider would reject them too.
    /// Mirrors `recipe_image_ai._TRANSIENT_STATUS_CODES`.
    static let transientStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.transport = transport
    }

    /// Generate one image for `prompt` via `provider`, using `key`. Returns the
    /// decoded image bytes + its MIME type. Throws `AIError.imageGenFailed` —
    /// `transient: true` for 5xx/429/network (the failover layer may retry),
    /// `transient: false` for 4xx/auth/malformed (surface as-is).
    public func generateImage(
        prompt: String,
        provider: ImageProvider,
        model: String? = nil,
        key: String
    ) async throws -> (Data, String) {
        switch provider {
        case .openAI:
            return try await generateOpenAI(
                prompt: prompt, model: model ?? Self.defaultOpenAIModel, key: key)
        case .gemini:
            return try await generateGemini(
                prompt: prompt, model: model ?? Self.defaultGeminiModel, key: key)
        }
    }

    // MARK: - OpenAI (POST /v1/images/generations)

    private func generateOpenAI(prompt: String, model: String, key: String) async throws -> (Data, String) {
        guard !key.isEmpty else {
            throw AIError.imageGenFailed(provider: "openai", transient: false,
                                         detail: "OpenAI API key not configured")
        }
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "n": 1,
            "size": "1024x1024",
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/images/generations")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (responseData, response) = try await sendMappingNetworkErrors(req, provider: "openai")
        try checkImageHTTP(response, data: responseData, provider: "openai")

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIError.imageGenFailed(provider: "openai", transient: false,
                                         detail: "Image response was not JSON")
        }
        return try await extractOpenAIImage(json)
    }

    /// Pull the first base64 image out of an OpenAI images-generations response.
    /// `gpt-image-1` returns `b64_json`; older `dall-e-*` can return a `url` we
    /// fetch as a fallback. Ports `_extract_openai_image`.
    private func extractOpenAIImage(_ json: [String: Any]) async throws -> (Data, String) {
        let items = json["data"] as? [[String: Any]] ?? []
        guard let first = items.first else {
            throw AIError.imageGenFailed(provider: "openai", transient: false,
                                         detail: "Image response had no data array")
        }
        if let b64 = first["b64_json"] as? String, !b64.isEmpty {
            guard let bytes = Data(base64Encoded: b64) else {
                throw AIError.imageGenFailed(provider: "openai", transient: false,
                                             detail: "Image base64 decode failed")
            }
            return (bytes, Self.defaultMIME)
        }
        if let url = first["url"] as? String, url.hasPrefix("http"), let u = URL(string: url) {
            let (bytes, response) = try await sendMappingNetworkErrors(
                URLRequest(url: u), provider: "openai")
            try checkImageHTTP(response, data: bytes, provider: "openai")
            let mime = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            return (bytes, (mime?.isEmpty == false ? mime! : Self.defaultMIME))
        }
        throw AIError.imageGenFailed(provider: "openai", transient: false,
                                     detail: "Image response had no base64 payload or URL")
    }

    // MARK: - Gemini (POST …/models/{model}:generateContent)

    private func generateGemini(prompt: String, model: String, key: String) async throws -> (Data, String) {
        guard !key.isEmpty else {
            throw AIError.imageGenFailed(provider: "gemini", transient: false,
                                         detail: "Gemini API key not configured")
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["responseModalities": ["IMAGE"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (responseData, response) = try await sendMappingNetworkErrors(req, provider: "gemini")
        try checkImageHTTP(response, data: responseData, provider: "gemini")

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw AIError.imageGenFailed(provider: "gemini", transient: false,
                                         detail: "Image response was not JSON")
        }
        return try extractGeminiImage(json)
    }

    /// Walk a Gemini `:generateContent` response for the first `inlineData`
    /// (camelCase) or `inline_data` (snake_case) part — either casing can appear
    /// across API minor versions. Returns decoded bytes + mimeType. Ports
    /// `_extract_gemini_image`.
    private func extractGeminiImage(_ json: [String: Any]) throws -> (Data, String) {
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        guard let first = candidates.first else {
            throw AIError.imageGenFailed(provider: "gemini", transient: false,
                                         detail: "Gemini response had no candidates")
        }
        let content = first["content"] as? [String: Any] ?? [:]
        let parts = content["parts"] as? [[String: Any]] ?? []
        for part in parts {
            guard let inline = (part["inlineData"] as? [String: Any])
                ?? (part["inline_data"] as? [String: Any]) else { continue }
            guard let b64 = inline["data"] as? String, !b64.isEmpty else { continue }
            let mime = (inline["mimeType"] as? String)
                ?? (inline["mime_type"] as? String)
                ?? Self.defaultMIME
            guard let bytes = Data(base64Encoded: b64) else {
                throw AIError.imageGenFailed(provider: "gemini", transient: false,
                                             detail: "Image base64 decode failed")
            }
            return (bytes, mime)
        }
        throw AIError.imageGenFailed(provider: "gemini", transient: false,
                                     detail: "Gemini response had no inlineData part")
    }

    // MARK: - Failover decision (AI-4 review fix F2)

    /// Pure predicate: should the caller failover from OpenAI to Gemini?
    ///
    /// Returns `true` iff:
    ///   - `error` is `.imageGenFailed` with `transient == true` (5xx/429/network),
    ///   - AND `hasGeminiKey` is true (there is a Gemini key to fall back to).
    ///
    /// Permanent failures (4xx/auth/malformed) and all non-image errors return `false`.
    /// Extracted from `AIService.generateRecipeImage` so the decision is unit-testable
    /// without the @MainActor / session-bound service.
    public static func shouldFailoverToGemini(error: AIError, hasGeminiKey: Bool) -> Bool {
        guard hasGeminiKey else { return false }
        if case .imageGenFailed(_, true, _) = error { return true }
        return false
    }

    // MARK: - Shared

    /// Run a request, mapping any transport-level (network) throw to a transient
    /// `imageGenFailed`. Mirrors the server treating `httpx.HTTPError` as transient.
    private func sendMappingNetworkErrors(
        _ request: URLRequest, provider: String
    ) async throws -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.imageGenFailed(provider: provider, transient: true,
                                         detail: "Image request failed: \(error)")
        }
    }

    /// Map a non-200 HTTP status to `imageGenFailed`, classifying transient
    /// (5xx/429/408) vs permanent (other 4xx). Mirrors `_TRANSIENT_STATUS_CODES`.
    /// The body snippet is sanitized before embedding so API keys that provider
    /// 401 bodies echo ("Incorrect API key provided: sk-proj-…") never reach the
    /// detail string — see SecretSanitizer (AI-4 review fix F1).
    private func checkImageHTTP(_ response: URLResponse, data: Data, provider: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard http.statusCode >= 400 else { return }
        let bodyText = String(data: data, encoding: .utf8) ?? "(no body)"
        let snippet = SecretSanitizer.redact(String(bodyText.prefix(200)))
        let transient = Self.transientStatusCodes.contains(http.statusCode)
        throw AIError.imageGenFailed(
            provider: provider, transient: transient,
            detail: "\(provider) returned \(http.statusCode): \(snippet)")
    }
}
