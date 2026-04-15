# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-15

Two major features implemented: AI planning quality and Kroger grocery pricing integration.

**What was done:**

### M1: AI Planning Excellence (complete)
- Added `PlanningContext` dataclass and `gather_planning_context()` to `week_planner.py`
- Enhanced the AI system prompt with preference signals (hard avoids, strong likes, cuisine preferences), pantry staples, recent meal history, and stronger planning rules
- Added `validate_plan_guardrails()` for deduplication and avoided-ingredient checking
- Added `score_generated_plan()` using existing `score_meal_candidate()` for per-recipe scoring
- Wired context gathering and scoring into the generate endpoint
- 19 new tests in `tests/test_week_planner.py`

### M2: Kroger Grocery Pricing (backend complete)
- Built `app/services/kroger.py` — Kroger API client with OAuth2, location search, product price search
- Added `fetch_kroger_pricing()` to `app/services/pricing.py`
- Added `GET /api/stores/search` endpoint for store location search by zip code
- Added `POST /api/weeks/{week_id}/pricing/fetch` endpoint for live Kroger pricing
- Relaxed retailer schema from hardcoded Literal to `str`
- Added `kroger_client_id` and `kroger_client_secret` to config
- 12 new tests in `tests/test_kroger.py`

## Production

- **URL**: https://simmersmith.fly.dev
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **TestFlight**: v1.0.0 build 3 uploaded (untested)

## Build Status

- Backend: ruff ✅, pytest 96/96 ✅
- iOS: BUILD SUCCEEDED ✅ (last checked April 14)
- Swift tests: 26/26 ✅ (last checked April 14)
- TestFlight: UPLOADED (build 3, not yet tested)
- Production: deployed and healthy ✅

## Architecture

- **Backend**: FastAPI + SQLAlchemy on Fly.io + Fly Postgres
- **Auth**: Apple Sign-In (JWKS verification) → session JWT. Legacy bearer fallback.
- **AI**: OpenAI (gpt-5.4-mini) for week planning. Planner now uses PlanningContext (preferences, staples, history, feedback signals).
- **Grocery Pricing**: Kroger API (OAuth2, product search at specific store locations). Existing import flow preserved for aldi/walmart/sams_club.
- **iOS**: SwiftUI, 3-tab layout (Week/Recipes/Assistant), dark theme design system

## Blockers

None. Kroger API credentials needed for live testing (register at developer.kroger.com).
