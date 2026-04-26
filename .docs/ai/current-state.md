# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-25 (continued)

Shipped **M12 Quick AI Wins** in four phases on dev. Build is queued
at `CURRENT_PROJECT_VERSION 16` but **NOT yet deployed to Fly or
uploaded to TestFlight** — those are the next user-driven actions.

M11 (Photo-First AI) shipped earlier this session and was deployed
to Fly + TestFlight build 15. M12 builds on top with four
lightweight features.

### What landed this session (M12)

**Phase 1 — Pairings on recipe detail (commit `52dfcd8`)**
- `app/services/pairing_ai.py`: strict-JSON `suggest_pairings(recipe)`
  returning 3 dishes with `role: side|appetizer|dessert|drink` and
  one-sentence reasons.
- `POST /api/recipes/{id}/pairings` route + 3 tests.
- iOS `RecipePairingsCard` lives just above Notes in recipe detail.
  Collapsed by default — single "Suggest pairings" button so we
  don't burn an AI call on every detail open.

**Phase 2 — Difficulty + kid-friendly (commit `b15a1d6`)**
- Alembic migration `20260425_0021_recipe_difficulty.py` adds
  `difficulty_score INT NULL CHECK (BETWEEN 1 AND 5)` +
  `kid_friendly BOOL DEFAULT false` to `recipes`.
- `app/services/recipe_difficulty_ai.py` infers both on first save
  via OpenAI/Anthropic. Wrapped in try/except — never blocks save.
- 4 tests confirm inference fires, skips when score already set,
  skips when no ingredients, and a provider error doesn't 500.
- iOS: `DifficultyFilter` enum + `difficultyFilterPills` strip in
  RecipesView (Any / Easy / Medium / Hard / Kid-friendly), plus
  Easy/Medium/Hard + Kid-friendly pills in the recipe detail header.

**Phase 3 — User region + in-season produce (commit `fccdaa6`)**
- `app/services/seasonal_ai.py`: strict-JSON `seasonal_produce`
  returning 5–8 produce items with `why_now` + `peak_score`.
  Module-level dict cache keyed by `(region, year, month)`,
  thread-safe via `threading.Lock`.
- `GET /api/seasonal/produce` (in new `app/api/discovery.py` router)
  reads `user_region` from ProfileSetting — fallback "United States".
- iOS: `InSeasonStrip` horizontal chip strip above Week day cards.
  Tap a chip → `InSeasonDetailSheet` with "why now" + Find recipes
  hand-off (uses new `recipesPrefilledSearch` AppState shuttle).
- Settings gains a new "Location" section with a free-text region
  field + Save button.
- 4 tests cover route happy path, cache hits, region fallback.

**Phase 4 — AI recipe web search (commit `db0c9f4`)**
- `app/services/recipe_search_ai.py` calls **OpenAI Responses API**
  with the `web_search` tool. The `_AIRecipe` strict-JSON shape maps
  to a `RecipePayload`; `source_url` + `source_label` from the cited
  page propagate to the recipe.
- `POST /api/recipes/ai/web-search` route + 4 tests.
- iOS `RecipeWebSearchSheet`: query input → preview card with source
  URL + ingredient count → "Open in editor" → opens
  `RecipeEditorView` with the draft. Nothing persists until the user
  saves — same flow URL/photo imports use.
- Anthropic web search is a future follow-up — feature gates on
  OpenAI for now and 502s if only Anthropic is configured.

**TestFlight prep (commit `?` pending)**
- `SimmerSmith/project.yml` `CURRENT_PROJECT_VERSION` 15 → 16.
- `xcodegen generate` re-run.
- Backend deploy + archive/upload pending user confirmation.

### Production state

- **URL**: https://simmersmith.fly.dev (healthy; current = M11.
  M12 backend NOT yet deployed.)
- **Model**: `gpt-5.4-mini` for general AI. Web-search route uses
  whatever OpenAI model is configured (Responses API supports
  gpt-4o, gpt-4o-mini, etc.).
- **TestFlight**: build 15 (M11). Build 16 archived locally, pending
  user-confirmed upload.

### Build status

- Backend: ruff clean, pytest 180/180 pass
- Swift tests: 26/26 pass
- iOS build: green on `generic/platform=iOS Simulator`
- Fly production: healthy; STALE wrt M12 backend
- TestFlight: STALE wrt M12

## Files Changed (this session)

Backend (new):
- `app/services/pairing_ai.py`
- `app/services/recipe_difficulty_ai.py`
- `app/services/seasonal_ai.py`
- `app/services/recipe_search_ai.py`
- `app/api/discovery.py`
- `alembic/versions/20260425_0021_recipe_difficulty.py`
- `tests/test_pairings_api.py`
- `tests/test_recipe_difficulty.py`
- `tests/test_seasonal_api.py`
- `tests/test_recipe_search_api.py`

Backend (extended):
- `app/api/recipes.py` (pairings + cook-check routes; opportunistic
  difficulty inference; module logger)
- `app/main.py` (registers discovery_router)
- `app/models/recipe.py` (difficulty_score + kid_friendly columns)
- `app/schemas/recipe.py` (PairingOptionOut, RecipePairingsResponse;
  RecipePayload gains the two new fields)
- `app/schemas/__init__.py` (exports)
- `app/services/drafts.py` (upsert persists the new fields)
- `app/services/presenters.py` (recipe_payload exposes them)

iOS (new):
- `SimmerSmith/SimmerSmith/App/AppState+Seasonal.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipePairingsCard.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipeWebSearchSheet.swift`
- `SimmerSmith/SimmerSmith/Features/Week/InSeasonStrip.swift`

iOS (extended):
- `SimmerSmithKit/Sources/SimmerSmithKit/Models/SimmerSmithModels.swift`
  (PairingOption, RecipePairings, InSeasonItem; RecipeSummary +
  RecipeDraft gain difficultyScore + kidFriendly)
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift`
- `SimmerSmith/SimmerSmith/App/AppState.swift`
  (seasonalProduce + seasonalProduceFetchedAt + recipesPrefilledSearch
  + userRegionDraft state; sync hooks)
- `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift` (suggestRecipePairings, searchRecipeOnWeb)
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipeDetailView.swift`
- `SimmerSmith/SimmerSmith/Features/Recipes/RecipesView.swift`
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift`
- `SimmerSmith/SimmerSmith/Features/Week/WeekView.swift`
- `SimmerSmith/SimmerSmith/Info.plist`
- `SimmerSmith/project.yml` (build 16 bump)

Docs:
- `.docs/ai/roadmap.md` — M12 marked complete
- `.docs/ai/current-state.md` — this file
- `.docs/ai/next-steps.md` — refreshed for deploy + TestFlight cut
