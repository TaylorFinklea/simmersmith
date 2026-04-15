# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-15

Massive feature sprint across backend and iOS. Completed M1 (AI Planning Excellence), built M2 backend (Kroger pricing), and started M3 (Google Sign-In + iOS store/pricing UI).

**What was done:**

### M1: AI Planning Excellence (complete)
- `PlanningContext` dataclass and `gather_planning_context()` in `week_planner.py`
- Enhanced AI prompt with preference signals, staples, recent meals, stronger rules
- `validate_plan_guardrails()` and `score_generated_plan()`
- 19 new tests in `tests/test_week_planner.py`

### M2: Kroger Grocery Pricing (backend complete)
- `app/services/kroger.py` — Kroger API client (OAuth2, store search, product pricing)
- `fetch_kroger_pricing()` in `app/services/pricing.py`
- `GET /api/stores/search` and `POST /api/weeks/{id}/pricing/fetch` endpoints
- Relaxed retailer schema from Literal to `str`
- 12 new tests in `tests/test_kroger.py`

### M3: App Store Submission (in progress)
- **Google Sign-In**: GoogleSignIn-iOS SPM dependency, `GIDSignIn` wired in SignInView, `signInWithGoogle()` in AppState + API client
- **Store selection UI**: New `StoreSelectionView` (zip search → store picker → save to profile), Grocery section added to SettingsView
- **Price display**: Kroger prices shown inline on grocery items, weekly estimated total at top
- **API client**: Added `searchStores()`, `fetchPricing()`, `getPricing()`, `StoreLocation`, `PricingResponse` models

## Production

- **URL**: https://simmersmith.fly.dev
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **TestFlight**: v1.0.0 build 3 uploaded (untested)

## Build Status

- Backend: ruff clean, pytest 96/96 pass
- Swift tests: 26/26 pass
- iOS build: pending (GoogleSignIn SPM resolving)
- TestFlight: UPLOADED (build 3, not yet tested)
- Production: deployed and healthy

## Blockers

- **iOS build**: Needs verification after GoogleSignIn SPM resolution
- **Kroger credentials**: Need to register at developer.kroger.com
- **Google Sign-In**: Need Google Cloud Console iOS client ID configured
- **TestFlight**: Build 3 untested on device
