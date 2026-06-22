import Foundation
import Testing
@testable import AIProviderKit

// SP-C AI-3 — event-menu + event-meal-recipe + day-rebalance prompt builders,
// schemas, and parsers.
//
// Verifies fidelity to:
//   • `app/services/event_ai.py::_build_prompt` (event-menu: attendees/constraints,
//     desired roles, already-on-menu dedupe, full-headcount servings, and — the
//     safety-critical invariant — the allergy hard rule + per-role coverage guarantee),
//   • `event_ai.py::_build_per_dish_prompt` (event-meal recipe → RecipeDraft, reusing
//     AI-2's recipe schema + `RecipeAIParser.parseRecipe`),
//   • `week_planner.py::rebalance_day` (day-scoped user prompt, ±5% target, the
//     `meal_date`/`day_name` default stamping; system prompt = the week-gen prompt).

// MARK: - Fixtures

private func partyEvent() -> EventMenuContext {
    EventMenuContext(
        name: "Maya's Birthday",
        occasion: "birthday",
        dateISO: "2026-07-04",
        attendeeCount: 12,
        notes: "outdoor, casual"
    )
}

private func attendeesWithConstraints() -> [EventAttendee] {
    [
        EventAttendee(
            guestId: "g-aunt",
            name: "Aunt Rosa",
            plusOnes: 1,
            relationshipLabel: "aunt",
            ageGroup: "adult",
            allergies: "peanuts, shellfish",
            dietaryNotes: "prefers mild spice"
        ),
        EventAttendee(
            guestId: "g-leo",
            name: "Leo",
            ageGroup: "toddler",
            allergies: "eggs"
        ),
        EventAttendee(
            guestId: "g-sam",
            name: "Sam",
            relationshipLabel: "friend"
        ),
    ]
}

// MARK: - (a) Event-menu prompt structure (fidelity to _build_prompt)

@Test("event-menu prompt embeds the event, attendees, roles, units, and the JSON schema")
func eventMenuPromptCoreStructure() {
    let prompt = EventMenuPrompt.buildPrompt(
        event: partyEvent(),
        attendees: attendeesWithConstraints(),
        roles: nil,
        unitSystem: .us
    )
    #expect(prompt.contains("UNIT SYSTEM — US CUSTOMARY ONLY"))
    #expect(prompt.contains("You are designing a menu for a one-off event"))
    // Event identity.
    #expect(prompt.contains("Event: Maya's Birthday"))
    #expect(prompt.contains("Occasion: birthday"))
    #expect(prompt.contains("Date: 2026-07-04"))
    #expect(prompt.contains("Total attendees (including host + plus-ones): 12"))
    #expect(prompt.contains("Host notes: outdoor, casual"))
    // Default roles when none supplied (DEFAULT_ROLES).
    #expect(prompt.contains("Desired dish roles: starter, main, side, side, dessert"))
    // Response-shape contract.
    #expect(prompt.contains("\"menu\": ["))
    #expect(prompt.contains("\"compatible_guests\""))
    #expect(prompt.contains("\"coverage_summary\""))
}

@Test("event-menu attendee block carries plus-ones, age hint, ALLERGIES, and notes")
func eventMenuGuestBlock() {
    let prompt = EventMenuPrompt.buildPrompt(
        event: partyEvent(),
        attendees: attendeesWithConstraints()
    )
    // Aunt Rosa: +1, relationship, allergies, dietary notes (adult → no age hint).
    #expect(prompt.contains("- Aunt Rosa (+1 more in their party) (aunt) ALLERGIES: peanuts, shellfish notes: prefers mild spice"))
    // Leo: toddler age hint present, eggs allergy.
    #expect(prompt.contains("age: toddler (1-3y — soft + bite-sized, no whole grapes/nuts, modest portion)"))
    #expect(prompt.contains("ALLERGIES: eggs"))
    // Sam: just a relationship, no constraints.
    #expect(prompt.contains("- Sam (friend)"))
}

@Test("THE ALLERGY HARD RULE + per-role coverage guarantee are present in the event-menu prompt")
func eventMenuAllergyRule() {
    let prompt = EventMenuPrompt.buildPrompt(
        event: partyEvent(),
        attendees: attendeesWithConstraints()
    )
    // The safety-critical invariant — must survive verbatim from event_ai._build_prompt.
    #expect(prompt.contains("NEVER include an allergen in a dish flagged as compatible with the allergic guest. Hard rule."))
    // Every constrained guest gets at least one compatible dish per major role.
    #expect(prompt.contains("For each constrained guest, guarantee at least one `main` that works"))
    // Full-headcount servings rule.
    #expect(prompt.contains("`servings` on every dish must reflect the full attendee count"))
}

