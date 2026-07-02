import Foundation
import Testing
@testable import AIProviderKit

// SP-D vision port — headless tests for `BYOKeyProvider.generateWithImage`.
// Reuses the module-internal MockHTTPTransport from BYOKeyProviderTests.swift;
// brings its own key store (that one is file-private there).
//
// Verifies, per vendor:
//   • the request body carries the vendor-specific image content block
//     (OpenAI: image_url data URI; Anthropic: base64 image source; open-models
//     incl. OpenRouter: OpenAI-compatible image_url), alongside the text prompt
//     and system prompt.
//   • the success response parses into an AIResponse.
//   • missing key / unsupported model surface the expected AIError.

private final class ImgKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    func key(for provider: String) -> String? { keys[provider] }
    func setKey(_ key: String?, for provider: String) { keys[provider] = key }
}

private func imgOpenAISuccessData(content: String = #"{"name":"basil"}"#) -> Data {
    let json = """
    { "choices": [ { "message": { "role": "assistant", "content": \(imgJSONString(content)) } } ] }
    """
    return json.data(using: .utf8)!
}

private func imgAnthropicSuccessData(text: String = #"{"name":"basil"}"#) -> Data {
    let json = """
    { "content": [{"type": "text", "text": \(imgJSONString(text))}] }
    """
    return json.data(using: .utf8)!
}

private func imgJSONString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func imgBody(_ transport: MockHTTPTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private let sampleImage = Data([0xFF, 0xD8, 0xFF, 0xD9]) // minimal fake JPEG bytes

// MARK: - OpenAI image request body

@Test("OpenAI image body carries system + a user content array with text then image_url data URI")
func openAIVisionRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: imgOpenAISuccessData())
    let keyStore = ImgKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, openAIModel: "gpt-4o", transport: transport)
    let request = AIRequest(
        feature: .companionDraft,
        systemPrompt: "You are a culinary expert.",
        prompt: "Identify the ingredient in this photo.",
        wantsStructuredJSON: true
    )
    _ = try await provider.generateWithImage(request, imageData: sampleImage, mimeType: "image/jpeg")

    let body = try imgBody(transport)
    #expect(body["model"] as? String == "gpt-4o")
    #expect((body["temperature"] as? Double) == 0.2)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let system = messages.first(where: { $0["role"] as? String == "system" })
    #expect(system?["content"] as? String == "You are a culinary expert.")
    let user = try #require(messages.first(where: { $0["role"] as? String == "user" }))
    let content = try #require(user["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[0]["text"] as? String == "Identify the ingredient in this photo.")
    #expect(content[1]["type"] as? String == "image_url")
    let imageURL = try #require(content[1]["image_url"] as? [String: Any])
    let url = try #require(imageURL["url"] as? String)
    #expect(url == "data:image/jpeg;base64,\(sampleImage.base64EncodedString())")
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
}

@Test("OpenAI image success response parses into AIResponse")
func openAIVisionResponseParsing() async throws {
    let transport = MockHTTPTransport(responseData: imgOpenAISuccessData(content: #"{"name":"habanero pepper"}"#))
    let keyStore = ImgKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    let response = try await provider.generateWithImage(
        AIRequest(feature: .companionDraft, prompt: "go", wantsStructuredJSON: true),
        imageData: sampleImage, mimeType: "image/jpeg"
    )
    #expect(response.text == #"{"name":"habanero pepper"}"#)
    #expect(response.tier == .cloudBYOKey(.openAI))
}

@Test("OpenAI image missing key throws AIError.noKeyConfigured")
func openAIVisionMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = ImgKeyStore()
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openAI)) {
        _ = try await provider.generateWithImage(
            AIRequest(feature: .companionDraft, prompt: "x"), imageData: sampleImage, mimeType: "image/jpeg"
        )
    }
}

// MARK: - Anthropic image request body

