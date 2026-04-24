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

## M5: Freemium + Subscription (deferred — postponed 2026-04-20)

> Spec: `.docs/ai/phases/freemium-subscription-spec.md`

The AI generations + Kroger + macros cost real money to run. Ship StoreKit 2 + server-enforced usage limits so the app can pay for itself.

- [ ] `Subscription` + `UsageCounter` models + Alembic migration
- [ ] `is_pro` / `ensure_action_allowed` / 402-on-limit gate on AI/pricing/rebalance endpoints
- [ ] Apple JWS verification + `POST /api/subscriptions/verify` + App Store Server Notifications v2 webhook
- [ ] StoreKit 2 client + paywall sheet + Settings subscription row
- [ ] App Store Connect products (`simmersmith.pro.monthly`, `.annual`) + TestFlight sandbox validation

## M6: Conversational Planning (complete)

> Spec: `.docs/ai/phases/conversational-planning-spec.md`

Reworked the AI experience from two disconnected surfaces (one-shot sparkle + isolated Assistant chat) into one conversation. The Assistant has tool access to the current week (read + write), the Week page is the execution view of what the Assistant built, and "plan my week" is a dialogue.

- [x] Assistant tool registry + gate reuse (11 tools)
- [x] Mutation tools (add/swap/remove meal, rebalance day, fetch pricing, set dietary goal)
- [x] Incremental `generate_week_plan` (day-by-day commit + `week.updated` per day)
- [x] Week-aware system prompt + `linked_week_id` per thread
- [x] iOS tool-call cards in Assistant + `week.updated` SSE handler
- [x] Week → Assistant entry points (sparkle opens a linked planning thread)
- [x] Per-day "Ask AI" button + active-chat chip on the Week page

Deferred (future polish):
- Anthropic tool-use support (OpenAI direct only for now; Anthropic threads fall back to the envelope-JSON path)
- True per-day AI generation (one call per day) — current implementation keeps a single AI call but applies day-by-day so the client sees progressive state updates

## M7: Assistant Polish + Post-Launch Growth

After M6 is shipped.

### Assistant polish (open from the 2026-04-20 shakedown)
- [x] True token-by-token streaming via OpenAI `stream: true` (was: chunk-on-complete)
- [x] Tolerant `AssistantToolCall` decoder (missing `ok`/`detail` on running events)
- [x] Fix "cancelled" error on pull-to-refresh — dedicated streaming URLSession so it's isolated from the shared session
- [x] Hallucination guardrail — amber "Nothing changed" affordance when the AI narrates an action without firing a tool
- [x] Persist streamed deltas server-side as they arrive (throttled to 500ms)
- [x] Cancel the SSE stream + abort the assistant turn when the user dismisses the sheet mid-stream
- [ ] Anthropic tool-use support (OpenAI-direct only today; Anthropic falls back to envelope JSON) — deferred
- [ ] True per-day AI generation (one AI call per day of `generate_week_plan`) — deferred, 7× token cost

### Post-launch growth
- [ ] Household sharing tied to a Pro seat
- [ ] Recipe images (AI-generated or fetched)
- [ ] Remote push notifications from backend (APNs integration)
- [ ] Proactive intelligence (leftover tracking, weekly theme, calendar-aware planning)

## M8: Smart Substitutions (complete)

> Spec: `.docs/ai/phases/smart-substitutions-spec.md`

AI-powered per-ingredient substitutions. Tapping the wand next to any
ingredient in recipe detail opens a sheet that asks the AI for 3-5
alternatives (with a short reason + optional adjusted quantity/unit),
respects the user's active ingredient preferences, and applies the
picked one via the existing recipe upsert flow.

- [x] `POST /api/recipes/{recipe_id}/ai/substitute` endpoint
- [x] `app/services/substitution_ai.py` + strict-JSON response parser
- [x] Preference-aware prompt (avoids re-introducing flagged items)
- [x] iOS `SubstitutionSheetView` + per-ingredient wand affordance
- [x] `applySubstitution` on AppState reusing `saveRecipe` upsert
- [x] "Replace recipe" vs. "Save as variation" choice after picking a
      substitute — variation mode uses the existing `variationDraft()`
      machinery so the new recipe links back via `baseRecipeId`

## M9: Preference-Aware Planner (complete)

Closes the loop on M8. Rather than reacting to disliked ingredients
after they show up, the week planner now avoids them at generation
time. Users can flag ingredients via the wand menu on any recipe or
via Settings → Ingredient Preferences.

- [x] Backend: `choice_mode` accepts `avoid` + `allergy`;
      `gather_planning_context` merges these into `hard_avoids` and
      surfaces allergies on their own emphasized prompt line
- [x] Backend: `score_meal_candidate` flips `blocked=True` for meals
      containing avoid/allergy-flagged ingredients (defense in depth)
- [x] iOS Settings: amber "Avoid" / red "Allergy" pills on the
      preference list; editor hides brand/variation when irrelevant
- [x] iOS Recipe Detail: wand button became a Menu with "Substitute",
      "Never use this in my plans", and "I'm allergic to this"
      — catalog-resolved ingredients only

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
