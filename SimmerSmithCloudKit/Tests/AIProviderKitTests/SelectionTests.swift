import Testing
@testable import AIProviderKit

// SP-A §7 AI seam: the routing policy + key store + client dispatch.

// MARK: - Router policy

@Test("light task prefers free on-device when available")
func lightPrefersOnDevice() {
    let r = ProviderRouter(onDeviceAvailable: true, byoKey: .openAI)
    #expect(r.tier(for: .substitution) == .onDevice)
}

@Test("heavy task defaults to cloud even when on-device is available (iOS 26)")
func heavyDefaultsCloud() {
    let r = ProviderRouter(onDeviceAvailable: true, byoKey: .anthropic)
    #expect(r.tier(for: .weekGen) == .cloudBYOKey(.anthropic))
}

@Test("heavy task uses credits when no BYO key")
func heavyUsesCredits() {
    let r = ProviderRouter(onDeviceAvailable: true, byoKey: nil, creditsAvailable: true)
    #expect(r.tier(for: .weekGen) == .creditsGateway)
}

@Test("heavy task on-device only when explicitly allowed (post-Spike-2)")
func heavyOnDeviceWhenAllowed() {
    let r = ProviderRouter(onDeviceAvailable: true, byoKey: nil,
                           creditsAvailable: false, allowOnDeviceHeavy: true)
    #expect(r.tier(for: .weekGen) == .onDevice)
}

@Test("no provider available returns nil")
func noneAvailable() {
    let r = ProviderRouter(onDeviceAvailable: false)
    #expect(r.tier(for: .substitution) == nil)
    #expect(r.tier(for: .weekGen) == nil)
}

@Test("light falls back to BYO key when on-device is unavailable")
func lightFallsBackToCloud() {
    let r = ProviderRouter(onDeviceAvailable: false, byoKey: .gemini)
    #expect(r.tier(for: .pairing) == .cloudBYOKey(.gemini))
}

// MARK: - Key store

@Test("in-memory key store round-trips and deletes")
func keyStoreRoundTrip() {
    let store = InMemoryKeyStore()
    #expect(store.key(for: "openai") == nil)
    store.setKey("sk-123", for: "openai")
    #expect(store.key(for: "openai") == "sk-123")
    store.setKey(nil, for: "openai")
    #expect(store.key(for: "openai") == nil)
}

// MARK: - Client dispatch

private struct FakeProvider: AIProvider {
    let tier: AITier
    func generate(_ request: AIRequest) async throws -> AIResponse {
        AIResponse(text: "ok", tier: tier)
    }
}

@Test("client dispatches to the router-resolved tier's provider")
func clientDispatchesToResolvedTier() async throws {
    let router = ProviderRouter(onDeviceAvailable: true, byoKey: .openAI)
    let client = AIClient(router: router) { tier in FakeProvider(tier: tier) }
    // light → on-device
    let light = try await client.generate(AIRequest(feature: .substitution, prompt: "x"))
    #expect(light.tier == .onDevice)
    // heavy → cloud BYO-key
    let heavy = try await client.generate(AIRequest(feature: .weekGen, prompt: "plan"))
    #expect(heavy.tier == .cloudBYOKey(.openAI))
}

@Test("client throws when no provider is available")
func clientThrowsNoProvider() async {
    let router = ProviderRouter(onDeviceAvailable: false)
    let client = AIClient(router: router) { tier in FakeProvider(tier: tier) }
    await #expect(throws: AIError.noProviderAvailable(.weekGen)) {
        try await client.generate(AIRequest(feature: .weekGen, prompt: "x"))
    }
}

@Test("real stub providers report not-wired-yet (SP-B fills them)")
func stubsNotWired() async {
    await #expect(throws: AIError.notWiredYet(.onDevice)) {
        try await OnDeviceProvider().generate(AIRequest(feature: .substitution, prompt: "x"))
    }
}