@Test("Anthropic image body carries system + a user content array with the image source block before the text block")
func anthropicVisionRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: imgAnthropicSuccessData())
    let keyStore = ImgKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(
        model: .anthropic, keyStore: keyStore, anthropicModel: "claude-opus-4-5", transport: transport
    )
    let request = AIRequest(
        feature: .companionDraft,
        systemPrompt: "You are a calm cooking coach.",
        prompt: "Judge whether the cook is on track.",
        wantsStructuredJSON: true
    )
    _ = try await provider.generateWithImage(request, imageData: sampleImage, mimeType: "image/png")

    let body = try imgBody(transport)
    #expect(body["model"] as? String == "claude-opus-4-5")
    #expect((body["max_tokens"] as? Int) == 1500)
    #expect(body["system"] as? String == "You are a calm cooking coach.")
    let messages = try #require(body["messages"] as? [[String: Any]])
    let userMsg = try #require(messages.first(where: { $0["role"] as? String == "user" }))
    let content = try #require(userMsg["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "image")
    let source = try #require(content[0]["source"] as? [String: Any])
    #expect(source["type"] as? String == "base64")
    #expect(source["media_type"] as? String == "image/png")
    #expect(source["data"] as? String == sampleImage.base64EncodedString())
    #expect(content[1]["type"] as? String == "text")
    #expect(content[1]["text"] as? String == "Judge whether the cook is on track.")
    #expect(transport.capturedRequest?.url?.absoluteString == "https://api.anthropic.com/v1/messages")
}

@Test("Anthropic image missing key throws AIError.noKeyConfigured")
func anthropicVisionMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = ImgKeyStore()
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.anthropic)) {
        _ = try await provider.generateWithImage(
            AIRequest(feature: .companionDraft, prompt: "x"), imageData: sampleImage, mimeType: "image/jpeg"
        )
    }
}

// MARK: - Open-models (OpenRouter) image request body

@Test("OpenRouter (open-models) image body uses the OpenAI-compatible image_url form + the vendor's chat URL")
func openRouterVisionRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: imgOpenAISuccessData())
    let keyStore = ImgKeyStore()
    keyStore.setKey("sk-or-test", for: ProviderRegistry.descriptor(for: .openRouter).keychainKeyID)
    let provider = BYOKeyProvider(model: .openModels(.openRouter), keyStore: keyStore, transport: transport)
    let request = AIRequest(
        feature: .companionDraft,
        prompt: "Identify the ingredient in this photo.",
        wantsStructuredJSON: true
    )
    _ = try await provider.generateWithImage(request, imageData: sampleImage, mimeType: "image/jpeg")

    let body = try imgBody(transport)
    let messages = try #require(body["messages"] as? [[String: Any]])
    let user = try #require(messages.first(where: { $0["role"] as? String == "user" }))
    let content = try #require(user["content"] as? [[String: Any]])
    #expect(content.count == 2)
    #expect(content[0]["type"] as? String == "text")
    #expect(content[1]["type"] as? String == "image_url")
    let imageURL = try #require(content[1]["image_url"] as? [String: Any])
    #expect((imageURL["url"] as? String) == "data:image/jpeg;base64,\(sampleImage.base64EncodedString())")
    #expect(transport.capturedRequest?.url?.absoluteString == ProviderRegistry.descriptor(for: .openRouter).chatURL)
}

@Test("Open-models image missing key throws AIError.noKeyConfigured")
func openModelsVisionMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = ImgKeyStore()
    let provider = BYOKeyProvider(model: .openModels(.openRouter), keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openModels(.openRouter))) {
        _ = try await provider.generateWithImage(
            AIRequest(feature: .companionDraft, prompt: "x"), imageData: sampleImage, mimeType: "image/jpeg"
        )
    }
}

// MARK: - Unsupported model

@Test("Gemini image throws AIError.notWiredYet")
func geminiVisionNotWired() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = ImgKeyStore()
    let provider = BYOKeyProvider(model: .gemini, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.notWiredYet(.cloudBYOKey(.gemini))) {
        _ = try await provider.generateWithImage(
            AIRequest(feature: .companionDraft, prompt: "x"), imageData: sampleImage, mimeType: "image/jpeg"
        )
    }
}
