import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-4 — headless tests for the image-gen path + prompt builder.
//
// Reuses the module-internal `MockHTTPTransport` (BYOKeyProviderTests.swift) so no
// real image API is hit. Verifies:
//   • RecipeImagePrompt.build — the port of recipe_image_ai._build_prompt
//     (name fallback, cuisine clause, top-5 ingredients, empties collapse)
//   • OpenAI request: endpoint + body {model:"gpt-image-1", prompt, n:1, size}
//   • Gemini request: endpoint + body {contents…, generationConfig.responseModalities}
//   • b64_json → Data (OpenAI) and inlineData.data → Data + mimeType (Gemini)
//   • transient (5xx/429/408/network) vs permanent (4xx/auth/malformed) mapping

// MARK: - Helpers (private — distinct from the BYOKey test-file privates)

private func imgBodyJSON(from transport: MockHTTPTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 1x1 transparent PNG, base64. A real decodable image payload for the parse tests.
private let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

private func openAIB64Response(_ b64: String = onePixelPNGBase64) -> Data {
    """
    {"data":[{"b64_json":"\(b64)"}]}
    """.data(using: .utf8)!
}

private func geminiInlineResponse(_ b64: String = onePixelPNGBase64,
                                  mime: String = "image/png",
                                  camelCase: Bool = true) -> Data {
    let key = camelCase ? "inlineData" : "inline_data"
    let mimeKey = camelCase ? "mimeType" : "mime_type"
    return """
    {"candidates":[{"content":{"parts":[{"\(key)":{"\(mimeKey)":"\(mime)","data":"\(b64)"}}]}}]}
    """.data(using: .utf8)!
}

// MARK: - Prompt builder

@Test("image prompt: full recipe renders name + cuisine + top ingredients, trailing period")
func imagePromptFull() {
    let prompt = RecipeImagePrompt.build(
        name: "Chicken Tikka Masala",
        cuisine: "Indian",
        ingredients: ["chicken", "yogurt", "tomato", "garam masala", "garlic"]
    )
    #expect(prompt == "A photographic, top-down shot of Chicken Tikka Masala. "
        + "a Indian dish. plated on a wooden table, soft natural light, no text, no watermarks. "
        + "Visible ingredients: chicken, yogurt, tomato, garam masala, garlic.")
}

@Test("image prompt: empty cuisine + no ingredients collapse out")
func imagePromptCollapsesEmpties() {
    let prompt = RecipeImagePrompt.build(name: "Oatmeal")
    #expect(prompt == "A photographic, top-down shot of Oatmeal. "
        + "plated on a wooden table, soft natural light, no text, no watermarks.")
}

@Test("image prompt: blank name falls back to 'a meal'")
func imagePromptBlankNameFallback() {
    let prompt = RecipeImagePrompt.build(name: "   ")
    #expect(prompt.hasPrefix("A photographic, top-down shot of a meal."))
}

@Test("image prompt: only first 5 ingredients used; blanks skipped")
func imagePromptTopFiveAndBlanks() {
    let prompt = RecipeImagePrompt.build(
        name: "Stew",
        ingredients: ["a", "  ", "b", "c", "d", "e", "f", "g"]
    )
    // "  " is dropped; then the first 5 of the input slice are taken (a, _, b, c, d)
    // → after blank-skip: a, b, c, d. "e","f","g" are past the prefix(5) cut.
    #expect(prompt.hasSuffix("Visible ingredients: a, b, c, d."))
}

// MARK: - OpenAI request body

@Test("OpenAI image request: endpoint + body model/prompt/n/size")
func openAIImageRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: openAIB64Response())
    let provider = ImageGenProvider(transport: transport)
    _ = try await provider.generateImage(
        prompt: "a photo of pasta", provider: .openAI, key: "sk-test")

    let req = try #require(transport.capturedRequest)
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/images/generations")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")

    let body = try imgBodyJSON(from: transport)
    #expect(body["model"] as? String == "gpt-image-1")
    #expect(body["prompt"] as? String == "a photo of pasta")
    #expect(body["n"] as? Int == 1)
    #expect(body["size"] as? String == "1024x1024")
}

// MARK: - Gemini request body

