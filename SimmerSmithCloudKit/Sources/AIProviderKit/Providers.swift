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

public struct BYOKeyProvider: AIProvider {
    public let tier: AITier
    private let model: CloudModel
    private let keyStore: KeyStore
    public init(model: CloudModel, keyStore: KeyStore) {
        self.tier = .cloudBYOKey(model); self.model = model; self.keyStore = keyStore
    }
    public func generate(_ request: AIRequest) async throws -> AIResponse {
        // SP-B: call the provider directly with the user's Keychain key.
        throw AIError.notWiredYet(tier)
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
