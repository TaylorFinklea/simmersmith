import Testing
@testable import AIProviderKit

// SP-C — AIError now conforms to LocalizedError so failures surface the real reason
// (status + provider error body) instead of "(AIProviderKit.AIError error N.)".

@Test("httpError surfaces provider + status, not 'error 3'")
func httpErrorBasic() {
    let e = AIError.httpError(provider: "openai", statusCode: 500, body: "(no body)")
    #expect(e.errorDescription == "Openai returned HTTP 500.")
    #expect(!(e.errorDescription ?? "").contains("error 3"))
}

@Test("httpError extracts the provider error.message from a JSON body")
func httpErrorJSONReason() {
    let body = #"{"error":{"message":"Invalid value: 'response_format' of type 'json_object' is not supported with this model.","type":"invalid_request_error"}}"#
    let e = AIError.httpError(provider: "openai", statusCode: 400, body: body)
    let desc = e.errorDescription ?? ""
    #expect(desc.contains("HTTP 400"))
    #expect(desc.contains("response_format"))
}

@Test("401 and 429 get actionable messages")
func httpAuthAndRateLimit() {
    let unauth = AIError.httpError(provider: "anthropic", statusCode: 401, body: "")
    #expect((unauth.errorDescription ?? "").contains("key"))
    let rate = AIError.httpError(provider: "openai", statusCode: 429, body: "")
    #expect((rate.errorDescription ?? "").contains("rate-limiting"))
}

@Test("noKeyConfigured and malformedResponse are human-readable")
func otherCases() {
    #expect((AIError.noKeyConfigured(.openAI).errorDescription ?? "").contains("API key"))
    #expect((AIError.malformedResponse("openai").errorDescription ?? "").contains("unexpected"))
}

@Test("a long error body is truncated")
func longBodyTruncates() {
    let long = String(repeating: "x", count: 1000)
    let e = AIError.httpError(provider: "openai", statusCode: 400, body: long)
    #expect((e.errorDescription ?? "").count < 300)
}

@Test("stripCodeFence unwraps fenced JSON and leaves raw JSON untouched")
func stripFence() {
    #expect(BYOKeyProvider.stripCodeFence("```json\n{\"a\":1}\n```") == "{\"a\":1}")
    #expect(BYOKeyProvider.stripCodeFence("```\n{\"a\":1}\n```") == "{\"a\":1}")
    #expect(BYOKeyProvider.stripCodeFence("{\"a\":1}") == "{\"a\":1}")
    #expect(BYOKeyProvider.stripCodeFence("  {\"a\":1}  ") == "{\"a\":1}")
}
