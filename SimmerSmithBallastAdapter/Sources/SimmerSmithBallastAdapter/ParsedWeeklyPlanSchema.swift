import BallastCore
import Foundation

public struct ParsedWeeklyPlanSchema: StructuredSchema {
    public typealias Value = WeeklyPlanWirePayload

    private static let validDays = Set([
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "today", "tomorrow", "tonight",
    ])
    private static let validSlots = Set(["breakfast", "lunch", "dinner"])
    private static let validIntents = Set(["recipe", "eatout", "leftovers", "skip"])

    private let transcript: String

    public init(transcript: String) {
        self.transcript = transcript
    }

    public func decode(_ text: String) throws -> WeeklyPlanWirePayload {
        do {
            return try JSONDecoder().decode(WeeklyPlanWirePayload.self, from: Data(text.utf8))
        } catch {
            throw BallastError.parsing(raw: text, detail: String(describing: error))
        }
    }

    public func validate(_ value: WeeklyPlanWirePayload) -> [String] {
        var errors: [String] = []
        var firstEntryBySlot: [String: Int] = [:]
        let normalizedTranscript = groundednessText(transcript)

        for (index, entry) in value.entries.enumerated() {
            let day = domainValue(entry.day)
            let slot = domainValue(entry.slot)
            let intent = domainValue(entry.intent)

            if !Self.validDays.contains(day) {
                errors.append("entries[\(index)].day: \"\(entry.day)\" is invalid")
            }
            if !Self.validSlots.contains(slot) {
                errors.append("entries[\(index)].slot: \"\(entry.slot)\" is invalid")
            }
            if !Self.validIntents.contains(intent) {
                errors.append("entries[\(index)].intent: \"\(entry.intent)\" is invalid")
            }

            if (intent == "recipe" || intent == "leftovers"),
               entry.rawDish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("entries[\(index)].raw_dish: must be non-empty for intent \"\(entry.intent)\"")
            }

            let evidence = groundednessText(entry.evidence)
            if evidence.isEmpty || !normalizedTranscript.contains(evidence) {
                errors.append(
                    "entries[\(index)].evidence: \"\(entry.evidence)\" is not a non-empty literal span in the transcript"
                )
            }

            let slotKey = "\(day)|\(slot)"
            if let firstIndex = firstEntryBySlot[slotKey] {
                errors.append(
                    "entries[\(index)].day/slot duplicates entries[\(firstIndex)] for \"\(entry.day)\"/\"\(entry.slot)\""
                )
            } else {
                firstEntryBySlot[slotKey] = index
            }
        }

        return errors
    }

    public func repairHint(for errors: [String]) -> String {
        """
        Fix only the named invalid fields, and remove entries whose evidence is not literally present in the transcript. Problems: \(errors.joined(separator: "; ")). One valid example: {"entries":[{"day":"Tuesday","slot":"lunch","raw_dish":"tuna salad","intent":"recipe","evidence":"Tuesday lunch tuna salad"}]}
        """
    }

    private func domainValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func groundednessText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}
