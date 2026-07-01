import Foundation
import Testing
@testable import AIProviderKit

// T2 — the ProviderDescriptor registry is the single source of truth for the
// directly-keyed open-model vendors. These lock the host/key/default/temperature/
// thinking-param facts the rest of the open-models path depends on.

@Test("descriptor(for:) returns the right host, key, and default per vendor")
func descriptorBasics() {
    let glm = ProviderRegistry.descriptor(for: .glm)
    #expect(glm.keychainKeyID == "zai")
    #expect(glm.chatURL == "https://api.z.ai/api/paas/v4/chat/completions")
    #expect(glm.defaultModel == "glm-5.2")
    #expect(glm.reasoningStyle == .reasoningContent)

    let kimi = ProviderRegistry.descriptor(for: .kimi)
    #expect(kimi.keychainKeyID == "moonshot")
    #expect(kimi.chatURL == "https://api.moonshot.ai/v1/chat/completions")
    #expect(kimi.defaultModel == "kimi-k2.6")

    let mm = ProviderRegistry.descriptor(for: .minimax)
    #expect(mm.keychainKeyID == "minimax")
    #expect(mm.chatURL == "https://api.minimax.io/v1/chat/completions")
    #expect(mm.defaultModel == "MiniMax-M3")
    #expect(mm.reasoningStyle == .reasoningDetails)
}

@Test("Kimi tool-loop temperature is the hard 1.0; one-shot is 0.6")
func kimiTemperatureConstraints() {
    let kimi = ProviderRegistry.descriptor(for: .kimi)
    #expect(kimi.toolLoopTemperature == 1.0)
    #expect(kimi.oneShotTemperature == 0.6)
}

@Test("vendor(forKeychainID:) round-trips the keychain id mapping")
func keychainRoundTrip() {
    #expect(ProviderRegistry.vendor(forKeychainID: "zai") == .glm)
    #expect(ProviderRegistry.vendor(forKeychainID: "moonshot") == .kimi)
    #expect(ProviderRegistry.vendor(forKeychainID: "minimax") == .minimax)
    #expect(ProviderRegistry.vendor(forKeychainID: "openai") == nil)
}

@Test("thinking-enabled vs disabled inject the right per-vendor params")
func thinkingParams() {
    func enabled(_ v: OpenModelVendor) -> [String: Any] {
        var body: [String: Any] = [:]
        ProviderRegistry.descriptor(for: v).applyThinkingEnabled(&body, ProviderRegistry.descriptor(for: v).defaultModel)
        return body
    }
    func disabled(_ v: OpenModelVendor) -> [String: Any] {
        var body: [String: Any] = [:]
        ProviderRegistry.descriptor(for: v).applyThinkingDisabled(&body, ProviderRegistry.descriptor(for: v).defaultModel)
        return body
    }

    // GLM: Preserved Thinking (clear_thinking:false) in the loop.
    let glmOn = enabled(.glm)["thinking"] as? [String: Any]
    #expect(glmOn?["type"] as? String == "enabled")
    #expect(glmOn?["clear_thinking"] as? Bool == false)

    // Kimi: keep:"all" in the loop.
    let kimiOn = enabled(.kimi)["thinking"] as? [String: Any]
    #expect(kimiOn?["type"] as? String == "enabled")
    #expect(kimiOn?["keep"] as? String == "all")

    // MiniMax: adaptive + reasoning_split.
    let mmOn = enabled(.minimax)
    #expect((mmOn["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect(mmOn["reasoning_split"] as? Bool == true)

    // The three direct vendors disable thinking cleanly.
    for v in [OpenModelVendor.glm, .kimi, .minimax] {
        #expect((disabled(v)["thinking"] as? [String: Any])?["type"] as? String == "disabled")
    }
    // OpenRouter injects NO thinking param either way — it normalizes reasoning itself,
    // so enabled/disabled are both no-ops (an unset body).
    #expect(enabled(.openRouter).isEmpty)
    #expect(disabled(.openRouter).isEmpty)
}

@Test("OpenRouter descriptor: one key, OpenAI-compatible URL, curated slugs, no live models list")
func openRouterDescriptor() {
    let or = ProviderRegistry.descriptor(for: .openRouter)
    #expect(or.keychainKeyID == "openrouter")
    #expect(or.chatURL == "https://openrouter.ai/api/v1/chat/completions")
    #expect(or.modelsURL == nil)              // nil → Test-Key uses a real chat probe
    #expect(or.reasoningStyle == .none)       // OpenRouter normalizes reasoning itself
    #expect(or.defaultModel == "z-ai/glm-4.6")
    #expect(or.fallbackModels.contains("z-ai/glm-4.6"))
    #expect(or.fallbackModels.contains("minimax/minimax-m3"))
    // The vendor round-trips through the keychain-id mapping like the direct vendors.
    #expect(ProviderRegistry.vendor(forKeychainID: "openrouter") == .openRouter)
    #expect(OpenModelVendor(rawValue: "openrouter") == .openRouter)
}
