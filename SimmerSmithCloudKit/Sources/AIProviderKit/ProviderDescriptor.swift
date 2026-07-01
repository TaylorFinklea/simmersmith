import Foundation

/// SP-C — the single source of truth for the directly-keyed open-model vendors
/// (GLM/Z.ai, Kimi/Moonshot, MiniMax). It replaces the hardcoded binary
/// openai/anthropic base-URL/key/model assumptions for the `.openModels` path: every
/// `.openModels` request looks up its descriptor here instead of branching on string
/// literals. OpenAI/Anthropic intentionally keep their existing dedicated methods.
///
/// All three vendors are driven on their OpenAI-compatible `/chat/completions`
/// surface with `Authorization: Bearer <key>` and OpenAI-shape `tools[]`/`tool_calls`.
/// They differ only in base URL, Keychain key, model id, the `thinking` parameter,
/// the reasoning field(s), and temperature — exactly what this descriptor captures.
public struct ProviderDescriptor: Sendable {
    public let vendor: OpenModelVendor
    /// Stable id ("glm" | "kimi" | "minimax"); equals `vendor.rawValue`.
    public let id: String
    public let displayName: String
    /// Keychain provider string ("zai" | "moonshot" | "minimax"). NOTE: this differs
    /// from `id` for GLM (zai) and Kimi (moonshot); for MiniMax it matches.
    public let keychainKeyID: String
    /// FULL OpenAI-compatible chat-completions URL (stored whole to avoid the GLM
    /// "append /v1 → 404" landmine).
    public let chatURL: String
    /// `/models` listing URL if the vendor supports it, else nil → static fallback only.
    public let modelsURL: String?
    public let defaultModel: String
    public let fallbackModels: [String]
    /// The reasoning capture/replay style expected in the tool loop.
    public let reasoningStyle: ReasoningStyle
    /// Mutates the request body to ENABLE thinking (tool loop) for this vendor/model.
    public let applyThinkingEnabled: @Sendable (_ body: inout [String: Any], _ model: String) -> Void
    /// Mutates the request body to DISABLE thinking (one-shot JSON) for this vendor/model.
    public let applyThinkingDisabled: @Sendable (_ body: inout [String: Any], _ model: String) -> Void
    /// Temperature for the multi-turn tool loop. Kimi HARD-requires 1.0 in thinking mode.
    public let toolLoopTemperature: Double
    /// Temperature for one-shot structured calls. Kimi HARD-requires 0.6 (non-thinking).
    public let oneShotTemperature: Double

    public init(
        vendor: OpenModelVendor,
        keychainKeyID: String,
        chatURL: String,
        modelsURL: String?,
        defaultModel: String,
        fallbackModels: [String],
        reasoningStyle: ReasoningStyle,
        toolLoopTemperature: Double,
        oneShotTemperature: Double,
        applyThinkingEnabled: @escaping @Sendable (_ body: inout [String: Any], _ model: String) -> Void,
        applyThinkingDisabled: @escaping @Sendable (_ body: inout [String: Any], _ model: String) -> Void
    ) {
        self.vendor = vendor
        self.id = vendor.rawValue
        self.displayName = vendor.displayName
        self.keychainKeyID = keychainKeyID
        self.chatURL = chatURL
        self.modelsURL = modelsURL
        self.defaultModel = defaultModel
        self.fallbackModels = fallbackModels
        self.reasoningStyle = reasoningStyle
        self.toolLoopTemperature = toolLoopTemperature
        self.oneShotTemperature = oneShotTemperature
        self.applyThinkingEnabled = applyThinkingEnabled
        self.applyThinkingDisabled = applyThinkingDisabled
    }
}

public enum ProviderRegistry {
    public static let allOpenModelVendors: [OpenModelVendor] = OpenModelVendor.allCases

