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

## M1: AI Planning Excellence (in progress)

Make the AI the star of the app. The planner currently uses only flat profile settings; the preference/feedback/history infrastructure exists but is unused.

- [ ] Preference-aware week planning (feed PreferenceSignal scores into AI prompt)
- [ ] History-aware deduplication (pass recent 2-3 weeks of meals, avoid repeats)
- [ ] Feedback loop (deprioritize poorly-rated meals/cuisines via signal scores)
- [ ] Staple awareness (tell AI what's in the pantry to leverage)
- [ ] Post-generation quality scoring (score_meal_candidate on each recipe)
- [ ] Deduplication guardrails (max 3 reuses per recipe per week)

## M2: Store-Specific Grocery Pricing

Must-have for launch. Integrate third-party grocery pricing API.

- [ ] Research and select grocery pricing API (Instacart/Kroger/Spoonacular)
- [ ] Store selection + configuration in iOS
- [ ] Price display in grocery list
- [ ] Price optimization suggestions

## M3: App Store Submission

Complete remaining launch prerequisites and submit.

- [ ] TestFlight validation + bug fixes
- [ ] Google Sign-In SDK integration
- [ ] App Store metadata (description, keywords, category, screenshots)
- [ ] Submit for App Store review

## M4: Post-Launch

Growth features after the core loop is validated.

- [ ] Freemium boundaries (AI usage limits, premium tier)
- [ ] Household sharing
- [ ] Recipe images (AI-generated or fetched)
- [ ] Advanced AI features (nutrition tracking, dietary progress, smart substitutions)
- [ ] Remote push notifications from backend (APNs integration)

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