@Test("event-menu honors caller-supplied roles and the metric unit system")
func eventMenuRolesAndMetric() {
    let prompt = EventMenuPrompt.buildPrompt(
        event: partyEvent(),
        attendees: [],
        roles: ["main", "dessert"],
        unitSystem: .metric
    )
    #expect(prompt.contains("Desired dish roles: main, dessert"))
    #expect(prompt.contains("UNIT SYSTEM — METRIC ONLY"))
    // No attendees → the placeholder line.
    #expect(prompt.contains("(no specific guests listed — design for a general audience)"))
}

@Test("event-menu surfaces only manual dishes as already-on-menu and dedupes them")
func eventMenuPreassignedBlock() {
    let prompt = EventMenuPrompt.buildPrompt(
        event: partyEvent(),
        attendees: attendeesWithConstraints(),
        preassignedMeals: [
            PreassignedMeal(role: "dessert", recipeName: "Carrot Cake", aiGenerated: false, assignedGuestName: "Sam"),
            PreassignedMeal(role: "side", recipeName: "Old AI Salad", aiGenerated: true),
        ]
    )
    #expect(prompt.contains("Already on the menu (do NOT propose duplicates):"))
    #expect(prompt.contains("- [dessert] Carrot Cake — being brought by Sam"))
    // The AI-generated dish is NOT surfaced (it gets wiped + replaced on regen).
    #expect(!prompt.contains("Old AI Salad"))
}

@Test("event-menu omits empty optional blocks (notes, user request, preassigned)")
func eventMenuOmitsEmptyBlocks() {
    let bare = EventMenuContext(name: "Plain Dinner", occasion: "dinner", dateISO: "", attendeeCount: 4, notes: "")
    let prompt = EventMenuPrompt.buildPrompt(event: bare, attendees: [])
    #expect(prompt.contains("Date: TBD"))
    #expect(!prompt.contains("Host notes:"))
    #expect(!prompt.contains("User request:"))
    #expect(!prompt.contains("Already on the menu"))
}

// MARK: - (a) Event-menu parser round-trip + coverage resolution

private let sampleMenuResponse = """
{
  "menu": [
    {
      "role": "main",
      "recipe_name": "Herb Roast Chicken",
      "servings": 12,
      "notes": "crowd pleaser",
      "compatible_guests": ["Aunt Rosa", "Leo"],
      "ingredients": [
        {"ingredient_name": "whole chicken", "quantity": 3, "unit": "each", "prep": ""},
        {"ingredient_name": "rosemary", "quantity": 2, "unit": "tbsp"}
      ]
    },
    {
      "role": "dessert",
      "recipe_name": "Fruit Salad",
      "compatible_guests": [],
      "ingredients": [{"ingredient_name": "mixed berries", "quantity": "4", "unit": "cup"}]
    }
  ],
  "coverage_summary": "Aunt Rosa and Leo both have the roast chicken as a safe main."
}
"""

@Test("event-menu parser round-trips the documented response shape")
func eventMenuParserRoundTrip() throws {
    let response = try EventMenuParser.parse(sampleMenuResponse)
    #expect(response.menu.count == 2)
    #expect(response.coverageSummary.contains("safe main"))
    let main = try #require(response.menu.first)
    #expect(main.role == "main")
    #expect(main.recipeName == "Herb Roast Chicken")
    #expect(main.servings == 12)
    #expect(main.compatibleGuests == ["Aunt Rosa", "Leo"])
    #expect(main.ingredients.count == 2)
    // String quantity ("4") on the dessert decodes to a Double.
    #expect(response.menu[1].ingredients.first?.quantity == 4)
    // Empty compatible_guests = works for everyone.
    #expect(response.menu[1].compatibleGuests.isEmpty)
}

@Test("event-menu parser strips a markdown fence and salvages leading prose")
func eventMenuParserStripsWrapping() throws {
    let fenced = "Here's the menu:\n```json\n" + sampleMenuResponse + "\n```"
    let response = try EventMenuParser.parse(fenced)
    #expect(response.menu.count == 2)
}

@Test("event-menu parser throws on non-JSON and on an empty menu")
func eventMenuParserErrors() {
    #expect(throws: EventMenuParseError.invalidJSON) {
        _ = try EventMenuParser.parse("no menu today, sorry")
    }
    #expect(throws: EventMenuParseError.emptyMenu) {
        _ = try EventMenuParser.parse(#"{"menu": [], "coverage_summary": ""}"#)
    }
}

