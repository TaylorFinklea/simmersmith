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
// Two layers of redaction:
//   1. Known-secret exact match (preferred) — call sites that hold the literal stored
//      key (BYOKeyProvider.checkHTTP, ImageGenProvider.checkImageHTTP,
//      URLSessionTransport.lines via the auth header) pass it through `knownSecrets`.
//      A future vendor whose key format doesn't match any shape pattern below
//      (dormant GLM/Kimi/MiniMax, or anything new) would otherwise leak when a 401
//      body echoes the raw key.
//   2. Shape-pattern fallback — common API-key schemes matched by prefix + run
//      length. Catches unknown keys that fit a known shape (OpenAI sk-…, Google
//      AIza…, bearer tokens in Authorization headers).
//
// Patterns covered (mirrors common API-key schemes):
//   sk-[A-Za-z0-9._-]{8,}   — OpenAI (sk-…, sk-proj-…, sk-svcacct-…)
//   AIza[A-Za-z0-9._-]{8,}  — Google / Gemini browser-facing keys
//   Bearer [A-Za-z0-9._~+/=-]{8,} — bearer tokens in Authorization headers
//
// The sanitizer is intentionally conservative: it matches only well-known prefixes
// so it never accidentally redact normal prose. The replacement keeps the prefix
// label ("sk-***", "AIza***", "Bearer ***") so error messages remain readable.
// Known secrets collapse to the opaque token "[REDACTED]" since their shape gives
// no useful diagnostic — the goal is just to keep the value out of the UI.

enum SecretSanitizer {
    /// Replace any exact occurrence of each entry in `knownSecrets` with
    /// "[REDACTED]", then apply the shape-pattern fallback (sk-…, AIza…, Bearer …)
    /// to whatever remains. Empty entries are skipped so a misconfigured caller
    /// can't blank the entire body. The function is pure (no side effects).
    ///
    /// - Parameter knownSecrets: literal secret values the caller holds
    ///   (e.g. the BYOKeyProvider's `key` for this request). Default `[]`
    ///   preserves the prior single-argument behaviour: shape patterns only.
    public static func redact(_ s: String, knownSecrets: [String] = []) -> String {
        var result = s
        // 1. Known secrets — exact match against each provided value.
        for secret in knownSecrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
        // 2. Shape-pattern fallback. Order matters: longer/more specific
        //    prefixes first so e.g. "sk-proj-…" matches before any bare "sk-…".
        let patterns: [(pattern: String, label: String)] = [
            ("sk-[A-Za-z0-9._\\-]{8,}", "sk-***"),
            ("AIza[A-Za-z0-9._\\-]{8,}", "AIza***"),
            // Bearer token: "Bearer " + base64url-ish run of ≥8 chars
            ("Bearer [A-Za-z0-9._~+/=\\-]{8,}", "Bearer ***"),
        ]
        for (raw, label) in patterns {
            guard let regex = try? NSRegularExpression(pattern: raw) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: label)
        }
        return result
    }
}
