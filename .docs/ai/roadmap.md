# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

SimmerSmith is an AI-first meal planning app for the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. iOS is the primary client, FastAPI on Fly.io with Postgres is the backend.

**Design direction**: Rich & dark editorial aesthetic with AI as a prominent floating action. Week, Recipes, and Assistant are the three core tabs.

## Infrastructure (complete)

- [x] Backend deployed on Fly.io + Fly Postgres
- [x] Apple/Google auth endpoints + session JWT
- [x] Multi-user data isolation (65 tests + 7 isolation tests)
- [x] Code quality audit + security hardening
- [x] Backend + iOS module decomposition

## R1: Core Flows (complete)

- [x] Sign in with Apple (iOS -> backend -> session JWT)
- [x] AI week planning (prompt -> OpenAI -> 21 meals + recipes)
- [x] Grocery generation (auto from AI draft)
- [x] Recipe import (in-app browser + HTML extraction)
- [x] Recipe UX (ingredient autocomplete, editorial detail view)

## R2: Visual Redesign (complete)

- [x] Design system (SMColor, SMFont, SMSpacing, SMRadius)
- [x] Dark theme forced app-wide
- [x] 3-tab structure (Week, Recipes, Assistant) + Settings as sheet
- [x] Week: today/tomorrow/rest sections, interactive meal cards, week navigation, empty slot quick-add, meal move/swap, recipe linking
- [x] Recipes: curated sections (Tonight's Dinner, This Week, Favorites, Recently Added), list/gallery toggle, meal-type filters, wrapping chips
- [x] Recipe detail: ingredients/steps toggle, compact calorie chips, wrapping metadata
- [x] Assistant: dark chat theme
- [x] Settings: dark sheet with sign-out
- [x] Grocery: dark sheet with Done button
- [x] Sign-in: Apple + Google buttons (Google placeholder)

## R3: TestFlight Prep (complete)

- [x] ExportOptions.plist for App Store Connect upload
- [x] Version bumped to 1.0.0 (build 3)
- [x] Archive + export IPA
- [x] Upload to TestFlight
- [x] Privacy policy URL

## M1: AI Planning Excellence (complete)

Make the AI the star of the app. The planner now uses preference signals, meal history, staples, and feedback to generate personalized plans.

- [x] Preference-aware week planning (feed PreferenceSignal scores into AI prompt)
- [x] History-aware deduplication (pass recent 2-3 weeks of meals, avoid repeats)
- [x] Feedback loop (deprioritize poorly-rated meals/cuisines via signal scores)
- [x] Staple awareness (tell AI what's in the pantry to leverage)
- [x] Post-generation quality scoring (score_meal_candidate on each recipe)
- [x] Deduplication guardrails (max 3 reuses per recipe per week)

## M2: Store-Specific Grocery Pricing (complete)

Must-have for launch. Kroger API selected as primary integration.

- [x] Research and select grocery pricing API — Kroger API (free, real store prices, 2,750+ stores)
- [x] Kroger API client (OAuth2, product search, location search)
- [x] Live pricing fetch endpoint (POST /api/weeks/{id}/pricing/fetch)
- [x] Store search endpoint (GET /api/stores/search?zip=...)
- [x] Relaxed retailer schema (supports kroger + existing retailers)
- [x] Store selection + configuration in iOS (`StoreSelectionView`)
- [x] Price display in grocery list (per-item + weekly total)
- [x] "Fetch Kroger prices" button in Grocery view
- [ ] Instacart "shop now" integration (secondary, affiliate revenue — deferred)
- [ ] Spoonacular estimated pricing fallback (deferred)

## M3: App Store Submission (in progress)

Complete remaining launch prerequisites and submit.

- [ ] TestFlight validation + bug fixes (build 8 on device, eating-out / timezone / Fetch Prices fixes shipped)
- [x] Google Sign-In SDK integration (GoogleSignIn-iOS SPM, restore-on-launch + signOut wired)
- [ ] App Store metadata (description, keywords, category, screenshots)
- [ ] Submit for App Store review

## M4: Nutrition-Aware AI + Dietary Goals (complete)

> Spec: `.docs/ai/phases/nutrition-goals-spec.md`

Post-launch stickiness milestone. Users set a dietary goal; the AI planner hits it; the app shows per-day and per-week macro progress. Builds on the existing USDA FDC ingredient catalog. Enables the future premium tier.

- [x] Ingredient macros (protein/carbs/fat/fiber) via Alembic migration
- [x] Curated macro seed (~82 common ingredients) + USDA/OFF ingest extended to capture macros
- [x] `DietaryGoal` model + settings UI
- [x] Per-meal / per-day / per-week macro aggregation on `WeekOut`
- [x] Planner prompt + post-generation scoring against the goal (macro-drift flags)
- [x] iOS macro rings on Today hero + each day card + weekly total chip
- [x] Day-breakdown nutrition sheet
- [x] "Rebalance this day" AI CTA when a day drifts ≥±15%

## M5: Freemium + Subscription (next)

> Spec: `.docs/ai/phases/freemium-subscription-spec.md`

The AI generations + Kroger + macros cost real money to run. Ship StoreKit 2 + server-enforced usage limits so the app can pay for itself.

- [ ] `Subscription` + `UsageCounter` models + Alembic migration
- [ ] `is_pro` / `ensure_action_allowed` / 402-on-limit gate on AI/pricing/rebalance endpoints
- [ ] Apple JWS verification + `POST /api/subscriptions/verify` + App Store Server Notifications v2 webhook
- [ ] StoreKit 2 client + paywall sheet + Settings subscription row
- [ ] App Store Connect products (`simmersmith.pro.monthly`, `.annual`) + TestFlight sandbox validation

## M6: Post-Launch Growth

After M5 is monetized.

- [ ] Household sharing tied to a Pro seat
- [ ] Recipe images (AI-generated or fetched)
- [ ] Smart substitutions powered by ingredient preferences
- [ ] Remote push notifications from backend (APNs integration)
- [ ] Proactive intelligence (leftover tracking, weekly theme, calendar-aware planning)

## Backlog

<!-- tier3_owner: claude -->

### Opus (design + cross-cutting)
- [ ] Design the AI preference interview conversation flow
- [ ] Design the freemium gate architecture

## Constraints

- AI is the primary interaction model
- Do not silently persist AI-generated content
- Postgres-only (Fly.io)
- Single-user accounts at launch
- MCP/agent access is a launch differentiator