@Test("Gemini image request: endpoint + contents + responseModalities IMAGE")
func geminiImageRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: geminiInlineResponse())
    let provider = ImageGenProvider(transport: transport)
    _ = try await provider.generateImage(
        prompt: "a photo of pasta", provider: .gemini, key: "g-test")

    let req = try #require(transport.capturedRequest)
    #expect(req.url?.absoluteString ==
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image-preview:generateContent")
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "g-test")

    let body = try imgBodyJSON(from: transport)
    let contents = body["contents"] as? [[String: Any]]
    let parts = contents?.first?["parts"] as? [[String: Any]]
    #expect(parts?.first?["text"] as? String == "a photo of pasta")
    let genConfig = body["generationConfig"] as? [String: Any]
    #expect(genConfig?["responseModalities"] as? [String] == ["IMAGE"])
}

// MARK: - Response parsing

@Test("OpenAI b64_json decodes to image bytes + image/png")
func openAIB64Parsing() async throws {
    let transport = MockHTTPTransport(responseData: openAIB64Response())
    let provider = ImageGenProvider(transport: transport)
    let (data, mime) = try await provider.generateImage(
        prompt: "p", provider: .openAI, key: "sk-test")
    #expect(mime == "image/png")
    #expect(data == Data(base64Encoded: onePixelPNGBase64))
    #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47])) // PNG magic
}

@Test("Gemini inlineData decodes to image bytes + its mimeType (camelCase)")
func geminiInlineParsing() async throws {
    let transport = MockHTTPTransport(
        responseData: geminiInlineResponse(mime: "image/png", camelCase: true))
    let provider = ImageGenProvider(transport: transport)
    let (data, mime) = try await provider.generateImage(
        prompt: "p", provider: .gemini, key: "g-test")
    #expect(mime == "image/png")
    #expect(data == Data(base64Encoded: onePixelPNGBase64))
}

@Test("Gemini inline_data snake_case also parses")
func geminiInlineSnakeCase() async throws {
    let transport = MockHTTPTransport(
        responseData: geminiInlineResponse(mime: "image/webp", camelCase: false))
    let provider = ImageGenProvider(transport: transport)
    let (data, mime) = try await provider.generateImage(
        prompt: "p", provider: .gemini, key: "g-test")
    #expect(mime == "image/webp")
    #expect(data == Data(base64Encoded: onePixelPNGBase64))
}

// MARK: - Error mapping (transient vs permanent)

@Test("OpenAI 401 maps to permanent imageGenFailed")
func openAI401Permanent() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"invalid_api_key"}"#.data(using: .utf8)!, responseStatus: 401)
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .openAI, key: "sk-bad")
    } throws: { error in
        guard case let .imageGenFailed(prov, transient, _) = error as? AIError else { return false }
        return prov == "openai" && transient == false
    }
}

@Test("OpenAI 500 maps to transient imageGenFailed")
func openAI500Transient() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"server"}"#.data(using: .utf8)!, responseStatus: 500)
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .openAI, key: "sk-test")
    } throws: { error in
        guard case let .imageGenFailed(_, transient, _) = error as? AIError else { return false }
        return transient == true
    }
}

@Test("OpenAI 429 maps to transient imageGenFailed")
func openAI429Transient() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"rate"}"#.data(using: .utf8)!, responseStatus: 429)
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .openAI, key: "sk-test")
    } throws: { error in
        guard case let .imageGenFailed(_, transient, _) = error as? AIError else { return false }
        return transient == true
    }
}

@Test("Gemini 503 maps to transient imageGenFailed")
func gemini503Transient() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"unavailable"}"#.data(using: .utf8)!, responseStatus: 503)
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .gemini, key: "g-test")
    } throws: { error in
        guard case let .imageGenFailed(prov, transient, _) = error as? AIError else { return false }
        return prov == "gemini" && transient == true
    }
}

@Test("Gemini 400 maps to permanent imageGenFailed")
func gemini400Permanent() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"bad request"}"#.data(using: .utf8)!, responseStatus: 400)
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .gemini, key: "g-test")
    } throws: { error in
        guard case let .imageGenFailed(_, transient, _) = error as? AIError else { return false }
        return transient == false
    }
}

