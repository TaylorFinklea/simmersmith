import Testing
@testable import GroceryMerge

// SP-A Phase 7 — HARDER 5-model head-to-head: parseQuantity (mixed numbers, fractions,
// division-by-zero, negatives, whitespace). qwen3.7-max produced NO code under --no-tools
// (tried to grep the repo) → excluded here, scored a reliability failure. The 4 that returned
// code are run against the same hidden cases. Scores in ~/.claude/model-scorecard.md.

private func firstFailure(_ parse: (String) -> Double?) -> String? {
    let cases: [(String, Double?)] = [
        ("2", 2), ("1.5", 1.5), ("0.25", 0.25), ("10", 10), ("  2  ", 2),
        ("1 1/2", 1.5), ("1 3/4", 1.75), ("1   1/2", 1.5),
        ("3/4", 0.75), ("1/2", 0.5), ("10/4", 2.5),
        ("1/0", nil), ("1 1/0", nil),
        ("", nil), ("   ", nil), ("to taste", nil), ("abc", nil),
        ("1/2/3", nil), ("-1", nil), ("1.5/2", nil),
    ]
    for (input, expected) in cases {
        if parse(input) != expected { return "\(input.debugDescription) → \(String(describing: parse(input))) expected \(String(describing: expected))" }
    }
    return nil
}

@Test func parse_canonical() { #expect(firstFailure(parseQuantity) == nil) }
@Test func parse_sonnet()   { #expect(firstFailure(parseQuantity_sonnet)  == nil) }
@Test func parse_haiku()    { let f = firstFailure(parseQuantity_haiku); print("HAIKU:", f ?? "PASS"); #expect(f != nil) }   // expected to FAIL (accepts -1)
@Test func parse_minimax()  { #expect(firstFailure(parseQuantity_minimax) == nil) }
@Test func parse_kimi()     { #expect(firstFailure(parseQuantity_kimi)    == nil) }

// ===== verbatim model submissions (renamed) =====

private func parseQuantity_sonnet(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    func parseNonNegativeInt(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(s)
    }
    func parseFraction(_ s: String) -> Double? {
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        guard let num = parseNonNegativeInt(String(parts[0])),
              let den = parseNonNegativeInt(String(parts[1])) else { return nil }
        guard den != 0 else { return nil }
        return Double(num) / Double(den)
    }
    if !trimmed.contains("/") {
        guard let value = Double(trimmed), value >= 0 else { return nil }
        let validChars = trimmed.allSatisfy({ $0.isNumber || $0 == "." })
        guard validChars else { return nil }
        let dotCount = trimmed.filter({ $0 == "." }).count
        guard dotCount <= 1 else { return nil }
        return value
    }
    let components = trimmed.components(separatedBy: .whitespaces).filter({ !$0.isEmpty })
    if components.count == 1 {
        let s = components[0]
        guard s.filter({ $0 == "/" }).count == 1 else { return nil }
        return parseFraction(s)
    } else if components.count == 2 {
        guard let whole = parseNonNegativeInt(components[0]) else { return nil }
        guard components[1].filter({ $0 == "/" }).count == 1 else { return nil }
        guard let frac = parseFraction(components[1]) else { return nil }
        return Double(whole) + frac
    } else {
        return nil
    }
}

private func parseQuantity_haiku(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if let value = Double(trimmed) { return value }
    let components = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if components.count >= 2 {
        let lastComponent = components.last!
        if lastComponent.contains("/") {
            let fractionParts = lastComponent.split(separator: "/").map(String.init)
            if fractionParts.count == 2, let numerator = UInt(fractionParts[0]),
               let denominator = UInt(fractionParts[1]), denominator != 0 {
                let wholeStr = components.dropLast().joined(separator: " ")
                if let whole = Double(wholeStr) {
                    return whole + Double(numerator) / Double(denominator)
                }
            }
        }
    }
    let fractionParts = trimmed.split(separator: "/").map(String.init)
    if fractionParts.count == 2 {
        if let numerator = UInt(fractionParts[0]), let denominator = UInt(fractionParts[1]), denominator != 0 {
            return Double(numerator) / Double(denominator)
        }
    }
    return nil
}

private func parseQuantity_minimax(_ text: String) -> Double? {
    func isAllDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0 >= "0" && $0 <= "9" } }
    func isPlainDecimal(_ s: String) -> Bool {
        if s.isEmpty { return false }
        var dotSeen = false
        for c in s {
            if c == "." { if dotSeen { return false }; dotSeen = true }
            else if c < "0" || c > "9" { return false }
        }
        return true
    }
    func parseFraction(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        var slashIndex: String.Index?
        var slashCount = 0
        for i in s.indices where s[i] == "/" { slashIndex = i; slashCount += 1 }
        guard slashCount == 1, let si = slashIndex else { return nil }
        let numStr = String(s[..<si]); let denStr = String(s[s.index(after: si)...])
        guard !numStr.isEmpty, !denStr.isEmpty, isAllDigits(numStr), isAllDigits(denStr) else { return nil }
        guard let den = Int(denStr), den != 0, let num = Int(numStr) else { return nil }
        return Double(num) / Double(den)
    }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if let firstSpace = trimmed.firstIndex(of: " ") {
        let wholePart = String(trimmed[..<firstSpace])
        let rest = String(trimmed[trimmed.index(after: firstSpace)...])
        if isAllDigits(wholePart) {
            var idx = rest.startIndex
            while idx < rest.endIndex, rest[idx] == " " { idx = rest.index(after: idx) }
            let fractionPart = String(rest[idx...])
            if let fracValue = parseFraction(fractionPart) { return Double(wholePart)! + fracValue }
        }
    }
    if let fracValue = parseFraction(trimmed) { return fracValue }
    if isPlainDecimal(trimmed) { return Double(trimmed) }
    return nil
}

private func parseQuantity_kimi(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    func parseNonNegativeInteger(_ s: String) -> Int? {
        guard !s.isEmpty else { return nil }
        for c in s { guard c.isASCII && c >= "0" && c <= "9" else { return nil } }
        return Int(s)
    }
    func parseDecimal(_ s: String) -> Double? {
        var sawDot = false; var hasDigit = false
        for c in s {
            if c == "." { if sawDot { return nil }; sawDot = true }
            else if c.isASCII && c >= "0" && c <= "9" { hasDigit = true }
            else { return nil }
        }
        guard hasDigit else { return nil }
        return Double(s)
    }
    if !trimmed.contains("/") { return parseDecimal(trimmed) }
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
    if parts.count == 1 {
        let fracParts = String(parts[0]).split(separator: "/")
        guard fracParts.count == 2, let num = parseNonNegativeInteger(String(fracParts[0])),
              let den = parseNonNegativeInteger(String(fracParts[1])), den != 0 else { return nil }
        return Double(num) / Double(den)
    }
    if parts.count == 2 {
        guard let whole = parseNonNegativeInteger(String(parts[0])) else { return nil }
        let fracParts = String(parts[1]).split(separator: "/")
        guard fracParts.count == 2, let num = parseNonNegativeInteger(String(fracParts[0])),
              let den = parseNonNegativeInteger(String(fracParts[1])), den != 0 else { return nil }
        return Double(whole) + Double(num) / Double(den)
    }
    return nil
}
