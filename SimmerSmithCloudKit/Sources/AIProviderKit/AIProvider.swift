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

/// One of the directly-keyed open-model vendors (SP-C). Each maps to its own
/// Keychain key + OpenAI-compatible base URL via `ProviderRegistry`.
public enum OpenModelVendor: String, Sendable, Equatable, CaseIterable {
    case glm, kimi, minimax
    /// OpenRouter — an OpenAI-compatible META-provider (one key, many open models by
    /// slug). Preferred entry point for open models; the direct GLM/Kimi/MiniMax vendors
    /// above stay in the code but are hidden from the picker. Explicit lowercase rawValue
    /// so `OpenModelVendor(rawValue:)` resolves the "openrouter" provider string.
    case openRouter = "openrouter"
    public var displayName: String {
        switch self {
        case .glm: return "GLM (Z.ai)"
        case .kimi: return "Kimi (Moonshot)"
        case .minimax: return "MiniMax"
        case .openRouter: return "OpenRouter"
        }
    }
}

public enum CloudModel: Sendable, Equatable {
    case openAI, anthropic, gemini
    case openRouter(String)            // FOSS models by slug
    case openModels(OpenModelVendor)   // SP-C open vendors (GLM/Kimi/MiniMax), direct keys

    /// A human-readable provider label for user-facing messages. Avoids leaking the raw
    /// enum reflection (e.g. "openModels(AIProviderKit.OpenModelVendor.glm)").
    public var label: String {
        switch self {
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        case .openRouter(let slug): return "OpenRouter (\(slug))"
        case .openModels(let vendor): return vendor.displayName
        }
    }
}

/// How a provider returns and replays model reasoning/thinking across a multi-turn
/// tool-use conversation. Captured verbatim, replayed verbatim — never reconstructed.
public enum ReasoningStyle: String, Sendable, Equatable {
    case none              // no reasoning captured / thinking disabled
    case reasoningContent  // GLM, Kimi: plaintext `reasoning_content` string is the whole state
    case reasoningDetails  // MiniMax split=true: `reasoning_content` + verbatim `reasoning_details`
    case signedBlock       // reserved: Anthropic-style block + signature (unused by the OSS vendors)
}

/// A vendor-agnostic carrier for one assistant turn's reasoning, threaded through the
/// tool loop so it can be re-emitted on the next request — vendors require the prior
/// turn's reasoning replayed within a single tool-call task (GLM Preserved Thinking,
/// Kimi thinking mode, MiniMax reasoning_split).
public struct ReasoningTrace: Sendable, Equatable {
    public var style: ReasoningStyle
    public var text: String?          // reasoning_content verbatim (GLM/Kimi/MiniMax)
    public var detailsJSON: String?   // MiniMax reasoning_details array re-encoded to a JSON string
    public var signature: String?     // signedBlock only; nil for the OSS vendors
    public init(style: ReasoningStyle = .none, text: String? = nil, detailsJSON: String? = nil, signature: String? = nil) {
        self.style = style
        self.text = text
        self.detailsJSON = detailsJSON
        self.signature = signature
    }
    /// True when there is nothing to replay (no style, or no captured payload).
    public var isEmpty: Bool {
        style == .none || ((text?.isEmpty ?? true) && (detailsJSON?.isEmpty ?? true))
    }
}

