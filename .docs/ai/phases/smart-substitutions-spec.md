# M8: Smart Substitutions — Spec

## Context

Users viewing a recipe sometimes can't (allergy), don't want to
(dislike), or don't have (out of stock) one of the ingredients. Today
their only option is to edit the recipe manually or ask the assistant
in free form. M8 adds a single-tap substitution flow that uses the
existing AI infrastructure + ingredient preferences to suggest
ingredient-aware alternatives.

## Scope (MVP, this session)

1. Backend endpoint that takes `(recipe_id, ingredient_id)` and returns
   3-5 substitution options with a short "why this works" reason.
2. iOS: tap an ingredient in Recipe Detail → sheet with suggestions →
   pick one → the recipe is updated locally + persisted server-side.
3. Suggestions respect any existing `IngredientPreference` rows — if
   the user has flagged an ingredient as active + has a preferred
   variation / brand, the AI is told to avoid re-introducing disliked
   ingredients.

Out of scope this session (can follow-up later):
- A separate "dislike / allergy / avoid" preference flag (current
  model is preference-positive only; we'll infer from context).
- AI-driven bulk substitution ("make this dairy-free"). That's the
  existing `recipe_ai.build_variation_draft` flow — keep them separate.
- Substitutions in the meal planner (week view).

## Design

### Backend

**New endpoint**: `POST /api/recipes/{recipe_id}/substitute`

Request:
```json
{ "ingredient_id": "...", "hint": "don't have sour cream" }
```

Response:
```json
{
  "suggestions": [
    { "name": "Greek yogurt", "reason": "Same tang, stirs in smoothly", "quantity": "1/2 cup" },
    { "name": "Crème fraîche", "reason": "Richer but same acidity" },
    ...
  ]
}
```

**New service**: `app/services/substitution_ai.py`
- `suggest_substitutions(recipe, target_ingredient, user_prefs, settings)` → list of suggestions.
- Uses `resolve_ai_execution_target` + `run_direct_provider` (same pattern as `recipe_ai.build_variation_draft`).
- Prompt includes: recipe title, all ingredients, the target ingredient, any hint, and any active user preferences relevant to ingredients in the recipe.
- Response parsed as strict JSON via pydantic.

**New schema**:
- `SubstitutionSuggestion { name, reason, quantity? }`
- `SubstituteRequest { ingredient_id, hint? }`
- `SubstituteResponse { suggestions: list[SubstitutionSuggestion] }`

**Reused utilities**:
- `app/services/ai.py` — provider target resolution.
- `app/services/drafts.py::upsert_recipe` — for applying a picked substitution (iOS replaces the ingredient in the payload + round-trips).

### iOS

**Entry point**: per-ingredient trailing button in `RecipeDetailView.ingredientRow` — a subtle `wand.and.stars` icon next to each ingredient, visible on tap.

**Sheet**: `SubstitutionSheetView`
- Header: "Substitute <ingredient name>"
- Input: optional hint field ("why are you swapping?")
- Content: list of suggestions (name + reason + optional quantity), tappable.
- Loading state while fetching.
- Picking one → dismisses, updates the recipe locally, calls existing `saveRecipe` flow.

**New APIClient method**: `suggestSubstitutions(recipeID, ingredientID, hint?)` returning the response.

**New AppState method**: `substituteIngredient(recipeID, ingredientID, with: SubstitutionSuggestion)` — replaces the ingredient locally + persists.

## Critical files

Backend:
- `app/api/recipes.py` — new route
- `app/services/substitution_ai.py` (new)
- `app/schemas/recipe.py` (or equivalent) — new schemas
- `app/services/drafts.py` — existing `upsert_recipe`, reused as-is
- `tests/test_recipe_ai.py` or `test_api.py` — integration test

iOS:
- `SimmerSmith/.../Features/Recipes/RecipeDetailView.swift` — add button + sheet mount
- `SimmerSmith/.../Features/Recipes/SubstitutionSheetView.swift` (new)
- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift` — new `suggestSubstitutions`
- `SimmerSmithKit/.../Models/SimmerSmithModels.swift` — `SubstitutionSuggestion`
- `SimmerSmith/.../App/AppState+Recipes.swift` (or equivalent) — apply method

## Verification

- `.venv/bin/pytest -v` (new test covering the endpoint with a fake AI target)
- `xcodebuild ... build` green
- E2E: open a recipe → tap the wand on an ingredient → see suggestions →
  pick one → ingredient updates in the recipe and persists after reload.
