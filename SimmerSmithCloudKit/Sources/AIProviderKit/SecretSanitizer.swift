import Foundation

// SP-C AI-4 review fix F1 — strip API-key-shaped tokens from error snippets before
// they reach AIError.imageGenFailed(detail:) or AIError.httpError(body:).
//
// OpenAI 401 bodies echo the submitted key:
//   "Incorrect API key provided: sk-proj-…"
// A suffix of that string can reach the UI via aiErrorMessage (AppState+AI.swift).
// The sanitizer replaces matching token prefixes with "sk-***" (or the appropriate
// scheme prefix) so the key is never surfaced to the user or written to logs.
//
// Patterns covered (mirrors common API-key schemes):
//   sk-[A-Za-z0-9._-]{8,}   — OpenAI (sk-…, sk-proj-…, sk-svcacct-…)
//   AIza[A-Za-z0-9._-]{8,}  — Google / Gemini browser-facing keys
//   Bearer [A-Za-z0-9._~+/=-]{8,} — bearer tokens in Authorization headers
//
// The sanitizer is intentionally conservative: it matches only well-known prefixes
// so it never accidentally redact normal prose. The replacement keeps the prefix
// label ("sk-***", "AIza***", "Bearer ***") so error messages remain readable.

enum SecretSanitizer {
    /// Replace API-key-shaped runs in `s` with their prefix + "***".
    /// Input and output are plain strings; the function is pure (no side effects).
    public static func redact(_ s: String) -> String {
        // Order matters: longer/more specific prefixes first.
        let patterns: [(pattern: String, label: String)] = [
            ("sk-[A-Za-z0-9._\\-]{8,}", "sk-***"),
            ("AIza[A-Za-z0-9._\\-]{8,}", "AIza***"),
            // Bearer token: "Bearer " + base64url-ish run of ≥8 chars
            ("Bearer [A-Za-z0-9._~+/=\\-]{8,}", "Bearer ***"),
        ]
        var result = s
        for (raw, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: raw) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: label)
        }
        return result
    }
}
