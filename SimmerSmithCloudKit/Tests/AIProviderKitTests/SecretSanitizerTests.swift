import Foundation
import Testing
@testable import AIProviderKit

// SP-C — SecretSanitizer known-secret layer (extends the F1 shape-pattern fix in
// ImageGenTests.swift). The shape-pattern layer only catches keys whose format
// matches a known prefix (sk-…, AIza…, Bearer …). A stored vendor key in a
// format that matches none of those — the dormant GLM/Kimi/MiniMax vendors, or
// anything new — would echo back in a 401 body and reach the UI unredacted.
// `redact(_:knownSecrets:)` adds a primary exact-match layer: the chokepoints
// that hold the literal key (BYOKeyProvider.checkHTTP, ImageGenProvider.checkImageHTTP,
// URLSessionTransport.lines via auth header) pass it through, and a 401 body
// that echoes the value verbatim is collapsed to "[REDACTED]". The shape-pattern
// layer still runs after as a fallback for keys the caller didn't enumerate.

// MARK: - Known-secret exact match

@Test("redact: a stored key in a non-sk format is redacted when passed as knownSecrets")
func redactKnownSecretNonSK() {
    // GLM/Kimi/MiniMax-style token: long opaque string, no scheme prefix the
    // shape-pattern layer would recognise. Without the knownSecrets layer it
    // would reach the UI unredacted.
    let key = "glm-1a2b3c4d5e6f7g8h9i0jklmnop"
    let body = "HTTP 401: invalid api_key \(key) for this account"
    let result = SecretSanitizer.redact(body, knownSecrets: [key])
    #expect(!result.contains(key))
    #expect(result.contains("[REDACTED]"))
    #expect(result.contains("HTTP 401: invalid api_key"))
    #expect(result.contains("for this account"))
}

@Test("redact: every occurrence of a known secret is collapsed, not just the first")
func redactKnownSecretMultipleOccurrences() {
    let key = "kimi-XYZ12345abcdef6789012345"
    let body = "echo: \(key) — again \(key) — done"
    let result = SecretSanitizer.redact(body, knownSecrets: [key])
    #expect(!result.contains(key))
    #expect(result.components(separatedBy: "[REDACTED]").count - 1 == 2)
}

@Test("redact: multiple known secrets are all redacted")
func redactMultipleKnownSecrets() {
    let k1 = "vendorA-token-zzzzzzzzzzzz"
    let k2 = "vendorB-token-yyyyyyyyyyyy"
    let body = "k1=\(k1) k2=\(k2)"
    let result = SecretSanitizer.redact(body, knownSecrets: [k1, k2])
    #expect(!result.contains(k1))
    #expect(!result.contains(k2))
    #expect(result == "k1=[REDACTED] k2=[REDACTED]")
}

// MARK: - Backward compatibility — shape-pattern layer still runs

@Test("redact: sk- key is redacted when passed as knownSecrets (exact match)")
func redactSKKeyAsKnownSecret() {
    let key = "sk-proj-ABC123xyz456789"
    let body = "Incorrect API key provided: \(key). Please check your key."
    let result = SecretSanitizer.redact(body, knownSecrets: [key])
    #expect(!result.contains(key))
    #expect(result.contains("[REDACTED]"))
    // The exact-match layer wins over the shape-pattern label; the body is
    // collapsed to [REDACTED] rather than the friendlier "sk-***" because the
    // caller explicitly identified the value.
    #expect(!result.contains("sk-***"))
    #expect(result.contains("Please check your key."))
}

@Test("redact: sk- key WITHOUT knownSecrets is still redacted by the shape-pattern layer")
func redactSKKeyShapePatternFallback() {
    // Mirrors the F1 tests in ImageGenTests.swift — confirms the existing
    // shape-pattern fallback is unaffected by the new knownSecrets layer.
    let body = "Incorrect API key provided: sk-proj-ABC123xyz456789. Please check your key."
    let result = SecretSanitizer.redact(body)
    #expect(!result.contains("sk-proj-ABC123xyz456789"))
    #expect(result.contains("sk-***"))
    #expect(result.contains("Please check your key."))
}

@Test("redact: AIza key is still redacted by the shape-pattern fallback")
func redactAIzaShapePatternFallback() {
    let body = "bad key AIza0987654321abcdefg here"
    let result = SecretSanitizer.redact(body)
    #expect(!result.contains("AIza0987654321abcdefg"))
    #expect(result.contains("AIza***"))
}

@Test("redact: Bearer token is still redacted by the shape-pattern fallback")
func redactBearerShapePatternFallback() {
    let body = "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 rejected"
    let result = SecretSanitizer.redact(body)
    #expect(!result.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
    #expect(result.contains("Bearer ***"))
}

// MARK: - Empty knownSecrets is identical to the old single-arg behaviour

@Test("redact: empty knownSecrets behaves exactly like the pre-change single-arg call")
func redactEmptyKnownSecretsEqualsOldBehaviour() {
    let body = "sk-proj-ABC123xyz456789 and AIza0987654321abcdefg and Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"
    let withEmpty = SecretSanitizer.redact(body, knownSecrets: [])
    let withDefault = SecretSanitizer.redact(body)
    #expect(withEmpty == withDefault)
    // Shape patterns fire: all three keys collapsed to their prefix labels.
    #expect(withEmpty.contains("sk-***"))
    #expect(withEmpty.contains("AIza***"))
    #expect(withEmpty.contains("Bearer ***"))
}