public struct AIRequest: Sendable {
    public var feature: AIFeature
    /// For Anthropic: sent via the `system` field; for OpenAI: prepended as a
    /// `{"role": "system", ...}` message. Leave nil to use a single user message.
    public var systemPrompt: String?
    public var prompt: String
    public var wantsStructuredJSON: Bool
    /// When true, the provider runs its built-in web-search tool instead of a plain
    /// chat completion (OpenAI Responses API `web_search`; Anthropic Messages
    /// `web_search_20250305`). Backs `searchRecipeOnWeb`. A provider/tier without the
    /// tool throws `AIError.webSearchUnsupported`. The structured-output prefill is
    /// suppressed in this mode (the tool loop is incompatible with it) — the prompt
    /// carries the JSON contract instead.
    public var wantsWebSearch: Bool
    public init(
        feature: AIFeature,
        systemPrompt: String? = nil,
        prompt: String,
        wantsStructuredJSON: Bool = false,
        wantsWebSearch: Bool = false
    ) {
        self.feature = feature
        self.systemPrompt = systemPrompt
        self.prompt = prompt
        self.wantsStructuredJSON = wantsStructuredJSON
        self.wantsWebSearch = wantsWebSearch
    }
}

public struct AIResponse: Sendable, Equatable {
    public var text: String
    public var tier: AITier
    /// Best-effort reasoning capture (telemetry / one-shot). NOT load-bearing — the
    /// tool-loop replay rides on `AIChatMessage.reasoning`, not here.
    public var reasoning: ReasoningTrace?
    public init(text: String, tier: AITier, reasoning: ReasoningTrace? = nil) {
        self.text = text
        self.tier = tier
        self.reasoning = reasoning
    }
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
    /// A web-search request was issued to a provider/model that can't run the
    /// built-in web-search tool (e.g. Gemini / OpenRouter in this build).
    case webSearchUnsupported(CloudModel)
    /// Image generation failed. `transient` is true for plausibly-retryable
    /// failures (5xx, 429, network-level errors) — the failover layer
    /// (AIService, AI-4) retries OpenAI→Gemini once when it's set and a Gemini
    /// key exists. Permanent failures (4xx/auth/content-policy, malformed
    /// response) carry `transient == false` and surface as-is. Ports the
    /// `RecipeImageTransientError` vs `RecipeImageError` split in
    /// `app/services/recipe_image_ai.py`.
    case imageGenFailed(provider: String, transient: Bool, detail: String)
}

extension AIError: LocalizedError {
    /// A human-readable message. WITHOUT this, the default Error description is the
    /// useless "(AIProviderKit.AIError error N.)" — which hides the HTTP status + body
    /// (case `.httpError`) that say WHY a call failed. Surfaced by the assistant tools,
    /// the app error banner, and logs.
    public var errorDescription: String? {
        switch self {
        case .noProviderAvailable(let feature):
            return "No AI provider is available for \(feature)."
        case .notWiredYet(let tier):
            return "That AI path isn't available yet (\(tier))."
        case .noKeyConfigured(let model):
            return "No API key is set for \(model.label). Add one in Settings → AI."
        case .httpError(let provider, let code, let body):
            let name = provider.capitalized
            if code == 401 {
                return "\(name) rejected the API key (401). Check your key in Settings → AI."
            }
            if code == 429 {
                return "\(name) is rate-limiting requests (429). Try again in a moment."
            }
            let reason = Self.providerErrorReason(from: body)
            let base = "\(name) returned HTTP \(code)."
            return reason.isEmpty ? base : "\(base) \(reason)"
        case .malformedResponse(let provider):
            return "\(provider.capitalized) returned an unexpected response."
        case .webSearchUnsupported(let model):
            return "Web search isn't available for \(model.label). Switch to a web-search-capable provider (OpenAI or Anthropic) in Settings → AI."
        case .imageGenFailed(let provider, _, let detail):
            return "\(provider.capitalized) image generation failed: \(detail)"
        }
    }

    /// Pull the human `error.message` out of an OpenAI/Anthropic JSON error body
    /// (`{"error":{"message":…}}`), else a trimmed snippet of the raw body.
    private static func providerErrorReason(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String,
           !message.isEmpty {
            return message.count > 240 ? String(message.prefix(240)) + "…" : message
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "(no body)" { return "" }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
    }
}

/// A backend that can answer a request at a given tier.
public protocol AIProvider: Sendable {
    var tier: AITier { get }
    func generate(_ request: AIRequest) async throws -> AIResponse
}
