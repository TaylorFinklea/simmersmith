import Foundation
import SimmerSmithKit
#if canImport(CloudKit)
import AIProviderKit
#endif

// SP-C AI-1 — on-device week generation.
//
// `generateWeek(weekID:prompt:)` is the device-side replacement for the Fly
// `generateWeekPlan` call: build the planning context from CloudKit/private-plane
// stores → build the ported system prompt → call the BYO-key provider for
// structured JSON → parse → apply the allergy HARD-GATE → map to MealUpdateRequest
// and save via WeekRepository (which regenerates grocery + mirrors). Fails closed
// on an allergy violation; surfaces clear errors for no-key / provider / parse.
//
// `generateWeekFromAI` (AppState+Weeks) delegates here when the CloudKit session
// (aiService + weekRepository) is live, and otherwise falls back to Fly.

#if canImport(CloudKit)
extension AppState {

    /// Generate a full 21-meal week on-device against the user's own cloud key.
    /// Throws `WeekGenError` for the no-session / no-meals / allergy cases and
    /// propagates `AIServiceError` / `AIError` for provider failures.
    @MainActor
    func generateWeek(weekID: String, prompt: String) async throws -> WeekSnapshot {
        guard let aiSvc = aiService, let weekRepo = weekRepository else {
            throw WeekGenError.sessionNotReady
        }
        guard let week = weekRepo.week(forId: weekID) else {
            throw WeekGenError.weekNotFound
        }

        // 1. Gather planning context from CloudKit + the private plane (NOT Fly).
        let context = gatherWeekGenContext(excludeWeekId: weekID)

        // 2. Build the ported system prompt (fidelity to week_planner._build_system_prompt).
        let unitSystem = UnitSystem.normalized(currentUnitSystemSetting())
        let systemPrompt = WeekGenPrompt.buildSystemPrompt(
            profileSettings: visibleProfileSettings(),
            weekStart: week.weekStart,
            context: context,
            unitSystem: unitSystem
        )
        let userPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? WeekGenPrompt.defaultUserPrompt
            : prompt

        // 3. Call the provider for structured JSON. The system prompt is threaded
        //    separately via AIRequest.systemPrompt so the provider can route it to the
        //    correct field (Anthropic: `system`; OpenAI: system-role message) matching
        //    week_planner.py's two-message structure (week_planner.py:393-413).
        let request = AIRequest(
            feature: .weekGen,
            systemPrompt: systemPrompt,
            prompt: userPrompt,
            wantsStructuredJSON: true
        )

        // 4. Generate → parse → allergy hard-gate, with a single parse retry (spec §4).
        let result = try await generateAndParse(
            aiSvc: aiSvc, request: request, allergies: context.allergies
        )

        // 5. Map the validated plan onto MealUpdateRequest + save via WeekRepository.
        let meals = mealUpdateRequests(from: result, weekStart: week.weekStart)
        guard !meals.isEmpty else { throw WeekGenError.emptyPlan }
        // knownMealIDs: the `week` snapshot fetched above (empty on a fresh week; old ids
        // known + replaced by the regenerated `meals` on a regen).
        return try await saveWeekMeals(
            weekID: weekID, meals: meals, knownMealIDs: Set(week.meals.map { $0.mealId })
        )
    }

    // MARK: - Context gather

    /// Assemble the planning context from the live repositories. Degrades to empty
    /// fields when a repository is missing or empty (the prompt omits those lines).
    func gatherWeekGenContext(excludeWeekId: String?) -> PlanningContext {
        let staples = pantryRepository?.pantryItems
            .filter(\.isActive)
            .map(\.stapleName) ?? []
        let aliases: [String: String] = aliasRepository?.aliases
            .reduce(into: [:]) { $0[$1.term] = $1.expansion } ?? [:]
        return WeekGenContextGatherer.build(
            pantryStaples: staples,
            dietaryGoal: profileRepository?.dietaryGoal,
            ingredientPreferences: ingredientPreferences,
            recentWeeks: weekRepository?.weeks ?? [],
            termAliases: aliases,
            excludeWeekId: excludeWeekId
        )
    }

