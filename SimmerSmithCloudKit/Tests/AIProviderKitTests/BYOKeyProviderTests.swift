import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-1 review fix (T1) — headless tests for BYOKeyProvider.
//
// Uses a MockHTTPTransport (satisfies the injectable HTTPTransport protocol) so no
// real API calls are made. Verifies:
//   • OpenAI request body: model / messages / temperature / response_format
//   • Anthropic request body: model / max_tokens / system / messages / prefill
//   • JSON response parsing → AIResponse
//   • 401 HTTP status maps to AIError.httpError
//   • Missing key maps to AIError.noKeyConfigured

// MARK: - Mock transport

/// Captures the last request and returns a scripted response.
final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    var capturedRequest: URLRequest?
    var responseData: Data
    var responseStatus: Int

    init(responseData: Data, responseStatus: Int = 200) {
        self.responseData = responseData
        self.responseStatus = responseStatus
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        capturedRequest = request
        let url = request.url ?? URL(string: "https://example.com")!
        let resp = HTTPURLResponse(url: url, statusCode: responseStatus,
                                   httpVersion: nil, headerFields: nil)!
        return (responseData, resp)
    }
}

/// A simple KeyStore that holds one key per provider ID in memory.
private final class MockKeyStore: KeyStore, @unchecked Sendable {
    private var keys: [String: String] = [:]
    func key(for provider: String) -> String? { keys[provider] }
    func setKey(_ key: String?, for provider: String) { keys[provider] = key }
}

// MARK: - Helpers

private func openAISuccessData(content: String = #"{"day":1}"#) -> Data {
    let json = """
    {
      "choices": [
        {"message": {"role": "assistant", "content": \(jsonString(content))}}
      ]
    }
    """
    return json.data(using: .utf8)!
}

private func anthropicSuccessData(text: String = #"{"day":1}"#) -> Data {
    let json = """
    {
      "content": [{"type": "text", "text": \(jsonString(text))}]
    }
    """
    return json.data(using: .utf8)!
}

private func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

private func bodyJSON(from transport: MockHTTPTransport) throws -> [String: Any] {
    let data = try #require(transport.capturedRequest?.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - OpenAI request body

@Test("OpenAI body carries model, messages, temperature, and response_format for structured JSON")
func openAIRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: openAISuccessData())
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore,
                                  openAIModel: "gpt-4o", transport: transport)
    let request = AIRequest(
        feature: .weekGen,
        systemPrompt: "You are a meal planner.",
        prompt: "Plan 21 meals.",
        wantsStructuredJSON: true
    )
    _ = try await provider.generate(request)

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "gpt-4o")
    #expect((body["temperature"] as? Double) == 0.7)
    let rf = body["response_format"] as? [String: Any]
    #expect(rf?["type"] as? String == "json_object")

    let messages = body["messages"] as? [[String: Any]]
    let system = messages?.first(where: { $0["role"] as? String == "system" })
    let user = messages?.first(where: { $0["role"] as? String == "user" })
    #expect(system?["content"] as? String == "You are a meal planner.")
    #expect(user?["content"] as? String == "Plan 21 meals.")
}

@Test("OpenAI body omits response_format when wantsStructuredJSON is false")
func openAINoStructuredFormat() async throws {
    let transport = MockHTTPTransport(responseData: openAISuccessData())
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    let request = AIRequest(feature: .substitution, prompt: "what can I sub for eggs?")
    _ = try await provider.generate(request)

    let body = try bodyJSON(from: transport)
    #expect(body["response_format"] == nil)
}

@Test("OpenAI success response parses into AIResponse")
func openAIResponseParsing() async throws {
    let transport = MockHTTPTransport(responseData: openAISuccessData(content: #"{"meals":[]}"#))
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-test", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    let response = try await provider.generate(AIRequest(feature: .weekGen, prompt: "go"))
    #expect(response.text == #"{"meals":[]}"#)
    #expect(response.tier == .cloudBYOKey(.openAI))
}

@Test("OpenAI 401 throws AIError.httpError")
func openAI401() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"invalid_api_key"}"#.data(using: .utf8)!,
        responseStatus: 401
    )
    let keyStore = MockKeyStore()
    keyStore.setKey("sk-bad", for: "openai")
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.httpError(provider: "openai", statusCode: 401, body: #"{"error":"invalid_api_key"}"#)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x"))
    }
}

@Test("OpenAI missing key throws AIError.noKeyConfigured")
func openAIMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = MockKeyStore()  // no key set
    let provider = BYOKeyProvider(model: .openAI, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.openAI)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x"))
    }
}

// MARK: - Anthropic request body

