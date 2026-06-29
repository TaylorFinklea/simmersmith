import Foundation

// SP-C voice week-planning — the canonical, plain (no-FoundationModels) structured plan that
// the resolver, the cloud-parse JSON, and the tests all use. The app target's @Generable
// adapter (the on-device model's output type) maps into THIS type, so there is one tested
// resolve path. Lives in SimmerSmithKit so the date-math + matching logic is host-testable
// via `swift test` (the critique's UTC-offset landmine deserves a runnable test, not just a
// compile check).

public enum MealIntent: String, Codable, Sendable, CaseIterable {
    case recipe, eatOut, leftovers, skip

    /// Tolerant parse from the model's free string — unknown/garbled → `.recipe` so a stray
    /// intent never silently drops the meal.
    public init(parsing raw: String) {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self = MealIntent(rawValue: normalized)
            ?? MealIntent.allCases.first { $0.rawValue.caseInsensitiveCompare(normalized) == .orderedSame }
            ?? .recipe
    }
}

public struct ParsedMealEntry: Codable, Sendable, Equatable {
    public let day: String        // "Monday"…"Sunday" or "today"/"tomorrow"/"tonight"
    public let slot: String       // breakfast | lunch | dinner
    public let rawDish: String    // dish exactly as spoken
    public let intent: String     // recipe | eatOut | leftovers | skip

    public init(day: String, slot: String, rawDish: String, intent: String) {
        self.day = day
        self.slot = slot
        self.rawDish = rawDish
        self.intent = intent
    }
}

public struct ParsedWeeklyPlan: Codable, Sendable, Equatable {
    public let entries: [ParsedMealEntry]
    public init(entries: [ParsedMealEntry]) { self.entries = entries }
}
