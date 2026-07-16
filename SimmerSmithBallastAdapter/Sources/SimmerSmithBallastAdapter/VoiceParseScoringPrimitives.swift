/// The 4-field meal identity every voice-parse scorer agrees on: day/slot/rawDish/intent,
/// normalized. Shared between the candidate scorer (`VoiceParseScorer`, which layers evidence on
/// top as a 5th field) and the production-cloud baseline scorer (`VoiceParseBaselineEval`, which
/// never sees evidence at all).
struct MealSignature: Hashable {
    let day: String
    let slot: String
    let rawDish: String
    let intent: String
}

/// Case/whitespace normalization plus multiset counting, factored out so both scorers compute
/// entry precision/recall/F1, unsupported-entry accounting, and exact-plan-match multiset
/// equality with byte-identical math.
enum VoiceParseScoringPrimitives {
    static func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func mealSignature(day: String, slot: String, rawDish: String, intent: String) -> MealSignature {
        MealSignature(
            day: normalize(day),
            slot: normalize(slot),
            rawDish: normalize(rawDish),
            intent: normalize(intent)
        )
    }

    static func counts<T: Hashable>(_ values: [T]) -> [T: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    static func intersectionCount<T: Hashable>(_ lhs: [T], _ rhs: [T]) -> Int {
        let left = counts(lhs)
        let right = counts(rhs)
        return left.reduce(into: 0) { total, pair in
            total += min(pair.value, right[pair.key, default: 0])
        }
    }

    static func ratio(
        _ numerator: Int,
        _ denominator: Int,
        emptyValue: Double = 0
    ) -> Double {
        denominator == 0 ? emptyValue : Double(numerator) / Double(denominator)
    }
}
