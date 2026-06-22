import Foundation

// SP-C AI-3 — Event-menu prompt builder (pure, headless-testable).
//
// Faithful Swift port of `app/services/event_ai.py::_build_prompt` (plus its
// `_describe_guests` attendee block + the `_AGE_GROUP_HINT` table + the
// `_describe_preassigned_meals` "already on the menu" block + `ai.unit_system_directive`).
// FIDELITY to the server is the bar: the event framing, the per-guest constraint
// lines (allergies / age group / dietary notes), the desired-roles spec, the
// already-on-menu dedupe block, the full-headcount `servings` rule, and — the
// safety-critical invariant — the **"NEVER include an allergen for a flagged guest"**
// hard rule plus the "every constrained guest has a compatible dish per role"
// guarantee, all match the Python. Reviews scrutinize this against the authority.
//
// What is intentionally NOT ported here:
//   • `_resolve_target` / `run_direct_provider` — that is the BYOKeyProvider / AIService
//     transport.
//   • the DB reads (`event.meals`, `event.attendees`) — the app-layer gather supplies
//     the `EventMenuContext` from the CloudKit event/guest stores.
//   • `_parse_response` / `_resolve_coverage` — those live in `EventMenuSchema`.

public enum EventMenuPrompt {

    /// The default desired dish roles when the caller supplies none — matches the
    /// server's `DEFAULT_ROLES = ("starter", "main", "side", "side", "dessert")`.
    public static let defaultRoles = ["starter", "main", "side", "side", "dessert"]

    /// Per-age-group portion/safety hints. Faithful port of `event_ai._AGE_GROUP_HINT`.
    /// Only non-adult groups inject their hint (matching the server's
    /// `age_hint and guest.age_group != "adult"` guard).
    static let ageGroupHint: [String: String] = [
        "baby": "baby (<1y — purees / soft foods only, no honey, no whole nuts, no raw fish, small portion)",
        "toddler": "toddler (1-3y — soft + bite-sized, no whole grapes/nuts, modest portion)",
        "child": "child (4-12y — milder seasoning preferred, smaller portion than adult)",
        "teen": "teen (13-17y — adult-sized portion typical)",
        "adult": "adult",
    ]

