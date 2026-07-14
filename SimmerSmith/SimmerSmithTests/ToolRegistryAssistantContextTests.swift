import AIProviderKit
import CloudKit
import Foundation
import HouseholdSync
import SimmerSmithKit
import Testing

@testable import SimmerSmith

// bead simmersmith-48y — the assistant was context-blind (it edited the WRONG week when
// the user was browsing a different one, because ToolRegistry only ever resolved
// `appState.currentWeek`) AND bypassed the allergy hard-gate on its two write tools
// (`weeks_update_meals`, `recipes_save`, neither of which ran `enforceAllergyGate` the
// way week-gen does). These tests exercise `ToolRegistry` directly against a real
// (headless) HouseholdSession stack — the same pattern as
// `RecipeMemoriesProductFlowTests` / `IngredientsProductFlowTests`: no iCloud account
// needed, `engine.save` writes the local store synchronously before enqueueing.
@MainActor
@Suite(.serialized)
struct ToolRegistryAssistantContextTests {

    // MARK: - Fixtures

    private func makeAppState() throws -> AppState {
        let container = try makeSimmerSmithModelContainer(inMemory: true)
        let suite = "ToolRegistryAssistantContextTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return AppState(
            modelContainer: container,
            settingsStore: ConnectionSettingsStore(
                defaults: defaults,
                keychain: KeychainStore(service: suite)
            )
        )
    }

    /// An `AppState` wired to a fresh headless `HouseholdSession`'s week + recipe repos.
    private func makeWiredAppState() throws -> (AppState, WeekRepository, RecipeRepository) {
        let appState = try makeAppState()
        let session = HouseholdSession(householdID: "tool-registry-tests-\(UUID().uuidString)")
        let weekRepo = WeekRepository(session: session)
        let recipeRepo = RecipeRepository(session: session)
        appState.householdSession = session
        appState.weekRepository = weekRepo
        appState.recipeRepository = recipeRepo
        return (appState, weekRepo, recipeRepo)
    }

    private func peanutAllergy() -> IngredientPreference {
        IngredientPreference(
            preferenceId: "pref-peanut",
            baseIngredientId: "ing-peanut",
            baseIngredientName: "peanut",
            choiceMode: "allergy",
            updatedAt: Date()
        )
    }

    private func argsJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(data: data, encoding: .utf8))
    }

    // MARK: - Browsed-week resolution seam

    @Test("weeks_get_current resolves the ACTIVE week id, not appState.currentWeek")
    func weeksGetCurrentResolvesActiveWeek() async throws {
        let (appState, weekRepo, _) = try makeWiredAppState()
        let current = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_750_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_750_600_000)
        ))
        let browsed = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_751_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_751_600_000)
        ))
        appState.currentWeek = current

        // activeWeekID simulates pageContext?.weekId / browsedWeek?.weekId — the week
        // the user is actually looking at, which DIFFERS from appState.currentWeek.
        let registry = ToolRegistry(appState: appState, activeWeekID: browsed.weekId)
        let result = await registry.runner(ToolCall(id: "1", name: "weeks_get_current", argsJSON: "{}"))

        #expect(result.ok)
        #expect(result.resultJSON.contains(browsed.weekId))
        #expect(!result.resultJSON.contains(current.weekId))
    }

    @Test("weeks_get_current falls back to appState.currentWeek with no active week id")
    func weeksGetCurrentFallsBackToCurrentWeek() async throws {
        let (appState, weekRepo, _) = try makeWiredAppState()
        let current = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_750_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_750_600_000)
        ))
        appState.currentWeek = current

        let registry = ToolRegistry(appState: appState, activeWeekID: nil)
        let result = await registry.runner(ToolCall(id: "1", name: "weeks_get_current", argsJSON: "{}"))

        #expect(result.ok)
        #expect(result.resultJSON.contains(current.weekId))
    }

    // MARK: - grocery_get fail-closed on an unknown week_id

    @Test("grocery_get errors on an unknown week_id instead of silently falling back")
    func groceryGetErrorsOnUnknownWeekID() async throws {
        let (appState, weekRepo, _) = try makeWiredAppState()
        let current = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_750_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_750_600_000)
        ))
        appState.currentWeek = current

        let registry = ToolRegistry(appState: appState, activeWeekID: nil)
        let result = await registry.runner(
            ToolCall(id: "1", name: "grocery_get", argsJSON: try argsJSON(["week_id": "not-a-real-week"]))
        )

        #expect(!result.ok)
        #expect(result.detail.contains("not found"))
    }

    // MARK: - Allergy hard-gate at the executor

    @Test("weeks_update_meals refuses a recipe name matching a recorded allergen")
    func weeksUpdateMealsRefusesAllergenName() async throws {
        let (appState, weekRepo, _) = try makeWiredAppState()
        let week = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_750_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_750_600_000)
        ))
        appState.ingredientPreferences = [peanutAllergy()]

        let registry = ToolRegistry(appState: appState, activeWeekID: week.weekId)
        let args = try argsJSON([
            "week_id": week.weekId,
            "meals": [[
                "day_name": "Monday", "meal_date": "2026-07-13", "slot": "dinner",
                "recipe_name": "Peanut Noodles",
            ]],
        ])
        let result = await registry.runner(ToolCall(id: "1", name: "weeks_update_meals", argsJSON: args))

        #expect(!result.ok)
        #expect(result.detail.lowercased().contains("peanut"))
        // Fail closed: nothing was actually written.
        let reloaded = try #require(weekRepo.week(forId: week.weekId))
        #expect(reloaded.meals.isEmpty)
    }

    @Test("weeks_update_meals refuses via a saved recipe's ingredients, even with a safe-sounding name")
    func weeksUpdateMealsRefusesAllergenIngredient() async throws {
        let (appState, weekRepo, recipeRepo) = try makeWiredAppState()
        let week = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_750_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_750_600_000)
        ))
        appState.ingredientPreferences = [peanutAllergy()]

        let saved = try recipeRepo.save(RecipeDraft(
            name: "Weeknight Noodles",
            ingredients: [RecipeIngredient(ingredientName: "peanut butter")]
        ))
        appState.recipes = recipeRepo.recipes

        let registry = ToolRegistry(appState: appState, activeWeekID: week.weekId)
        let args = try argsJSON([
            "week_id": week.weekId,
            "meals": [[
                "day_name": "Monday", "meal_date": "2026-07-13", "slot": "dinner",
                "recipe_id": saved.recipeId, "recipe_name": "Weeknight Noodles",
            ]],
        ])
        let result = await registry.runner(ToolCall(id: "1", name: "weeks_update_meals", argsJSON: args))

        #expect(!result.ok)
        #expect(result.detail.lowercased().contains("peanut"))
    }

    @Test("weeks_update_meals still saves an unresolvable, non-allergen recipe name")
    func weeksUpdateMealsAllowsUnresolvableCleanName() async throws {
        let (appState, weekRepo, _) = try makeWiredAppState()
        let week = try #require(weekRepo.createWeek(
            weekStart: Date(timeIntervalSince1970: 1_750_000_000),
            weekEnd: Date(timeIntervalSince1970: 1_750_600_000)
        ))
        appState.ingredientPreferences = [peanutAllergy()]

        // No recipe_id, no matching saved recipe, and the name itself doesn't mention
        // the allergen — must NOT be blocked just because it's unresolvable (unlike
        // week-gen's fail-closed-on-unknown, which assumes a complete structured-output
        // plan). Blocking every unresolvable name once a household has ANY allergy on
        // file would make weeks_update_meals unusable for ordinary chat edits.
        let registry = ToolRegistry(appState: appState, activeWeekID: week.weekId)
        let args = try argsJSON([
            "week_id": week.weekId,
            "meals": [[
                "day_name": "Monday", "meal_date": "2026-07-13", "slot": "dinner",
                "recipe_name": "Grilled Chicken",
            ]],
        ])
        let result = await registry.runner(ToolCall(id: "1", name: "weeks_update_meals", argsJSON: args))

        #expect(result.ok)
        let reloaded = try #require(weekRepo.week(forId: week.weekId))
        #expect(reloaded.meals.map(\.recipeName) == ["Grilled Chicken"])
    }

    @Test("recipes_save refuses a recipe whose ingredients match a recorded allergen")
    func recipesSaveRefusesAllergenIngredient() async throws {
        let (appState, _, recipeRepo) = try makeWiredAppState()
        appState.ingredientPreferences = [peanutAllergy()]

        let registry = ToolRegistry(appState: appState, activeWeekID: nil)
        let args = try argsJSON([
            "recipe": [
                "name": "Snack Bar",
                "ingredients": [["ingredient_name": "peanut butter", "unit": "tbsp"]],
            ],
        ])
        let result = await registry.runner(ToolCall(id: "1", name: "recipes_save", argsJSON: args))

        #expect(!result.ok)
        #expect(result.detail.lowercased().contains("peanut"))
        #expect(recipeRepo.recipes.isEmpty)
    }

    @Test("recipes_save still saves a clean recipe despite an allergy on file")
    func recipesSaveAllowsCleanRecipe() async throws {
        let (appState, _, recipeRepo) = try makeWiredAppState()
        appState.ingredientPreferences = [peanutAllergy()]

        let registry = ToolRegistry(appState: appState, activeWeekID: nil)
        let args = try argsJSON([
            "recipe": [
                "name": "Grilled Salmon",
                "ingredients": [["ingredient_name": "salmon", "unit": "lb"]],
            ],
        ])
        let result = await registry.runner(ToolCall(id: "1", name: "recipes_save", argsJSON: args))

        #expect(result.ok)
        #expect(recipeRepo.recipes.first?.name == "Grilled Salmon")
    }
}