@Test("Anthropic body carries model, max_tokens=8000, system field, user message, and prefill")
func anthropicRequestBody() async throws {
    let transport = MockHTTPTransport(responseData: anthropicSuccessData(text: #""day":1}"#))
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore,
                                  anthropicModel: "claude-opus-4-5", transport: transport)
    let request = AIRequest(
        feature: .weekGen,
        systemPrompt: "You are SimmerSmith.",
        prompt: "Plan 21 meals.",
        wantsStructuredJSON: true
    )
    _ = try await provider.generate(request)

    let body = try bodyJSON(from: transport)
    #expect(body["model"] as? String == "claude-opus-4-5")
    #expect((body["max_tokens"] as? Int) == 8000)
    #expect(body["system"] as? String == "You are SimmerSmith.")

    let messages = body["messages"] as? [[String: Any]]
    let userMsg = messages?.first(where: { $0["role"] as? String == "user" })
    let assistantMsg = messages?.first(where: { $0["role"] as? String == "assistant" })
    #expect(userMsg?["content"] as? String == "Plan 21 meals.")
    // prefill
    #expect(assistantMsg?["content"] as? String == "{")
}

@Test("Anthropic response text is re-prefixed with { when it doesn't already start with {")
func anthropicPrefillReattach() async throws {
    // Model returns just the continuation after the { prefill
    let transport = MockHTTPTransport(responseData: anthropicSuccessData(text: #""meals":[]}"#))
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    let response = try await provider.generate(
        AIRequest(feature: .weekGen, prompt: "go", wantsStructuredJSON: true)
    )
    #expect(response.text.hasPrefix("{"))
    #expect(response.text == #"{"meals":[]}"#)
}

@Test("Anthropic prefill is NOT double-prepended when model echoes { back")
func anthropicPrefillNotDoubled() async throws {
    // Some models echo the prefill token back in their response
    let transport = MockHTTPTransport(responseData: anthropicSuccessData(text: #"{"meals":[]}"#))
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-test", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    let response = try await provider.generate(
        AIRequest(feature: .weekGen, prompt: "go", wantsStructuredJSON: true)
    )
    // Must not be "{{…}"
    #expect(response.text == #"{"meals":[]}"#)
}

@Test("Anthropic 401 throws AIError.httpError")
func anthropic401() async {
    let transport = MockHTTPTransport(
        responseData: #"{"error":"auth"}"#.data(using: .utf8)!,
        responseStatus: 401
    )
    let keyStore = MockKeyStore()
    keyStore.setKey("ant-bad", for: "anthropic")
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.httpError(provider: "anthropic", statusCode: 401, body: #"{"error":"auth"}"#)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x"))
    }
}

@Test("Anthropic missing key throws AIError.noKeyConfigured")
func anthropicMissingKey() async {
    let transport = MockHTTPTransport(responseData: Data())
    let keyStore = MockKeyStore()  // no key set
    let provider = BYOKeyProvider(model: .anthropic, keyStore: keyStore, transport: transport)
    await #expect(throws: AIError.noKeyConfigured(.anthropic)) {
        _ = try await provider.generate(AIRequest(feature: .weekGen, prompt: "x"))
    }
}

// MARK: - Allergy gate projection test (C1 coverage)
//
// This test verifies the gate fires for a real allergy pref where baseIngredientName
// is populated — covering the C1 fix. The projection logic lives in PreferenceRepository
// (app layer, not in AIProviderKit), but the gate itself is in MealPlanParser here.
// We test the gate end-to-end with a populated allergen list to prove it fires.

@Test("allergy gate fires and fails closed for a populated allergen list from projection")
func allergyGateFiresWithProjectedNames() throws {
    // Simulate the allergies that WeekGenContextGatherer emits after C1 fix
    // (baseIngredientName now comes from the private-plane row).
    let projectedAllergies = ["peanut", "shellfish"]

    let violatingJSON = """
    {
      "recipes": [{
        "name": "Satay Skewers",
        "ingredients": [
          {"ingredient_name": "peanut sauce"},
          {"ingredient_name": "chicken"}
        ]
      }],
      "meal_plan": [{
        "day_name": "Monday", "meal_date": "2026-06-22",
        "slot": "dinner", "recipe_name": "Satay Skewers"
      }]
    }
    """
    let result = try MealPlanParser.parse(violatingJSON)
    #expect(throws: MealPlanParseError.allergyViolation(recipe: "Satay Skewers", allergen: "peanut")) {
        try MealPlanParser.enforceAllergyGate(result, allergies: projectedAllergies)
    }
}

@Test("allergy gate fails closed for a slot whose recipe_name matches nothing")
func allergyGateFailsClosedOnUnresolvedSlot() throws {
    // A slot references a recipe not in the recipes array — with allergens set, this
    // must throw (C2 fix: fail closed, not silently skip).
    let json = """
    {
      "recipes": [{"name": "Safe Salad", "ingredients": [{"ingredient_name": "lettuce"}]}],
      "meal_plan": [
        {"day_name": "Monday", "meal_date": "2026-06-22", "slot": "lunch",
         "recipe_name": "Mystery Shellfish Dish"}
      ]
    }
    """
    let result = try MealPlanParser.parse(json)
    let err = #expect(throws: (any Error).self) {
        try MealPlanParser.enforceAllergyGate(result, allergies: ["shellfish"])
    }
    guard let parseErr = err as? MealPlanParseError,
          case let .allergyViolation(recipe, allergen) = parseErr else {
        Issue.record("Expected allergyViolation, got \(String(describing: err))")
        return
    }
    #expect(recipe == "Mystery Shellfish Dish")
    #expect(allergen == "unknown")
}