    /// Render the attendees-with-constraints block. Faithful port of
    /// `event_ai._describe_guests`: one line per guest with optional `(+N more)`,
    /// relationship label, non-adult age hint, ALLERGIES, and dietary notes — in that
    /// order. Returns the placeholder when there are no attendees.
    static func describeGuests(_ attendees: [EventAttendee]) -> String {
        if attendees.isEmpty {
            return "(no specific guests listed — design for a general audience)"
        }
        var lines: [String] = []
        for attendee in attendees {
            var parts = ["- \(attendee.name)"]
            if attendee.plusOnes > 0 {
                parts.append("(+\(attendee.plusOnes) more in their party)")
            }
            let relationship = attendee.relationshipLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !relationship.isEmpty {
                parts.append("(\(relationship))")
            }
            let ageHint = ageGroupHint[attendee.ageGroup] ?? ""
            if !ageHint.isEmpty && attendee.ageGroup != "adult" {
                parts.append("age: \(ageHint)")
            }
            let allergies = attendee.allergies.trimmingCharacters(in: .whitespacesAndNewlines)
            if !allergies.isEmpty {
                parts.append("ALLERGIES: \(allergies)")
            }
            let notes = attendee.dietaryNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty {
                parts.append("notes: \(notes)")
            }
            lines.append(parts.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// The name→guest-id roster the coverage resolver (`EventMenuParser.resolveCoverage`)
    /// uses, built the way `_describe_guests`'s `lookup` is (trimmed + lowercased name
    /// → guest id). Exposed so the app can resolve the AI's `compatible_guests` names
    /// back to guest ids without re-deriving the normalization.
    public static func nameToGuestId(_ attendees: [EventAttendee]) -> [String: String] {
        var lookup: [String: String] = [:]
        for attendee in attendees {
            lookup[attendee.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] = attendee.guestId
        }
        return lookup
    }

    /// Render the "already on the menu" dedupe block. Faithful port of
    /// `event_ai._describe_preassigned_meals`: only the user's manual (non-AI) dishes,
    /// each `[role] name` with an optional `— being brought by Guest`. Returns "" when
    /// there are no manual dishes (the server returns an empty string, omitting the block).
    static func describePreassignedMeals(_ meals: [PreassignedMeal]) -> String {
        let manual = meals.filter { !$0.aiGenerated }
        guard !manual.isEmpty else { return "" }
        var lines = ["Already on the menu (do NOT propose duplicates):"]
        for meal in manual {
            var assignee = ""
            let name = meal.assignedGuestName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                assignee = " — being brought by \(name)"
            }
            lines.append("- [\(meal.role)] \(meal.recipeName)\(assignee)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The JSON response-shape block the prompt asks the model to return. Mirrors the
    /// `schema` string literal in `event_ai._build_prompt`.
    static let schemaHint = """
    {
      "menu": [
        {
          "role": "starter" | "main" | "side" | "dessert" | "beverage" | "other",
          "recipe_name": "",
          "servings": 0,
          "notes": "",
          "compatible_guests": ["Guest Name", ...],
          "ingredients": [
            {"ingredient_name": "", "quantity": 0, "unit": "", "prep": ""}
          ]
        }
      ],
      "coverage_summary": "one short paragraph describing how each constrained guest has something they can eat"
    }
    """

    /// Build the event-menu system prompt. Faithful port of `event_ai._build_prompt`:
    /// the event identity, the attendee-constraint block, the desired roles, the
    /// already-on-menu dedupe block, the full-headcount servings rule, and the
    /// allergy-safety hard rule + per-role coverage guarantee.
    ///
    /// - Parameters:
    ///   - event: the event identity (name / occasion / date / total attendee count /
    ///     host notes).
    ///   - attendees: the guests-with-constraints (allergies, age groups, notes).
    ///   - roles: the desired dish roles; nil/empty → `defaultRoles`.
    ///   - preassignedMeals: dishes already on the event (only the manual ones are
    ///     surfaced as "do NOT duplicate").
    ///   - userPrompt: an optional free-text request from the user.
    ///   - unitSystem: the user's unit system (defaults to `.us` like the server).
    public static func buildPrompt(
        event: EventMenuContext,
        attendees: [EventAttendee],
        roles: [String]? = nil,
        preassignedMeals: [PreassignedMeal] = [],
        userPrompt: String = "",
        unitSystem: UnitSystem = .us
    ) -> String {
        let guestBlock = describeGuests(attendees)
        let resolvedRoles = (roles?.isEmpty ?? true) ? defaultRoles : roles!
        let roleSpec = resolvedRoles.isEmpty ? "dealer's choice" : resolvedRoles.joined(separator: ", ")
        let dateLine = event.dateISO.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Date: TBD"
            : "Date: \(event.dateISO.trimmingCharacters(in: .whitespacesAndNewlines))"
        let trimmedNotes = event.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesLine = trimmedNotes.isEmpty ? "" : "\nHost notes: \(trimmedNotes)"
        let trimmedUserPrompt = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = trimmedUserPrompt.isEmpty ? "" : "\nUser request: \(trimmedUserPrompt)"
        let preassigned = describePreassignedMeals(preassignedMeals)
        let preassignedBlock = preassigned.isEmpty ? "" : "\n\(preassigned)"
        let unitsDirective = WeekGenPrompt.unitSystemDirective(unitSystem)

        return """
        \(unitsDirective)

        You are designing a menu for a one-off event (not a recurring week). \
        Your job: propose a crowd-pleasing menu for the majority, THEN ensure \
        every guest with constraints has at least one compatible dish at each \
        major role they'd expect (typically a main + a side). Do NOT over-\
        restrict the whole menu just to accommodate one guest — design inclusive \
        variants or dedicated dishes instead.

        Event: \(event.name)
        Occasion: \(event.occasion)
        \(dateLine)
        Total attendees (including host + plus-ones): \(event.attendeeCount)
        Desired dish roles: \(roleSpec)
        \(notesLine)\(extra)
        \(preassignedBlock)
        Guests with constraints:
        \(guestBlock)

        Rules:
        - `servings` on every dish must reflect the full attendee count (scale \
        recipes accordingly — party portions, not single-serving).
        - NEVER include an allergen in a dish flagged as compatible with the \
        allergic guest. Hard rule.
        - For each constrained guest, guarantee at least one `main` that works \
        for them. Prefer dishes that naturally work for everyone over dedicated \
        substitute plates when possible.
        - `compatible_guests` should list the *names* of guests the dish is \
        explicitly safe for. Leave the list empty when the dish works for all.
        - `ingredients` should include quantities appropriate for the full \
        headcount. Prefer common pantry items.
        - Return ONLY a JSON object matching this schema:
        \(schemaHint)
        """
    }
}

// MARK: - Inputs (app → prompt)

/// The event identity for the menu prompt. The app maps a domain `Event` onto this
/// dependency-free value so the builder stays in AIProviderKit. Mirrors the fields
/// `event_ai._build_prompt` reads off the `Event` model.
public struct EventMenuContext: Sendable, Equatable {
    public var name: String
    public var occasion: String
    /// The event date as an ISO `yyyy-MM-dd` string, or "" for TBD (the app formats
    /// the domain `Date`; the builder just embeds it the way the server does
    /// `event_date.isoformat()`).
    public var dateISO: String
    public var attendeeCount: Int
    public var notes: String

    public init(
        name: String,
        occasion: String = "",
        dateISO: String = "",
        attendeeCount: Int = 0,
        notes: String = ""
    ) {
        self.name = name
        self.occasion = occasion
        self.dateISO = dateISO
        self.attendeeCount = attendeeCount
        self.notes = notes
    }
}

/// One attendee with their constraints. Mirrors the `(Guest, plus_ones)` tuple
/// `event_ai._describe_guests` consumes. `guestId` is carried so the coverage
/// resolver can map the AI's `compatible_guests` names back to ids.
public struct EventAttendee: Sendable, Equatable {
    public var guestId: String
    public var name: String
    public var plusOnes: Int
    public var relationshipLabel: String
    /// One of `baby` / `toddler` / `child` / `teen` / `adult` (mirrors `Guest.age_group`).
    public var ageGroup: String
    public var allergies: String
    public var dietaryNotes: String

    public init(
        guestId: String,
        name: String,
        plusOnes: Int = 0,
        relationshipLabel: String = "",
        ageGroup: String = "adult",
        allergies: String = "",
        dietaryNotes: String = ""
    ) {
        self.guestId = guestId
        self.name = name
        self.plusOnes = plusOnes
        self.relationshipLabel = relationshipLabel
        self.ageGroup = ageGroup
        self.allergies = allergies
        self.dietaryNotes = dietaryNotes
    }
}

/// A dish already on the event. Mirrors the `EventMeal` fields
/// `event_ai._describe_preassigned_meals` reads. Only `aiGenerated == false` rows are
/// surfaced as "do NOT duplicate" (regenerated AI dishes are wiped + replaced).
public struct PreassignedMeal: Sendable, Equatable {
    public var role: String
    public var recipeName: String
    public var aiGenerated: Bool
    public var assignedGuestName: String

    public init(
        role: String,
        recipeName: String,
        aiGenerated: Bool,
        assignedGuestName: String = ""
    ) {
        self.role = role
        self.recipeName = recipeName
        self.aiGenerated = aiGenerated
        self.assignedGuestName = assignedGuestName
    }
}