@Test("network-level transport error maps to transient imageGenFailed")
func networkErrorTransient() async {
    let transport = ThrowingTransport()
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .openAI, key: "sk-test")
    } throws: { error in
        guard case let .imageGenFailed(_, transient, _) = error as? AIError else { return false }
        return transient == true
    }
}

@Test("empty key maps to permanent imageGenFailed (no request sent)")
func emptyKeyPermanent() async {
    let transport = MockHTTPTransport(responseData: openAIB64Response())
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .openAI, key: "")
    } throws: { error in
        guard case let .imageGenFailed(_, transient, _) = error as? AIError else { return false }
        return transient == false
    }
    #expect(transport.capturedRequest == nil)
}

@Test("OpenAI empty data array maps to permanent imageGenFailed")
func openAIEmptyDataPermanent() async {
    let transport = MockHTTPTransport(responseData: #"{"data":[]}"#.data(using: .utf8)!)
    let provider = ImageGenProvider(transport: transport)
    await #expect {
        _ = try await provider.generateImage(prompt: "p", provider: .openAI, key: "sk-test")
    } throws: { error in
        guard case let .imageGenFailed(_, transient, _) = error as? AIError else { return false }
        return transient == false
    }
}

// MARK: - Transport double that always throws (network failure)

private struct ThrowingTransport: HTTPTransport {
    struct Boom: Error {}
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw Boom()
    }
}

// MARK: - F1: SecretSanitizer (AI-4 review fix)

@Test("redactSecrets: sk- key is replaced, surrounding text preserved")
func redactSKKey() {
    let input = "Incorrect API key provided: sk-proj-ABC123xyz456789. Please check your key."
    let result = SecretSanitizer.redact(input)
    #expect(!result.contains("sk-proj-ABC123xyz456789"))
    #expect(result.contains("sk-***"))
    #expect(result.contains("Incorrect API key provided:"))
    #expect(result.contains("Please check your key."))
}

@Test("redactSecrets: short sk- run below 8 chars is NOT redacted")
func redactSKTooShort() {
    let input = "sk-abc"
    let result = SecretSanitizer.redact(input)
    // Under 8-char suffix → no match → unchanged.
    #expect(result == "sk-abc")
}

@Test("redactSecrets: AIza Google key is replaced")
func redactGoogleKey() {
    let input = "bad key AIza0987654321abcdefg here"
    let result = SecretSanitizer.redact(input)
    #expect(!result.contains("AIza0987654321abcdefg"))
    #expect(result.contains("AIza***"))
}

@Test("redactSecrets: Bearer token is replaced")
func redactBearerToken() {
    let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 rejected"
    let result = SecretSanitizer.redact(input)
    #expect(!result.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
    #expect(result.contains("Bearer ***"))
}

@Test("redactSecrets: plain prose without keys is unchanged")
func redactPlainProse() {
    let input = "openai returned 500: internal server error"
    #expect(SecretSanitizer.redact(input) == input)
}

// MARK: - F2: shouldFailoverToGemini (AI-4 review fix)

@Test("shouldFailoverToGemini: transient error + Gemini key → true")
func failoverTransientWithKey() {
    let err = AIError.imageGenFailed(provider: "openai", transient: true, detail: "server error")
    #expect(ImageGenProvider.shouldFailoverToGemini(error: err, hasGeminiKey: true) == true)
}

@Test("shouldFailoverToGemini: permanent error + Gemini key → false")
func failoverPermanentWithKey() {
    let err = AIError.imageGenFailed(provider: "openai", transient: false, detail: "bad key")
    #expect(ImageGenProvider.shouldFailoverToGemini(error: err, hasGeminiKey: true) == false)
}

@Test("shouldFailoverToGemini: transient error + no Gemini key → false")
func failoverTransientNoKey() {
    let err = AIError.imageGenFailed(provider: "openai", transient: true, detail: "server error")
    #expect(ImageGenProvider.shouldFailoverToGemini(error: err, hasGeminiKey: false) == false)
}

@Test("shouldFailoverToGemini: non-image error + Gemini key → false")
func failoverNonImageError() {
    let err = AIError.malformedResponse("openai")
    #expect(ImageGenProvider.shouldFailoverToGemini(error: err, hasGeminiKey: true) == false)
}
