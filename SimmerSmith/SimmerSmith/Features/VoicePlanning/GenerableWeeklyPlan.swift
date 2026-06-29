import Foundation
import SimmerSmithKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// SP-C voice week-planning — the on-device model's OUTPUT type. @Generable so Foundation
// Models produces it via constrained decoding; immediately mapped to the canonical, tested
// SimmerSmithKit.ParsedWeeklyPlan that the resolver consumes (one tested resolve path; this
// struct is just the model adapter). All-String properties: @Generable supports String
// natively without a per-property @Guide, and the prompt guides the values.

#if canImport(FoundationModels)

@Generable(description: "One meal assigned to a specific day and slot")
struct GenerableMealEntry: Equatable {
    /// "Monday"…"Sunday", or relative "today"/"tomorrow"/"tonight".
    let day: String
    /// "breakfast" | "lunch" | "dinner".
    let slot: String
    /// The dish exactly as spoken.
    let rawDish: String
    /// "recipe" | "eatOut" | "leftovers" | "skip".
    let intent: String
}

@Generable(description: "A full weekly meal plan parsed from a spoken request")
struct GenerableWeeklyPlan: Equatable {
    let entries: [GenerableMealEntry]

    /// Map to the canonical package type the resolver + cloud path share.
    func toParsed() -> ParsedWeeklyPlan {
        ParsedWeeklyPlan(entries: entries.map {
            ParsedMealEntry(day: $0.day, slot: $0.slot, rawDish: $0.rawDish, intent: $0.intent)
        })
    }
}

#endif
