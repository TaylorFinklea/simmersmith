# SP-C — AI track, slice AI-3: Nutrition + Event AI + Day-rebalance

> 2026-06-22. Third AI slice. MIXED: deterministic catalog port (nutrition) + LLM ports
> (event-menu, event-meal-recipe, day-rebalance via AIService). Reuses AI-1 infra + the public catalog.

## 0. Goal + scope
Bring the AI-3 `// AI TRACK` methods off Fly. Two kinds:
- **Deterministic (nutrition — NOT LLM):** `estimateRecipeNutrition`, `searchNutritionItems`,
  `saveIngredientNutritionMatch`. Server `calculate_recipe_nutrition` (app/services/nutrition.py) looks
  up per-ingredient macros from the BaseIngredient/IngredientVariation catalog + scales by qty/unit.
- **LLM (reuse AIService):** `generateEventMenu` (event_ai.py), `generateEventMealRecipe` (RecipeDraft),
  `rebalanceDay` (rebalance a day's meals toward the dietary goal — like week-gen).

## 1. Design decisions (Lead, from the map)
- **Nutrition = deterministic port over the PUBLIC catalog.** The macro data lives in the catalog
  (BaseIngredient: nutrition_reference_amount/unit, calories, protein_g/carbs_g/fat_g/fiber_g). The app's
  `PublicCatalogReader` (SP-A Phase 6) reads the public catalog. **FIRST verify the public catalog records
  expose the full macros** (the iOS BaseIngredient model currently decodes calories only — "partial"). If
  yes → port `calculate_recipe_nutrition` (the macro lookup + unit conversion + scaling) to Swift reading
  the catalog. If the catalog has calories only → compute calorie-level nutrition + coverage status, and
  FLAG that full-macro nutrition needs the catalog publish to include the macro columns (a CATALOG-track
  follow-up; don't block AI-3 on it). No LLM, no API key for nutrition.
- **Nutrition match** (`IngredientNutritionMatch`) is per-household → store via the household plane (a
  small manifest type) OR the private plane; mirror how user matches were stored. If that's heavy, the
  match can ride the existing ingredient-preference/private-plane store. Keep it minimal.
- **Event-menu / event-meal-recipe / rebalance = LLM via AIService** (port the prompts from event_ai.py +
  the rebalance logic; mirror WeekGenPrompt/MealPlanSchema). Apply through the CloudKit repos.
- **No-key UX:** the LLM features show "add your key" (AI-1 pattern); nutrition works WITHOUT a key.

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| `NutritionCalculator` | new (SimmerSmithKit) | port `calculate_recipe_nutrition` + `MacroBreakdown` scaling + unit conversion (`_macros_for_reference`/`_calories_for_reference`): given recipe ingredients + catalog macro lookups → `NutritionSummary` (total + per-serving + coverage + unmatched). Pure, headless-testable (inject the catalog-lookup closure). |
| catalog macro read | modify (PublicCatalogReader / BaseIngredient decode) | ensure the public catalog read decodes the macro fields (protein/carbs/fat/fiber) if the records carry them; expose a `macros(forIngredient:)` lookup the calculator uses. If records lack macros → calories-only + the flag. |
| nutrition search/match | modify (AppState / a small repo) | `searchNutritionItems` → read the catalog (PublicCatalogReader name search) instead of Fly; `saveIngredientNutritionMatch` → store the user's ingredient→item match (household/private plane). |
| event/rebalance prompts | new (AIProviderKit) | Swift prompt-builders + schemas + parsers for: EVENT MENU (event + attendees/constraints → dishes with compatible_guests, port event_ai._build_prompt + the allergy-safety rule), EVENT MEAL RECIPE (→ RecipeDraft, reuse the recipe-extraction schema from AI-2), DAY REBALANCE (a day's meals + goal → rebalanced meals). Headless-test builders + parsers. |
| `AppState` rewire | modify (+Recipes/+Events/+Weeks/+Ingredients) | nutrition → NutritionCalculator + catalog; generateEventMenu → AIService → parse → `EventRepository.addEventMeal` per dish + `refreshEventGrocery`; generateEventMealRecipe → AIService → RecipeDraft (save path already through RecipeRepository) + link to the event meal; rebalanceDay → AIService → `WeekRepository.saveWeekMeals`. Un-gate the `isCloudKitOnly` guards. |

## 3. Reuse / do-not-rebuild
- AIService.generate / BYOKeyProvider (AI-1) — the LLM features.
- RecipeRepository.save (recipe drafts), EventRepository.addEventMeal/refreshEventGrocery, WeekRepository.saveWeekMeals — the apply paths (mostly wired).
- PublicCatalogReader (SP-A Phase 6) — the catalog for nutrition.
- NutritionSummary / MacroBreakdown domain types (exist on iOS) — keep.

## 4. Verification
- **Headless:** NutritionCalculator (a recipe with known ingredients + injected catalog macros → correct
  totals/per-serving/coverage; unmatched ingredient handling; unit conversion); the event-menu /
  rebalance prompt-builders + parsers round-trip; the allergy-safety in the event-menu prompt.
- **On-device (TestFlight):** a recipe's nutrition computes from the catalog (calorie-level at least);
  nutrition search returns catalog items; generate an event menu → meals appear on the event + grocery
  regenerates; generate an event-meal recipe → saves + links; rebalance a day → the day's meals update.

## 5. Risks
- **Catalog macro availability** — the #1 unknown: does the public catalog expose full macros? Verify
  first; degrade to calorie-level + flag if not (don't block).
- **Nutrition unit conversion fidelity** — port `_macros_for_reference`/`_calories_for_reference` carefully
  (reference amounts/units, scaling); TDD against the server's behavior.
- **Event-menu allergy safety** — the prompt must keep the "NEVER include an allergen for a flagged guest"
  rule; the menu is user-reviewed before meals are added, so no hard gate, but keep the rule in the prompt.
- **Apply correctness** — event meals add through EventRepository (grocery regenerates); rebalance through
  WeekRepository (grocery regenerates). Don't bypass.
- **Possible small manifest type** for IngredientNutritionMatch → a schema deploy (flag if added).
