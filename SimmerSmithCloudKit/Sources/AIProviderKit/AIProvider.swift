import Foundation

/// The provider-agnostic AI seam (SP-A §7). One call site routes every AI feature
/// to a tier; the data plane never knows which model answered. SP-A builds the
/// seam + selection + key store; SP-B wires the real backends.

/// AI-backed features, tagged by reasoning weight so the router can default light
/// tasks on-device and heavy reasoning to the cloud.
public enum AIFeature: String, Sendable, CaseIterable {
    // light — strong on-device (first-gen FM on iOS 26; AFM 3 at GA)
    case substitution, pairing, difficulty, seasonal, normalization, companionDraft
    // heavy — cloud by default on iOS 26 (Spike 2 at GA decides if on-device clears it)
    case weekGen, assistantPlanning, recipeImage

    public var isHeavy: Bool {
        switch self {
        case .weekGen, .assistantPlanning, .recipeImage: return true
        default: return false
        }
    }
}

/// Where a request runs.
public enum AITier: Sendable, Equatable {
    case onDevice                      // Foundation Models (free, private)
    case cloudBYOKey(CloudModel)       // user's own key, called directly
    case creditsGateway                // optional SP-E server, our key + ledger
}

public enum CloudModel: Sendable, Equatable {
    case openAI, anthropic, gemini
    case openRouter(String)            // FOSS models by slug
}

public struct AIRequest: Sendable {
    public var feature: AIFeature
    /// For Anthropic: sent via the `system` field; for OpenAI: prepended as a
    /// `{"role": "system", ...}` message. Leave nil to use a single user message.
    public var systemPrompt: String?
    public var prompt: String
    public var wantsStructuredJSON: Bool
    public init(
        feature: AIFeature,
        systemPrompt: String? = nil,
        prompt: String,
        wantsStructuredJSON: Bool = false
    ) {
        self.feature = feature
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.wantsStructuredJSON = wantsStructuredJSON
    }
}

public struct AIResponse: Sendable, Equatable {
    public var text: String
    public var tier: AITier
    public init(text: String, tier: AITier) { self.text = text; self.tier = tier }
}

public enum AIError: Error, Equatable {
    case noProviderAvailable(AIFeature)
    case notWiredYet(AITier)           // SP-B fills the real backends
    /// The user has not configured a key for the given cloud model.
    case noKeyConfigured(CloudModel)
    /// The provider returned a non-200 HTTP status.
    case httpError(provider: String, statusCode: Int, body: String)
    /// The provider returned a 200 but the response shape was unexpected.
    case malformedResponse(String)
}

/// A backend that can answer a request at a given tier.
public protocol AIProvider: Sendable {
    var tier: AITier { get }
    func generate(_ request: AIRequest) async throws -> AIResponse
}