    // MARK: - Generate + parse (with one retry on malformed output)

    private func generateAndParse(
        aiSvc: AIService, request: AIRequest, allergies: [String]
    ) async throws -> MealPlanResult {
        var lastParseError: Error?
        for attempt in 0..<2 {
            let response = try await aiSvc.generate(request)
            do {
                // Parse first (a malformed response is a parse error, retryable), then
                // the allergy gate fails closed (NOT retryable — a clean regenerate
                // could still violate, so surface it immediately).
                let result = try MealPlanParser.parse(response.text)
                try MealPlanParser.enforceAllergyGate(result, allergies: allergies)
                return result
            } catch let err as MealPlanParseError {
                switch err {
                case .invalidJSON, .emptyPlan:
                    lastParseError = err
                    if attempt == 0 { continue }    // retry once
                    throw WeekGenError.malformedResponse
                case .allergyViolation(let recipe, let allergen):
                    throw WeekGenError.allergyViolation(recipe: recipe, allergen: allergen)
                }
            }
        }
        throw WeekGenError.malformedResponse(underlying: lastParseError)
    }

    // MARK: - Schema → MealUpdateRequest mapping

    /// Map the parsed plan's 21 slots onto `MealUpdateRequest`. The recipe name comes
    /// from the slot; servings/notes pass through; `mealDate` is parsed from the slot's
    /// ISO day (falling back to the week-start + slot index). Recipe records are NOT
    /// created here — week-gen meals carry `recipeName` (AI-2 wires full recipe import);
    /// ingredients live on the meal's resolved recipe later.
    func mealUpdateRequests(from result: MealPlanResult, weekStart: Date) -> [MealUpdateRequest] {
        result.mealPlan.compactMap { slot in
            let name = slot.recipeName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let date = Self.parseISODay(slot.mealDate) ?? weekStart
            return MealUpdateRequest(
                mealId: nil,
                dayName: slot.dayName,
                mealDate: date,
                slot: slot.slot,
                recipeId: slot.recipeId,
                recipeName: name,
                servings: slot.servings,
                scaleMultiplier: 1.0,
                notes: slot.notes,
                approved: slot.approved
            )
        }
    }

    // MARK: - Profile helpers

    /// The unit-system setting, preferring the private-plane ProfileRepository value
    /// (CloudKit world) and falling back to the Fly profile snapshot.
    private func currentUnitSystemSetting() -> String? {
        if let v = profileRepository?.settings["unit_system"], !v.isEmpty { return v }
        return profile?.settings["unit_system"]
    }

    /// The visible profile settings for the prompt's profile block — the Fly profile
    /// snapshot's settings minus AI-secret keys (mirrors `visible_profile_settings`).
    /// In a CloudKit-only world this is sparse; the prompt degrades to
    /// "(no preferences set)".
    private func visibleProfileSettings() -> [String: String] {
        let secretKeys: Set<String> = [
            "ai_openai_api_key", "ai_anthropic_api_key", "ai_direct_api_key",
        ]
        var out = profile?.settings ?? [:]
        for key in secretKeys { out.removeValue(forKey: key) }
        return out
    }

    private static func parseISODay(_ s: String) -> Date? {
        Self.isoDayFormatter.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let isoDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - WeekGenError

enum WeekGenError: Error, LocalizedError {
    case sessionNotReady
    case weekNotFound
    case emptyPlan
    case malformedResponse(underlying: Error? = nil)
    case allergyViolation(recipe: String, allergen: String)

    static var malformedResponse: WeekGenError { .malformedResponse(underlying: nil) }

    var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            return "AI week generation needs iCloud — try again after sync finishes."
        case .weekNotFound:
            return "That week could not be found."
        case .emptyPlan:
            return "The AI returned a plan with no meals. Please try again."
        case .malformedResponse:
            return "The AI returned an unexpected response. Please try again."
        case .allergyViolation(let recipe, let allergen):
            return "Generation stopped: \"\(recipe)\" contains \(allergen), which is on your allergy list. No unsafe plan was saved — try regenerating."
        }
    }
}
#endif