    /// The descriptor for a vendor. Hosts are the INTERNATIONAL endpoints (api.z.ai /
    /// api.moonshot.ai / api.minimax.io); China-region hosts are out of scope (v1).
    public static func descriptor(for vendor: OpenModelVendor) -> ProviderDescriptor {
        switch vendor {
        case .glm:
            // GLM-5.2 (Z.ai). Preserved Thinking (clear_thinking:false) makes reasoning
            // replay mandatory — which the open-models encoder always honors.
            return ProviderDescriptor(
                vendor: .glm,
                keychainKeyID: "zai",
                chatURL: "https://api.z.ai/api/paas/v4/chat/completions",
                modelsURL: "https://api.z.ai/api/paas/v4/models",
                defaultModel: "glm-5.2",
                fallbackModels: ["glm-5.2", "glm-4.6", "glm-4.5-air"],
                reasoningStyle: .reasoningContent,
                toolLoopTemperature: 0.3,
                oneShotTemperature: 0.7,
                applyThinkingEnabled: { body, _ in
                    body["thinking"] = ["type": "enabled", "clear_thinking": false]
                },
                applyThinkingDisabled: { body, _ in
                    body["thinking"] = ["type": "disabled"]
                }
            )
        case .kimi:
            // Kimi-K2.6 (Moonshot). Thinking mode HARD-requires temperature 1.0; the
            // tool loop substitutes toolLoopTemperature regardless of the caller's value.
            return ProviderDescriptor(
                vendor: .kimi,
                keychainKeyID: "moonshot",
                chatURL: "https://api.moonshot.ai/v1/chat/completions",
                modelsURL: "https://api.moonshot.ai/v1/models",
                defaultModel: "kimi-k2.6",
                fallbackModels: ["kimi-k2.6"],
                reasoningStyle: .reasoningContent,
                toolLoopTemperature: 1.0,
                oneShotTemperature: 0.6,
                applyThinkingEnabled: { body, _ in
                    body["thinking"] = ["type": "enabled", "keep": "all"]
                },
                applyThinkingDisabled: { body, _ in
                    body["thinking"] = ["type": "disabled"]
                }
            )
        case .minimax:
            // MiniMax-M3. reasoning_split:true pulls reasoning OUT of content into
            // reasoning_content + reasoning_details (avoids the inline-<think>-in-JSON trap).
            // /models endpoint existence is MUST-VERIFY — kept; T4 probes/falls back.
            return ProviderDescriptor(
                vendor: .minimax,
                keychainKeyID: "minimax",
                chatURL: "https://api.minimax.io/v1/chat/completions",
                modelsURL: "https://api.minimax.io/v1/models",
                defaultModel: "MiniMax-M3",
                fallbackModels: ["MiniMax-M3"],
                reasoningStyle: .reasoningDetails,
                toolLoopTemperature: 0.3,
                oneShotTemperature: 0.7,
                applyThinkingEnabled: { body, _ in
                    body["thinking"] = ["type": "adaptive"]
                    body["reasoning_split"] = true
                },
                applyThinkingDisabled: { body, _ in
                    body["thinking"] = ["type": "disabled"]
                }
            )
        case .openRouter:
            // OpenRouter — OpenAI-compatible META-provider (one key, open models by slug).
            // It NORMALIZES reasoning across providers itself, so we send NO vendor-specific
            // `thinking` param (no-op) and DON'T capture/replay reasoning (reasoningStyle
            // .none) — a robust v1 pass-through. `modelsURL` is nil so the Test-Key button
            // validates via a real chat probe (also catching quota/model issues) and the
            // model dropdown shows the curated `fallbackModels` + a Custom… slot. Slugs
            // verified live against openrouter.ai/api/v1/models (2026-07-01).
            return ProviderDescriptor(
                vendor: .openRouter,
                keychainKeyID: "openrouter",
                chatURL: "https://openrouter.ai/api/v1/chat/completions",
                modelsURL: nil,
                defaultModel: "z-ai/glm-4.6",
                fallbackModels: [
                    "z-ai/glm-4.6",
                    "z-ai/glm-5",
                    "moonshotai/kimi-k2.6",
                    "moonshotai/kimi-k2-thinking",
                    "minimax/minimax-m3",
                    "deepseek/deepseek-v3.2",
                    "qwen/qwen3-235b-a22b-2507",
                    "meta-llama/llama-4-maverick",
                ],
                reasoningStyle: .none,
                toolLoopTemperature: 0.3,
                oneShotTemperature: 0.7,
                applyThinkingEnabled: { _, _ in },
                applyThinkingDisabled: { _, _ in }
            )
        }
    }

    /// Map a Keychain provider id back to its vendor ("zai" → .glm, "moonshot" → .kimi,
    /// "minimax" → .minimax). Nil for any non-open-model provider string.
    public static func vendor(forKeychainID id: String) -> OpenModelVendor? {
        allOpenModelVendors.first { descriptor(for: $0).keychainKeyID == id }
    }
}
