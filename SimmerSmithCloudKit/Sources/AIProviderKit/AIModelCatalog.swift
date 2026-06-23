import Foundation

// SP-C — AIModelCatalog: the pure, headless-testable core behind the Settings
// "Model" dropdown. The old free-text model field is replaced by a Picker whose
// options come from one of two sources:
//
//   1. LIVE  — `BYOKeyProvider.listModels()` (the provider's `/v1/models`), so the
//              list reflects exactly what the user's key can call. OpenAI's endpoint
//              returns every model (embeddings, audio, image, moderation…), so the
//              raw IDs are filtered to chat-capable text models and sorted so the
//              best/newest float to the top. Anthropic returns a clean Claude list.
//   2. FALLBACK — a small curated static list per provider, used before the fetch
//                 returns, when no key is configured yet, or when the fetch fails.
//
// `displayOptions` then guarantees the provider default and the currently-saved
// value are always present so the Picker never renders blank, and the UI layer
// adds a trailing "Custom…" row for brand-new models the catalog doesn't know.
//
// Pure value logic only — no networking, no Keychain — so it unit-tests headlessly.
public enum AIModelCatalog {

    // MARK: - Defaults (must match BYOKeyProvider / AIService.resolveConfiguration)

    public static let defaultOpenAIModel = "gpt-4o"
    public static let defaultAnthropicModel = "claude-opus-4-5"

    public static func defaultModel(for provider: String) -> String {
        switch provider.lowercased() {
        case "anthropic": return defaultAnthropicModel
        default: return defaultOpenAIModel
        }
    }

    // MARK: - Fallback lists (curated, ordered best-first)

    /// Used until the live list returns, or when there's no key / the fetch fails.
    /// The live `/v1/models` list is preferred whenever available — these are only a
    /// reasonable offline default, and "Custom…" covers anything missing.
    public static let openAIFallback: [String] = [
        "gpt-5.5", "gpt-5.5-mini",
        "gpt-5.4", "gpt-5.4-mini",
        "gpt-5", "gpt-5-mini",
        "gpt-4.1", "gpt-4.1-mini",
        "gpt-4o", "gpt-4o-mini",
        "o3", "o4-mini",
    ]

    public static let anthropicFallback: [String] = [
        "claude-opus-4-5",
        "claude-sonnet-4-6",
        "claude-haiku-4-5",
        "claude-opus-4-1",
        "claude-3-7-sonnet-latest",
        "claude-3-5-sonnet-latest",
    ]

    public static func fallback(for provider: String) -> [String] {
        switch provider.lowercased() {
        case "anthropic": return anthropicFallback
        default: return openAIFallback
        }
    }

    // MARK: - Curation of a raw /v1/models response

    /// Filter + sort a raw list of provider model IDs into a chat-capable,
    /// best-first list. Returns `[]` for unknown providers or when nothing
    /// survives filtering (callers then fall back to the static list).
    public static func curatedModels(provider: String, rawIDs: [String]) -> [String] {
        switch provider.lowercased() {
        case "openai": return curateOpenAI(rawIDs)
        case "anthropic": return curateAnthropic(rawIDs)
        default: return []
        }
    }

    /// Substrings that mark an OpenAI model ID as NOT a text-chat model.
    private static let openAINonChatMarkers: [String] = [
        "embedding", "whisper", "tts", "audio", "image", "dall-e", "dalle",
        "moderation", "realtime", "transcribe", "search", "babbage", "davinci",
        "ada", "curie", "instruct", "codex", "computer-use", "guard",
    ]

    /// Prefixes that mark an OpenAI model ID as a text-chat / reasoning model.
    private static let openAIChatPrefixes: [String] = ["gpt-", "o1", "o3", "o4", "chatgpt"]

    private static func curateOpenAI(_ rawIDs: [String]) -> [String] {
        let chat = rawIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { id in
                guard !id.isEmpty else { return false }
                let lower = id.lowercased()
                guard openAIChatPrefixes.contains(where: { lower.hasPrefix($0) }) else { return false }
                return !openAINonChatMarkers.contains(where: { lower.contains($0) })
            }
        return rankByPreference(chat, preference: openAIFallback)
    }

    private static func curateAnthropic(_ rawIDs: [String]) -> [String] {
        let chat = rawIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased().hasPrefix("claude") }
        return rankByPreference(chat, preference: anthropicFallback)
    }

    /// Stable ordering: IDs that appear in `preference` come first in preference
    /// order; everything else keeps its original (API) order afterwards. Dedupes.
    private static func rankByPreference(_ ids: [String], preference: [String]) -> [String] {
        var seen = Set<String>()
        var preferred: [String] = []
        for p in preference where ids.contains(p) && !seen.contains(p) {
            seen.insert(p)
            preferred.append(p)
        }
        var rest: [String] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            rest.append(id)
        }
        return preferred + rest
    }

    // MARK: - Final option list for the Picker

    /// Build the option list the Picker renders. `available` is the curated live
    /// list (or `[]` if not fetched yet); when empty the static fallback is used.
    /// The provider default and the saved value are always included so the Picker
    /// selection is never absent. A saved value not already present is placed first
    /// (so a previously-typed custom model stays visible and selected).
    public static func displayOptions(provider: String, available: [String], saved: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []

        func add(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t) else { return }
            seen.insert(t)
            out.append(t)
        }

        let base = available.isEmpty ? fallback(for: provider) : available
        for m in base { add(m) }
        add(defaultModel(for: provider))

        let savedTrimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        if !savedTrimmed.isEmpty, !seen.contains(savedTrimmed) {
            out.insert(savedTrimmed, at: 0)
            seen.insert(savedTrimmed)
        }
        return out
    }
}
