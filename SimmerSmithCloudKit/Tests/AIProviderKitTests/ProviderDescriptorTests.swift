import Foundation
import Testing
@testable import AIProviderKit

// T2 — the ProviderDescriptor registry is the single source of truth for the
// directly-keyed open-model vendors. These lock the host/key/default/temperature/
// thinking-param facts the rest of the open-models path depends on.

@Test("descriptor(for:) returns the right host, key, and default for visible open-model vendors")
func descriptorBasics() {
    let ollama = ProviderRegistry.descriptor(for: .ollamaCloud)
    #expect(ollama.keychainKeyID == "ollama")
    #expect(ollama.chatURL == "https://ollama.com/v1/chat/completions")
    #expect(ollama.modelsURL == "https://ollama.com/v1/models")
    #expect(ollama.defaultModel == "glm-5.2")
    #expect(ollama.fallbackModels == ["glm-5.2", "kimi-k2.6", "minimax-m3"])
    #expect(ollama.reasoningStyle == .none)

    let nw = ProviderRegistry.descriptor(for: .neuralwatt)
    #expect(nw.keychainKeyID == "neuralwatt")
    #expect(nw.chatURL == "https://api.neuralwatt.com/v1/chat/completions")
    #expect(nw.modelsURL == "https://api.neuralwatt.com/v1/models")
    #expect(nw.defaultModel == "glm-5.2-short")
    #expect(nw.fallbackModels == ["glm-5.2", "glm-5.2-short", "glm-5.2-fast", "glm-5.2-short-fast", "kimi-k2.6", "kimi-k2.6-fast"])
    #expect(nw.reasoningStyle == .none)
}

@Test("Kimi tool-loop temperature is the hard 1.0; one-shot is 0.6")
func kimiTemperatureConstraints() {
    let kimi = ProviderRegistry.descriptor(for: .kimi)
    #expect(kimi.toolLoopTemperature == 1.0)
    #expect(kimi.oneShotTemperature == 0.6)
}

@Test("vendor(forKeychainID:) maps visible provider keychain ids and excludes hidden OpenRouter")
func keychainRoundTrip() {
    #expect(ProviderRegistry.vendor(forKeychainID: "ollama") == .ollamaCloud)
    #expect(ProviderRegistry.vendor(forKeychainID: "neuralwatt") == .neuralwatt)
    #expect(ProviderRegistry.vendor(forKeychainID: "openrouter") == nil)
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

@Test("visible open-model vendors are Ollama Cloud and NeuralWatt only")
func visibleOpenModelVendors() {
    #expect(ProviderRegistry.allOpenModelVendors == [.ollamaCloud, .neuralwatt])
    #expect(OpenModelVendor(rawValue: "ollama") == .ollamaCloud)
    #expect(OpenModelVendor(rawValue: "neuralwatt") == .neuralwatt)
    #expect(OpenModelVendor(rawValue: "openrouter") == .openRouter)
}
