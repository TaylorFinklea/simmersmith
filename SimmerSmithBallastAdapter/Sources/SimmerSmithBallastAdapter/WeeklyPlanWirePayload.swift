import SimmerSmithKit

public struct WeeklyPlanWireEntry: Codable, Sendable, Equatable {
    public let day: String
    public let slot: String
    public let rawDish: String
    public let intent: String
    public let evidence: String

    public init(day: String, slot: String, rawDish: String, intent: String, evidence: String) {
        self.day = day
        self.slot = slot
        self.rawDish = rawDish
        self.intent = intent
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case day
        case slot
        case rawDish = "raw_dish"
        case intent
        case evidence
    }
}

public struct WeeklyPlanWirePayload: Codable, Sendable, Equatable {
    public let entries: [WeeklyPlanWireEntry]

    public init(entries: [WeeklyPlanWireEntry]) {
        self.entries = entries
    }

    public func toParsed() -> ParsedWeeklyPlan {
        ParsedWeeklyPlan(entries: entries.map { entry in
            ParsedMealEntry(
                day: entry.day,
                slot: entry.slot,
                rawDish: entry.rawDish,
                intent: MealIntent(parsing: entry.intent).rawValue
            )
        })
    }
}
