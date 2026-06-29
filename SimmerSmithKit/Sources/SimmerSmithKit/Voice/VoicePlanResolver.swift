import Foundation

// SP-C voice week-planning — pure resolver: a parsed spoken plan + the recipe library + the
// week's Monday → [MealUpdateRequest] proposal. No app state, no FoundationModels → fully
// host-testable. Best-match-else-free-text per the user-locked decision; intents map to the
// app's existing conventions (eat-out = recipe-less "Eating Out"; skip = omit the slot).
public enum VoicePlanResolver {

    /// Gregorian calendar pinned to UTC — meal_date is stored at UTC midnight (see DayKey),
    /// so ALL offset math must be UTC or a meal lands on the adjacent day. Self-contained
    /// (does not depend on the app-target DayKey) so this stays in the package.
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    static let weekdayOrder = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    /// Below this normalized-overlap score a dish is kept as free-text rather than matched.
    static let matchThreshold = 0.34

    /// Resolve a parsed plan into apply-ready meal requests.
    /// - weekStart: the week's Monday at UTC midnight (WeekSnapshot.weekStart).
    /// - now: injected for deterministic "today"/"tomorrow" resolution in tests.
    public static func resolve(
        _ plan: ParsedWeeklyPlan,
        recipes: [RecipeSummary],
        weekStart: Date,
        now: Date = Date()
    ) -> [MealUpdateRequest] {
        var out: [MealUpdateRequest] = []
        for entry in plan.entries {
            guard let offset = weekdayOffset(forDay: entry.day, weekStart: weekStart, now: now), (0...6).contains(offset) else { continue }
            let slot = normalizeSlot(entry.slot)
            guard !slot.isEmpty else { continue }

            let intent = MealIntent(parsing: entry.intent)
            if intent == .skip { continue }  // skip = leave the slot empty (omit the row)

            // mealDate = the week's Monday + offset days, in UTC (matches UTC-midnight storage).
            let mealDate = utcCalendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
            let dayName = weekdayOrder[offset].capitalized

            let recipeId: String?
            let recipeName: String
            switch intent {
            case .recipe:
                if let match = bestMatch(for: entry.rawDish, in: recipes) {
                    recipeId = match.recipeId
                    recipeName = match.name
                } else {
                    recipeId = nil
                    recipeName = titlecased(entry.rawDish)
                }
            case .eatOut:
                recipeId = nil
                recipeName = "Eating Out"   // matches the app's existing recipe-less convention
            case .leftovers:
                recipeId = nil
                let dish = titlecased(entry.rawDish)
                recipeName = (dish.isEmpty || dish.lowercased() == "leftovers") ? "Leftovers" : "\(dish) Leftovers"
            case .skip:
                continue
            }
            out.append(MealUpdateRequest(
                dayName: dayName, mealDate: mealDate, slot: slot,
                recipeId: recipeId, recipeName: recipeName, approved: false
            ))
        }
        return out
    }

    // MARK: - Day resolution

    /// 0-based offset from the week's Monday (0=Mon … 6=Sun) for a spoken day reference.
    /// Named weekdays map directly. "today"/"tonight"/"tomorrow" resolve to the ACTUAL UTC day
    /// delta from `weekStart` — so if `now` is outside the planned week they return nil (the
    /// entry is dropped, surfaced in review) rather than mis-landing on the same weekday a week
    /// off. Unknown → nil.
    public static func weekdayOffset(forDay raw: String, weekStart: Date, now: Date = Date()) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "this ", with: "")
            .replacingOccurrences(of: "next ", with: "")
        if let i = weekdayOrder.firstIndex(of: s) { return i }
        switch s {
        case "today", "tonight":
            return dayDelta(weekStart: weekStart, to: now)
        case "tomorrow":
            let next = utcCalendar.date(byAdding: .day, value: 1, to: now) ?? now
            return dayDelta(weekStart: weekStart, to: next)
        default:
            // A contained weekday token, e.g. "tuesday lunch" leaking into the day field.
            if let hit = weekdayOrder.first(where: { s.contains($0) }) {
                return weekdayOrder.firstIndex(of: hit)
            }
            return nil
        }
    }

    /// Whole-day UTC delta from `weekStart` (UTC midnight) to `date`'s UTC day; nil if outside
    /// 0…6 (i.e. `date` is not within the planned week).
    private static func dayDelta(weekStart: Date, to date: Date) -> Int? {
        let dayStart = utcCalendar.startOfDay(for: date)
        guard let days = utcCalendar.dateComponents([.day], from: weekStart, to: dayStart).day,
              (0...6).contains(days) else { return nil }
        return days
    }

    static func normalizeSlot(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "breakfast", "brekkie", "brunch": return "breakfast"
        case "lunch": return "lunch"
        case "dinner", "supper", "tea": return "dinner"
        default: return ""
        }
    }

    // MARK: - Best-match recipe scorer

    /// The closest non-archived recipe to a spoken dish, or nil (→ free-text). Strips filler
    /// words ("that … recipe"), then scores token overlap with a containment boost.
    public static func bestMatch(for rawDish: String, in recipes: [RecipeSummary]) -> RecipeSummary? {
        let qTokens = queryTokens(rawDish)
        guard !qTokens.isEmpty else { return nil }
        let q = qTokens.joined(separator: " ")
        let active = recipes.filter { !$0.archived }

        if let exact = active.first(where: { normalize($0.name) == q }) { return exact }

        var best: (recipe: RecipeSummary, score: Double)?
        let qSet = Set(qTokens)
        for r in active {
            let n = normalize(r.name)
            let nSet = Set(n.split(separator: " ").map(String.init))
            let overlap = qSet.intersection(nSet).count
            guard overlap > 0 else { continue }
            let jaccard = Double(overlap) / Double(qSet.union(nSet).count)
            let contained = n.contains(q) || q.contains(n)
            let score = jaccard + (contained ? 0.3 : 0)
            if best == nil || score > best!.score { best = (r, score) }
        }
        if let best, best.score >= matchThreshold { return best.recipe }
        return nil
    }

    private static let fillerWords: Set<String> = [
        "that", "the", "a", "an", "my", "our", "some", "recipe", "recipes",
        "dish", "thing", "one", "make", "i", "we", "for", "of", "with",
    ]

    static func queryTokens(_ raw: String) -> [String] {
        normalize(raw).split(separator: " ").map(String.init).filter { !fillerWords.contains($0) }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func titlecased(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
