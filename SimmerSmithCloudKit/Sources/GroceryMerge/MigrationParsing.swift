import Foundation

// SP-A Phase 7 (migration tooling) — parse a legacy free-text quantity (prod `quantity_text`)
// into a numeric value during the Postgres→CloudKit import. Pure → unit-tested headlessly.
// (Winner of the 5-model head-to-head parse task — kimi-k2.7-code's clean, edge-correct port —
// see model-scorecard.md 2026-06-16.)
public func parseQuantity(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }

    func parseNonNegativeInteger(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        for c in s { guard c.isASCII && c >= "0" && c <= "9" else { return nil } }
        return Int(s)
    }

    func parseDecimal(_ s: String) -> Double? {
        var sawDot = false
        var hasDigit = false
        for c in s {
            if c == "." {
                if sawDot { return nil }
                sawDot = true
            } else if c.isASCII && c >= "0" && c <= "9" {
                hasDigit = true
            } else {
                return nil
            }
        }
        guard hasDigit else { return nil }
        return Double(s)
    }

    if !trimmed.contains("/") {
        return parseDecimal(trimmed)
    }

    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)

    if parts.count == 1 {
        let fracParts = String(parts[0]).split(separator: "/")
        guard fracParts.count == 2,
              let num = parseNonNegativeInteger(String(fracParts[0])),
              let den = parseNonNegativeInteger(String(fracParts[1])),
              den != 0 else { return nil }
        return Double(num) / Double(den)
    }

    if parts.count == 2 {
        guard let whole = parseNonNegativeInteger(String(parts[0])) else { return nil }
        let fracParts = String(parts[1]).split(separator: "/")
        guard fracParts.count == 2,
              let num = parseNonNegativeInteger(String(fracParts[0])),
              let den = parseNonNegativeInteger(String(fracParts[1])),
              den != 0 else { return nil }
        return Double(whole) + Double(num) / Double(den)
    }

    return nil
}