@Test("coverage resolution maps AI guest names back to ids and drops invented names")
func eventMenuCoverageResolution() {
    let attendees = attendeesWithConstraints()
    let lookup = EventMenuPrompt.nameToGuestId(attendees)
    // Case-insensitive + trimmed match; "Everyone" is dropped (invented / catch-all).
    let resolved = EventMenuParser.resolveCoverage(
        ["  aunt rosa ", "LEO", "Everyone"],
        nameToGuestId: lookup
    )
    #expect(resolved == ["g-aunt", "g-leo"])
}

@Test("parseAndResolve maps names to ids, stamps sort order, and applies the servings fallback")
func eventMenuParseAndResolve() throws {
    let attendees = attendeesWithConstraints()
    let lookup = EventMenuPrompt.nameToGuestId(attendees)
    let result = try EventMenuParser.parseAndResolve(
        sampleMenuResponse,
        nameToGuestId: lookup,
        attendeeCount: 12
    )
    #expect(result.dishes.count == 2)
    let main = try #require(result.dishes.first)
    #expect(main.sortOrder == 0)
    // compatible_guests names resolved to guest ids (the server's constraint_coverage).
    #expect(main.constraintCoverage == ["g-aunt", "g-leo"])
    // The dessert had no servings → falls back to the attendee count (matching
    // `ai_meal.servings or float(event.attendee_count or 1)`).
    let dessert = result.dishes[1]
    #expect(dessert.sortOrder == 1)
    #expect(dessert.servings == 12)
    #expect(dessert.constraintCoverage.isEmpty)
}

// MARK: - (b) Event-meal recipe prompt (fidelity to _build_per_dish_prompt)

@Test("event-meal recipe prompt frames one dish, scales to headcount, and keeps the allergy rule")
func eventMealRecipePromptStructure() {
    let constraints = EventMenuPrompt.describeGuests(attendeesWithConstraints())
    let prompt = RecipeAIPrompt.eventMealRecipePrompt(
        dishName: "Herb Roast Chicken",
        servings: 12,
        eventName: "Maya's Birthday",
        occasion: "birthday",
        constraintsBlock: constraints,
        userPrompt: "keep it gluten-free",
        unit: .us
    )
    #expect(prompt.contains("UNIT SYSTEM — US CUSTOMARY ONLY"))
    #expect(prompt.contains("You are writing ONE detailed recipe for the dish \"Herb Roast Chicken\""))
    #expect(prompt.contains("on the event \"Maya's Birthday\" (occasion: birthday)"))
    #expect(prompt.contains("This recipe must serve 12 people total"))
    // The event guest-constraint block is reused so the recipe avoids allergens.
    #expect(prompt.contains("Guests with constraints (avoid allergens for these diners):"))
    #expect(prompt.contains("ALLERGIES: peanuts, shellfish"))
    #expect(prompt.contains("User hint: keep it gluten-free"))
    // The safety-critical hard rule — must survive verbatim.
    #expect(prompt.contains("NEVER include a known allergen for any guest listed above."))
    // Reuses AI-2's single-recipe schema.
    #expect(prompt.contains("\"ingredient_name\""))
    #expect(prompt.contains("\"steps\""))
}

@Test("event-meal recipe prompt defaults occasion to 'general' and degrades with no attendees")
func eventMealRecipePromptDefaults() {
    let prompt = RecipeAIPrompt.eventMealRecipePrompt(
        dishName: "Garden Salad",
        servings: 6,
        eventName: "Office Lunch",
        occasion: "",
        constraintsBlock: ""
    )
    #expect(prompt.contains("(occasion: general)"))
    // No attendees → conservative placeholder, no User hint line.
    #expect(prompt.contains("(no specific guests listed — avoid common allergens conservatively)"))
    #expect(!prompt.contains("User hint:"))
}

@Test("event-meal recipe response parses with AI-2's parseRecipe (→ a RecipeDraft)")
func eventMealRecipeParses() throws {
    let raw = """
    {
      "name": "Herb Roast Chicken",
      "meal_type": "dinner",
      "servings": 12,
      "ingredients": [{"ingredient_name": "whole chicken", "quantity": 3, "unit": "each"}],
      "steps": [{"instruction": "Roast at 425F until done."}]
    }
    """
    let recipe = try RecipeAIParser.parseRecipe(raw)
    #expect(recipe.name == "Herb Roast Chicken")
    #expect(recipe.servings == 12)
    #expect(recipe.ingredients.count == 1)
    #expect(recipe.steps.first?.instruction == "Roast at 425F until done.")
}

// MARK: - (c) Day-rebalance prompt (fidelity to rebalance_day)

private func rebalanceWeekStart() -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = 6; c.day = 22
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: c)!
}

