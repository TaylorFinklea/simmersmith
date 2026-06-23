import Testing
@testable import AIProviderKit

// SP-C — AIModelCatalog: curation + merge for the Settings model dropdown.

// MARK: - OpenAI curation (filter non-chat + rank by preference)

@Test("openAI curation drops non-chat models")
func openAIDropsNonChat() {
    let raw = [
        "gpt-4o", "text-embedding-3-large", "whisper-1", "tts-1",
        "dall-e-3", "gpt-image-1", "omni-moderation-latest",
        "gpt-3.5-turbo-instruct", "gpt-realtime", "gpt-4o-transcribe",
        "babbage-002", "davinci-002", "gpt-4.1",
    ]
    let curated = AIModelCatalog.curatedModels(provider: "openai", rawIDs: raw)
    #expect(curated.contains("gpt-4o"))
    #expect(curated.contains("gpt-4.1"))
    #expect(!curated.contains("text-embedding-3-large"))
    #expect(!curated.contains("whisper-1"))
    #expect(!curated.contains("tts-1"))
    #expect(!curated.contains("dall-e-3"))
    #expect(!curated.contains("gpt-image-1"))
    #expect(!curated.contains("omni-moderation-latest"))
    #expect(!curated.contains("gpt-3.5-turbo-instruct"))
    #expect(!curated.contains("gpt-realtime"))
    #expect(!curated.contains("gpt-4o-transcribe"))
    #expect(!curated.contains("babbage-002"))
    #expect(!curated.contains("davinci-002"))
}

@Test("openAI curation keeps reasoning models (o3/o4)")
func openAIKeepsReasoning() {
    let curated = AIModelCatalog.curatedModels(provider: "openai", rawIDs: ["o3", "o4-mini", "gpt-4o"])
    #expect(curated.contains("o3"))
    #expect(curated.contains("o4-mini"))
}

@Test("openAI curation ranks preferred models first, unknown chat models after")
func openAIRanksPreferenceFirst() {
    // Includes an unknown-but-chat model that should land after the preferred ones.
    let raw = ["gpt-4o", "gpt-5.5", "gpt-9-future"]
    let curated = AIModelCatalog.curatedModels(provider: "openai", rawIDs: raw)
    // gpt-5.5 precedes gpt-4o in the preference list.
    let i55 = curated.firstIndex(of: "gpt-5.5")
    let i4o = curated.firstIndex(of: "gpt-4o")
    let iFuture = curated.firstIndex(of: "gpt-9-future")
    #expect(i55 != nil && i4o != nil && iFuture != nil)
    #expect(i55! < i4o!)
    #expect(i4o! < iFuture!)
}

@Test("openAI curation dedupes repeats")
func openAIDedupes() {
    let curated = AIModelCatalog.curatedModels(provider: "openai", rawIDs: ["gpt-4o", "gpt-4o", "gpt-4.1"])
    #expect(curated.filter { $0 == "gpt-4o" }.count == 1)
}

@Test("openAI curation returns empty when nothing survives")
func openAIEmptyWhenAllFiltered() {
    let curated = AIModelCatalog.curatedModels(provider: "openai", rawIDs: ["text-embedding-3-large", "whisper-1"])
    #expect(curated.isEmpty)
}

// MARK: - Anthropic curation

@Test("anthropic curation keeps only claude models, ranks preference first")
func anthropicCuration() {
    let raw = ["claude-sonnet-4-6", "claude-opus-4-5", "not-a-claude", "claude-future-7"]
    let curated = AIModelCatalog.curatedModels(provider: "anthropic", rawIDs: raw)
    #expect(!curated.contains("not-a-claude"))
    #expect(curated.contains("claude-future-7"))
    // opus-4-5 precedes sonnet-4-6 in the preference list.
    #expect(curated.firstIndex(of: "claude-opus-4-5")! < curated.firstIndex(of: "claude-sonnet-4-6")!)
    // Unknown claude model lands after the preferred ones.
    #expect(curated.firstIndex(of: "claude-sonnet-4-6")! < curated.firstIndex(of: "claude-future-7")!)
}

@Test("unknown provider curates to empty")
func unknownProviderEmpty() {
    #expect(AIModelCatalog.curatedModels(provider: "gemini", rawIDs: ["whatever"]).isEmpty)
}

// MARK: - displayOptions (merge + guarantees)

@Test("displayOptions uses fallback when available is empty")
func displayUsesFallback() {
    let opts = AIModelCatalog.displayOptions(provider: "openai", available: [], saved: "")
    #expect(opts == AIModelCatalog.openAIFallback)
}

@Test("displayOptions always contains the provider default")
func displayContainsDefault() {
    // A curated list that happens to omit the default still gets it appended.
    let opts = AIModelCatalog.displayOptions(provider: "openai", available: ["gpt-5.5", "gpt-4.1"], saved: "")
    #expect(opts.contains(AIModelCatalog.defaultOpenAIModel))
    let anth = AIModelCatalog.displayOptions(provider: "anthropic", available: ["claude-sonnet-4-6"], saved: "")
    #expect(anth.contains(AIModelCatalog.defaultAnthropicModel))
}

@Test("displayOptions includes a saved value already in the list without duplicating")
func displaySavedInList() {
    let opts = AIModelCatalog.displayOptions(provider: "openai", available: ["gpt-5.5", "gpt-4o"], saved: "gpt-5.5")
    #expect(opts.filter { $0 == "gpt-5.5" }.count == 1)
}

@Test("displayOptions surfaces a saved custom value at the front")
func displaySavedCustomFront() {
    let opts = AIModelCatalog.displayOptions(provider: "openai", available: ["gpt-5.5"], saved: "my-ft-model:1234")
    #expect(opts.first == "my-ft-model:1234")
    #expect(opts.contains("gpt-5.5"))
}

@Test("displayOptions trims and ignores blank saved")
func displayBlankSaved() {
    let opts = AIModelCatalog.displayOptions(provider: "anthropic", available: [], saved: "   ")
    #expect(opts == AIModelCatalog.anthropicFallback)
}

@Test("displayOptions produces no duplicates")
func displayNoDuplicates() {
    let opts = AIModelCatalog.displayOptions(
        provider: "openai",
        available: ["gpt-4o", "gpt-4o", "gpt-4.1"],
        saved: "gpt-4o"
    )
    #expect(Set(opts).count == opts.count)
}