@Test("redact: empty entries in knownSecrets are skipped (don't blank the body)")
func redactEmptyKnownSecretEntries() {
    let body = "key=sk-proj-ABC123xyz456789 end"
    // A misconfigured caller passing "" would otherwise zero the entire body
    // via replacingOccurrences; the new design explicitly skips empties so the
    // shape-pattern layer still runs and the sk- key is collapsed normally.
    let result = SecretSanitizer.redact(body, knownSecrets: [""])
    #expect(!result.contains("sk-proj-ABC123xyz456789"))
    #expect(result.contains("sk-***"))
    #expect(result.contains("end"))
}

// MARK: - Clean text untouched

@Test("redact: clean prose with no keys is untouched, with or without knownSecrets")
func redactCleanProseUnchanged() {
    let body = "openai returned 500: internal server error — please try again later"
    #expect(SecretSanitizer.redact(body) == body)
    #expect(SecretSanitizer.redact(body, knownSecrets: ["any-token-12345678"]) == body)
    #expect(SecretSanitizer.redact(body, knownSecrets: []) == body)
}

@Test("redact: clean prose with non-key identifiers is untouched (no false positives)")
func redactCleanProseWithNonKeyStrings() {
    // 8+ char runs that AREN'T keys (no sk- / AIza / Bearer scheme) must NOT
    // be matched by the shape-pattern layer. The knownSecrets layer is the
    // only way to redact arbitrary vendor tokens.
    let body = "version 1.2.3-rc4 build abcdef1234567890"
    #expect(SecretSanitizer.redact(body) == body)
}

// MARK: - URLSessionTransport.authSecrets (the streaming chokepoint's wiring)

@Test("authSecrets: Authorization: Bearer <key> extracts the key")
func authSecretsBearer() {
    var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
    req.setValue("Bearer sk-proj-ABC123xyz456789", forHTTPHeaderField: "Authorization")
    #expect(URLSessionTransport.authSecrets(from: req) == ["sk-proj-ABC123xyz456789"])
}

@Test("authSecrets: lowercase 'bearer' scheme is recognised")
func authSecretsBearerLowercase() {
    var req = URLRequest(url: URL(string: "https://api.example.com/v1/chat")!)
    req.setValue("bearer vendor-token-zzzzzzzzzzzz", forHTTPHeaderField: "Authorization")
    #expect(URLSessionTransport.authSecrets(from: req) == ["vendor-token-zzzzzzzzzzzz"])
}

@Test("authSecrets: x-api-key header is extracted (Anthropic)")
func authSecretsXAPIKey() {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    req.setValue("sk-ant-api03-abcdefghijklmnop", forHTTPHeaderField: "x-api-key")
    #expect(URLSessionTransport.authSecrets(from: req) == ["sk-ant-api03-abcdefghijklmnop"])
}

@Test("authSecrets: x-goog-api-key header is extracted (Gemini)")
func authSecretsXGoogAPIKey() {
    var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1/models")!)
    req.setValue("AIzaSyAbcdefghijklmnop1234567890", forHTTPHeaderField: "x-goog-api-key")
    #expect(URLSessionTransport.authSecrets(from: req) == ["AIzaSyAbcdefghijklmnop1234567890"])
}

@Test("authSecrets: request with no auth headers returns empty")
func authSecretsNoHeaders() {
    let req = URLRequest(url: URL(string: "https://api.example.com/")!)
    #expect(URLSessionTransport.authSecrets(from: req) == [])
}

@Test("authSecrets: non-Bearer Authorization scheme is ignored")
func authSecretsIgnoresNonBearer() {
    // "Basic" is a common alternative scheme. The key wouldn't be a typical
    // vendor API key, so we deliberately don't treat it as one — the caller
    // can still pass it via knownSecrets if needed.
    var req = URLRequest(url: URL(string: "https://api.example.com/")!)
    req.setValue("Basic dXNlcjpwYXNz", forHTTPHeaderField: "Authorization")
    #expect(URLSessionTransport.authSecrets(from: req) == [])
}

@Test("authSecrets: empty Bearer token is ignored")
func authSecretsEmptyBearerToken() {
    var req = URLRequest(url: URL(string: "https://api.example.com/")!)
    req.setValue("Bearer ", forHTTPHeaderField: "Authorization")
    #expect(URLSessionTransport.authSecrets(from: req) == [])
}

// MARK: - End-to-end: chokepoint wiring via the streaming path

@Test("URLSessionTransport.authSecrets value flows through SecretSanitizer.redact")
func authSecretsFlowsIntoRedact() {
    // The line-74 streaming chokepoint pipes authSecrets into the known-secrets
    // layer. Verify the two work together: a 401 body that echoes a vendor token
    // in a non-sk format gets redacted when the request carried the same token
    // in its Authorization header.
    let key = "opaque-glm-token-aaaaaaaaaaaa"
    var req = URLRequest(url: URL(string: "https://api.example.com/v1/chat")!)
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let body = "401 Unauthorized: token \(key) rejected"
    let known = URLSessionTransport.authSecrets(from: req)
    let result = SecretSanitizer.redact(body, knownSecrets: known)
    #expect(!result.contains(key))
    #expect(result.contains("[REDACTED]"))
    #expect(result.contains("401 Unauthorized"))
    #expect(result.contains("rejected"))
}