private func rebalanceContext() -> PlanningContext {
    PlanningContext(
        dietaryGoal: DietaryGoalContext(
            goalType: "cut", dailyCalories: 1900, proteinG: 150,
            carbsG: 170, fatG: 55, fiberG: 28, notes: "high protein"
        ),
        allergies: ["peanut"]
    )
}

@Test("rebalance system prompt is the week-gen prompt (carries goal + ±10% week rule + allergy line)")
func rebalanceSystemPromptDelegates() {
    let sys = DayRebalancePrompt.systemPrompt(
        profileSettings: ["household_name": "The Smiths"],
        weekStart: rebalanceWeekStart(),
        context: rebalanceContext(),
        unitSystem: .us
    )
    let weekGen = WeekGenPrompt.buildSystemPrompt(
        profileSettings: ["household_name": "The Smiths"],
        weekStart: rebalanceWeekStart(),
        context: rebalanceContext(),
        unitSystem: .us
    )
    // The rebalance system prompt is byte-for-byte the week-gen prompt.
    #expect(sys == weekGen)
    #expect(sys.contains("Dietary goal (per-person, per-day):"))
    #expect(sys.contains("- Daily target: 1900 calories, 150g protein, 170g carbs, 55g fat, 28g fiber"))
    #expect(sys.contains("HARD ALLERGIES — NEVER include these or any dish containing them: peanut"))
}

@Test("rebalance user prompt scopes to one day with the ±5% target and a 3-entry meal_plan")
func rebalanceUserPromptScoping() {
    let date = WeekGenPrompt.isoDay(rebalanceWeekStart(), offsetDays: 2) // Wednesday
    let user = DayRebalancePrompt.userPrompt(dayName: "Wednesday", targetDateISO: date)
    #expect(date == "2026-06-24")
    #expect(user.contains("Replan only Wednesday (2026-06-24)"))
    // Tighter than the week's ±10% — the rebalance-specific target.
    #expect(user.contains("within ±5% of the daily calorie target"))
    #expect(user.contains("respect every rule already stated in the system prompt"))
    #expect(user.contains("`meal_plan` array containing exactly 3 entries"))
    #expect(user.contains("meal_date \"2026-06-24\" and day_name \"Wednesday\""))
}

@Test("rebalance user prompt appends the optional deficit note")
func rebalanceUserPromptDeficitNote() {
    let user = DayRebalancePrompt.userPrompt(
        dayName: "Friday",
        targetDateISO: "2026-06-26",
        existingDeficitNote: "The day currently runs 400 kcal under target."
    )
    #expect(user.hasSuffix("The day currently runs 400 kcal under target."))
    // No note → no trailing fragment.
    let bare = DayRebalancePrompt.userPrompt(dayName: "Friday", targetDateISO: "2026-06-26")
    #expect(bare.hasSuffix("day_name \"Friday\"."))
}

@Test("rebalance response parses with MealPlanParser and stamps day defaults")
func rebalanceParsesAndStampsDefaults() throws {
    // The model returns the week-gen shape but omits meal_date/day_name on one slot.
    let raw = """
    {
      "recipes": [{"name": "Greek Yogurt Bowl", "ingredients": [{"ingredient_name": "greek yogurt"}]}],
      "meal_plan": [
        {"slot": "breakfast", "recipe_name": "Greek Yogurt Bowl"},
        {"day_name": "Wednesday", "meal_date": "2026-06-24", "slot": "lunch", "recipe_name": "Greek Yogurt Bowl"}
      ]
    }
    """
    let parsed = try MealPlanParser.parse(raw)
    let stamped = DayRebalancePrompt.applyDayDefaults(parsed, dayName: "Wednesday", targetDateISO: "2026-06-24")
    // The slot that omitted the date/day gets it backfilled.
    #expect(stamped.mealPlan[0].mealDate == "2026-06-24")
    #expect(stamped.mealPlan[0].dayName == "Wednesday")
    // The slot that already carried them is unchanged.
    #expect(stamped.mealPlan[1].mealDate == "2026-06-24")
    #expect(stamped.mealPlan[1].dayName == "Wednesday")
}

@Test("rebalance still runs the shared allergy hard-gate (fails closed on a peanut dish)")
func rebalanceAllergyGate() throws {
    let raw = """
    {
      "recipes": [{"name": "Peanut Noodles", "ingredients": [{"ingredient_name": "peanut butter"}]}],
      "meal_plan": [{"day_name": "Wednesday", "meal_date": "2026-06-24", "slot": "dinner", "recipe_name": "Peanut Noodles"}]
    }
    """
    #expect(throws: MealPlanParseError.allergyViolation(recipe: "Peanut Noodles", allergen: "peanut")) {
        _ = try MealPlanParser.parseAndGate(raw, allergies: ["peanut"])
    }
}
