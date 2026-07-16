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
            } else {
                let unsupportedFields = evidenceUnsupportedFields(entry)
                if !unsupportedFields.isEmpty {
                    errors.append(
                        "entries[\(index)].evidence: \"\(entry.evidence)\" does not support fields: \(unsupportedFields.joined(separator: ", "))"
                    )
                }
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

    private func evidenceUnsupportedFields(_ entry: WeeklyPlanWireEntry) -> [String] {
        var fields: [String] = []
        let evidence = lexicalText(entry.evidence)
        let evidenceCompact = compact(evidence)

        if !evidenceCompact.contains(compact(entry.day)) {
            fields.append("day")
        }

        let slot = compact(entry.slot)
        let slotForms = slot == "dinner" ? ["dinner", "diner"] : [slot]
        if !slotForms.contains(where: evidenceCompact.contains) {
            fields.append("slot")
        }

        let rawDish = compact(entry.rawDish)
        if !rawDish.isEmpty, !evidenceCompact.contains(rawDish) {
            fields.append("raw_dish")
        }

        let intent = domainValue(entry.intent)
        let words = Set(evidence.split(separator: " ").map(String.init))
        let eatOutMarkers = ["eatout", "takeout", "orderout", "orderingout", "restaurant", "pizza"]
        let hasEatOutMarker = eatOutMarkers.contains(where: evidenceCompact.contains)
            || (words.contains("at") && !rawDish.isEmpty && evidenceCompact.contains(rawDish))
        let intentIsSupported = switch intent {
        case "recipe":
            !hasEatOutMarker
                && !evidenceCompact.contains("leftover")
                && !evidenceCompact.contains("skip")
        case "eatout":
            hasEatOutMarker
        case "leftovers":
            evidenceCompact.contains("leftover")
        case "skip":
            evidenceCompact.contains("skip")
        default:
            true
        }
        if !intentIsSupported {
            fields.append("intent")
        }

        return fields
    }

    private func lexicalText(_ value: String) -> String {
        let words = value.lowercased().map { character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func compact(_ value: String) -> String {
        lexicalText(value).replacingOccurrences(of: " ", with: "")
    }
}
