# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

SimmerSmith is an AI-first meal planning app for the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. iOS is the primary client, FastAPI on Fly.io with Postgres is the backend.

**Design direction**: Rich & dark editorial aesthetic with AI as a prominent floating action. Week, Recipes, and Assistant are the three core tabs.

## Now / Next / Later

Active items. Trim as completed.

### Now (validation + commit)

Three milestones shipped this session — M18 push notifications, M17.1
image-gen cost telemetry, and M19/M7 Phase 5 Anthropic tool-use. Fly is
on v58 (carries M17, M18, M17.1). M19 is uncommitted at session end.

Open follow-ups:
- Commit M19 + `fly deploy` to ship Anthropic tool-use server-side.
- Install TestFlight build 28 → sign in → accept the auto-fired APNs
  permission prompt → run the `POST /api/push/test` curl smoke test →
  wait for the 17:00 local "tonight's meal" tick.
- Dogfood M19: Settings → AI provider → Anthropic → planning thread →
  "add salmon to Tuesday dinner" → confirm tool fires + week refreshes
  + iOS shows the same `assistant.tool_call` card OpenAI shows.

### Awaiting User / External
- TestFlight build 26 dogfooding feedback (wife's iPhone).
- Add internal testers to TestFlight if not done.
- Register at developer.kroger.com — `client_id` + `client_secret`.
- `fly secrets set SIMMERSMITH_KROGER_CLIENT_ID=… SIMMERSMITH_KROGER_CLIENT_SECRET=…`.

### Next (M22 in flight, M23 candidates)

**M22 — Grocery list polish + Reminders sync** (in flight 2026-05-03)
- Smart-merge regen preserves user edits (`is_user_added`,
  `is_user_removed`, `quantity_override`, `unit_override`,
  `notes_override`).
- Server-side household-shared check state.
- Per-event `auto_merge_grocery` toggle (default on).
- 5 new mutation routes under `/api/weeks/{id}/grocery/...`.
- iOS 5th tab + add/edit/remove + EventKit two-way Reminders bridge.
- Settings → Grocery → "Sync to Reminders" with list picker.
- M23 = the cart-automation skill (separate milestone, see below).

**M23 candidates** (post-M22)
- **Cart-automation skill** (Aldi / Walmart / Sam's Club / Instacart).
  Local Claude Code + Codex skill that reads the chosen Reminders
  list, runs Playwright/browser-use against each store, computes a
  store-split, and fills carts to checkout. Skill uses the
  parse-friendly Reminders title format `"<qty> <unit> <name>"`
  established by M22.
- **Anthropic web search support** for the recipe finder (Messages
  API `web_search_20250305` — currently OpenAI-only).
- **Owner role transfer** (M21 follow-up).
- **Removing a member as owner** (M21 follow-up).

### Soon
- Backfill helper: a Settings button that runs difficulty inference on every recipe still missing a score.
- Instacart "shop now" affiliate integration (M2 secondary).
- Spoonacular estimated pricing fallback (M2 secondary).

### Later
- Provider-aware prompt tuning if Gemini benefits from a different prompt shape (M17 follow-up).
- Image-gen failover (OpenAI 5xx → retry once via Gemini) — saved for if dogfooding demands it.
- Per-user push quiet-hours customization (M18 ships a hard 22:00–07:00 window).
- Thread-deep-link routing for the AI-finished push (today's deep link parses `?thread_id=` but only routes to the assistant tab; opening the specific thread is a follow-up).
- Multi-machine push scheduler safety (Postgres advisory lock) — only if we scale past one Fly machine.

### Deferred (M7 Phases 5 + 6)
- Phase 5: Anthropic tool-use support — refactor `_run_openai_tool_loop` into a provider-agnostic adapter.
- Phase 6: True per-day `generate_week_plan` (7× tokens; flag cost before shipping).

### Deferred (do not restart without authorization)
- **M5 Freemium + Subscription**: postponed 2026-04-20. Saved to memory (`project_m5_freemium_deferred.md`).

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
- [x] Phase 5 — Anthropic tool-use parity (shipped 2026-04-30 as M19; provider-agnostic adapter)
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

## M10: Event Plans (complete)

> Spec: `.docs/ai/phases/event-plans-spec.md`

A parallel planning surface for one-off gatherings (holidays,
birthdays, dinner parties). Structured reusable guest list with saved
allergies / dietary notes; AI menu generation that handles mixed
constraints (design for the majority, ensure each constrained guest
has at least one compatible dish per role); separate event grocery
list with merge-into-week support.

- [x] Phase 1 — backend data model + CRUD (5 tables, ownership tests)
- [x] Phase 2 — AI event menu generation w/ `constraint_coverage`
      mapped back to guest_ids
- [x] Phase 3 — event grocery list + merge/unmerge with weekly list
      (idempotent via `merged_into_week_id`)
- [x] Phase 4 — iOS Events tab, create flow, detail view
- [x] Phase 5 — Guest editor sheet (shared from event create; Settings
      entry point deferred as follow-up polish)
- [x] Phase 6 — Merge-to-week UI with current-week detection + undo

## M10.1: Event Polish v2 (complete)

Dogfooding fixes after first real Easter use:

- [x] Backend: `_aggregate_event_rows` skips assignee-brought meals so
      the host's grocery list reflects only what they're shopping for
- [x] iOS: "Guests bringing" subsection on event detail
- [x] iOS: `EventEditSheet` for editing event metadata after creation
- [x] iOS: ellipsis menu on event detail with Edit + Delete + dialog

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

## M11: Photo-First AI (complete on dev; awaiting deploy + TestFlight 15)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

A product audit revealed that photo / multimodal AI was mentioned three
times in the original product notes and was entirely absent. M11 adds
all four flows in a single milestone, and lays the foundation
(`vision_ai`) for the future cooking-coach work.

- [x] Phase 1 — already shipped. Recipe scan via VisionKit /
      `RecipeImportView`'s existing scaffolding (audit blind spot).
- [x] Phase 2 — `app/services/vision_ai.py` foundation. Strict-JSON
      `identify_ingredient` + `check_cooking_progress` with image
      content blocks for OpenAI + Anthropic. 7 tests.
- [x] Phase 3 — Scan ingredient → identify + uses. Backend route +
      iOS `IngredientScannerView` w/ result card + Find Recipes action.
- [x] Phase 4 — Barcode scan → product lookup. Kroger UPC reverse
      lookup + iOS `BarcodeScannerView` (DataScannerViewController) +
      product card. Entry point in GroceryView.
- [x] Phase 5 — Cooking-progress check. Per-step "Check it" camera
      chip in RecipeDetailView opens `CookCheckSheet` → vision call →
      verdict + tip inline.

## M12: Quick AI Wins (complete; shipped to Fly + TestFlight build 16)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Lightweight follow-on to M11. Each phase ships independently.

- [x] Phase 1 — Pairings on recipe detail. `pairing_ai.py` + iOS
      `RecipePairingsCard` (collapsed by default, lazy-loaded on tap).
- [x] Phase 2 — Difficulty + kid-friendly. Alembic migration adds
      `difficulty_score: int? CHECK 1..5` + `kid_friendly: bool`.
      Opportunistic AI inference on save (best-effort). iOS gets
      filter chips and detail-header pills.
- [x] Phase 3 — User region + in-season produce. `seasonal_ai.py`
      with module-level dict cache keyed by `(region, year, month)`.
      iOS adds `InSeasonStrip` above Week day cards + a Settings
      free-text region field.
- [x] Phase 4 — AI recipe web search. OpenAI Responses API +
      `web_search` tool extracts a real recipe with citation. iOS
      `RecipeWebSearchSheet` previews and hands off to the existing
      recipe editor.

## M13: Cooking Mode (complete on dev; awaiting TestFlight 17)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Hands-free, big-text cook flow. Composes the M11 `cook_check` photo
chip and the existing assistant launch context into a focused
full-screen experience. iOS-only — no backend changes.

- [x] Phase 1 — `CookingModeView` skeleton. Big-text steps,
      progress bar, prev/next/ask-assistant/exit buttons, wake-lock,
      long-press step → existing `CookCheckSheet`. Toolbar pan icon
      + "Start cooking" button at the bottom of the steps section
      on `RecipeDetailView`.
- [x] Phase 2 — TTS step readout. `SpokenStepService`
      (`AVSpeechSynthesizer`) speaks each step on entry; mute toggle
      in the top bar persists via UserDefaults; AVAudioSession
      ducks background music during speech.
- [x] Phase 3 — Voice commands. `VoiceCommandService`
      (on-device `SFSpeechRecognizer` + `AVAudioEngine`) recognizes
      next / back / repeat / stop. Auto-restarts every ~50s to dodge
      the ~1-min buffer limit. Live-caption pill, mic toggle,
      confirmation alert before exiting on a heard "stop".
- [x] Phase 4 — Manual quick timers + per-step polish.
      `CookingTimerChip` row (5/10/15/20/Custom), concurrent
      countdowns, haptic + TTS "Timer done." chime. Visible
      "Check it" button per step. "Done" on the last step shows a
      "Nicely done." toast on the recipe detail view.

## M14: AI-generated recipe images (in flight)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Replace the gradient-only header placeholder with one AI-generated
photo per recipe. Phase 1 ships invisible plumbing; Phase 2 wires
generation on save; Phase 3 spreads to list cards + Settings
backfill.

- [x] Phase 1 — Plumbing. `recipe_images` table + serve route +
      iOS `imageURL` field + `RecipeHeaderImage` view replacing the
      gradient block in `RecipeDetailView`.
- [x] Phase 2 — Generation on save. `recipe_image_ai.py` calls
      OpenAI's `/v1/images/generations` (`gpt-image-1`) using the
      existing `SIMMERSMITH_AI_OPENAI_API_KEY`. Best-effort: a
      provider outage never blocks the save.
- [x] Phase 3 — List cards + Settings backfill. `HeroRecipeCard`,
      `CompactRecipeCard`, `RecipeCard`, `RecipeListRow` route through
      a shared `RecipeHeaderImage` view that renders `AsyncImage`
      bytes when present and falls back to the recipe-id-hash
      gradient. `POST /api/recipes/ai/backfill-images` + Settings
      "Generate missing images" button fill in pre-M14 recipes.

## M16: M14 polish — regenerate, manual upload, remove (in flight)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Three small affordances on the recipe detail toolbar so the user
isn't stuck with whatever the AI initially generated.

- [x] Single phase. Three new routes
      (`POST /image/regenerate`, `PUT /image`, `DELETE /image`),
      one shared utility (`PhotoCompression.swift`,
      consolidating the cook-check + memory-photo + image-
      override compression paths), one new sheet
      (`RecipeImageOverrideSheet`), and a Menu integration on
      `RecipeDetailView`. `RecipeHeaderImage` gains an
      `isLoading` overlay so regen shows a spinner.

## M17: Gemini-direct image-gen (complete on dev; awaiting deploy + TestFlight 27)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

The OpenAI image-gen path from M14/M16 gets a sibling Gemini
(`gemini-2.5-flash-image-preview`) path, picked per user via a
Settings toggle stored as a `profile_settings` row. No Alembic
migration. Default stays OpenAI so existing behavior is preserved.

- [x] Single phase. `app/services/recipe_image_ai.py` split into
      `_generate_via_openai` + `_generate_via_gemini` with
      `_resolve_provider(settings, user_settings)` dispatching
      per-call. `is_image_gen_configured` and
      `generate_recipe_image` gain a keyword-only `user_settings`
      param. Three call sites
      (save / backfill / regenerate) load `profile_settings_map`
      and pass it through. iOS Settings adds an OpenAI/Gemini
      Picker; `AppState+Profile.swift` mirrors the existing
      region-save flow.

## M17+ Future image-gen work

- [ ] **Cost telemetry.** Per-provider image-gen counts so we
      can confirm Gemini's cheaper-per-image claim.
- [ ] **Provider-aware prompt tuning.** Both providers currently
      share `_build_prompt`. If Gemini benefits from a different
      shape, split.
- [ ] **Auto-failover.** OpenAI 5xx/timeout → retry once via
      Gemini. Saved for if dogfooding demands it.

## M15: Recipe memories log (in flight)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Replace the static `recipes.memories` text blob with a per-cook
log of time-stamped entries plus optional photo attachments, so a
recipe accrues family history across cooks.

- [x] Phase 1 — Text memories. New `recipe_memories` table with an
      Alembic data-migration that copies any non-empty legacy blob
      into a single seed row per recipe. GET/POST/DELETE routes.
      `RecipeMemoriesSection` replaces the static memories block on
      `RecipeDetailView`; `MemoryComposeSheet` wraps a TextField +
      Save with empty-body validation.
- [x] Phase 2 — Photo attachments. `image_bytes` + `mime_type`
      columns + `GET …/photo` route mirroring the M14
      ETag/immutable-cache pattern. `MemoryComposeSheet` adds a
      `PhotosPicker` row with the same 2048px / JPEG 0.8 ceiling
      `CookCheckSheet` uses; rows render a 60×60 thumbnail when a
      photo exists; tap → full-screen viewer.

## M21: Household sharing (complete on dev; awaiting deploy + TestFlight 32)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Closes the long-standing single-user-per-account gap: spouses /
roommates can now share a Week, Recipe library, Pantry, Events, and
Guests under one household. Per-user data (taste signals, allergies,
push devices, AI provider toggle, timezone) stays user-scoped.

- [x] Phase 1 — Schema. New `households`, `household_members`,
      `household_invitations`, `household_settings` tables. `household_id`
      column on Week / Recipe / Staple / Event / Guest, backfilled from
      one-solo-household-per-user seeded for every existing user.
- [x] Phase 2 — Service rewrite + auth. `CurrentUser` carries
      `household_id` (lazy solo creation on first request). Every
      shared-table query flips from `user_id` to `household_id`.
      Writers populate `household_id` on construct.
- [x] Phase 3 — Invitation API + tests. 5 routes
      (GET/PUT household, POST/DELETE invitations, POST join). Auto-merge
      semantics: joining migrates the joiner's solo content into the
      target household and deletes the empty solo. 12 new tests.
- [x] Phase 4 — iOS surfaces. `HouseholdSnapshot` model + 5 API
      methods + `AppState+Household.swift` + `InvitationSheet`
      (code + ShareLink) + `JoinHouseholdSheet` + `HouseholdSection`
      in Settings between Sync and AI.
- [ ] Phase 5 — Ship. Build bump 31→32, push, fly deploy,
      TestFlight 32, on-device cross-account dogfood.

## M20: M18 follow-up pushes (complete on dev; awaiting commit + deploy + TestFlight 31)

Two missing pieces from M18 push notifications, both small.

- [x] **Cook-mode timer-end local notification.** When the user starts a
      cook-mode timer, schedule a `UNNotificationRequest` so a backgrounded
      timer still fires a banner. Cancel on dismiss or natural fire so
      foreground users don't get a duplicate banner. iOS-only; no backend.
- [x] **AI-finished-thinking push.** Fires after a planning turn that ran
      tools (`generate_week_plan`, etc.). Best-effort `asyncio.create_task`
      from inside the SSE generator after `assistant.completed` is yielded.
      New `push_assistant_done` profile_settings row (default on); third
      Settings toggle. iOS suppresses banners while foregrounded so this
      only surfaces when the user has the app backgrounded mid-turn.
      6 new tests covering the summarizer + per-user gate.

## M19: Anthropic tool-use parity (M7 Phase 5) (complete on dev; awaiting commit + deploy)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Closes the long-standing M6 deferred item: Anthropic users now run the
same 11 tools the OpenAI path runs, instead of falling back to
envelope-JSON parsing. Backend-only milestone — iOS was already
provider-agnostic.

- [x] Single phase. `app/services/assistant_ai.py` gains a
      `ProviderAdapter` ABC + `OpenAIAdapter` + `AnthropicAdapter`.
      `_run_openai_tool_loop` is replaced by `_run_provider_tool_loop`
      driven by an adapter. Dispatch table picks the adapter by
      `target.provider_name`. Anthropic adapter handles the Messages API
      SSE shape (`content_block_start` / `input_json_delta` accumulation
      / `content_block_stop` / `message_delta`/`stop_reason`).
- [x] Tests: 7 new (1 schema parity + 3 Anthropic-loop scenarios + 2
      dispatch routing + 1 import sanity). Existing OpenAI abort test
      updated for the new adapter API. Full suite **242/242**.
- [ ] Commit + `fly deploy` to ship server-side.

## M18: Push notifications (APNs) (Phases 1-4 complete; awaiting deploy + TestFlight 28)

> Spec: `.docs/ai/phases/push-notifications-spec.md`

Backend → device pushes for "tonight's meal is X" (daily, 17:00 local
default) and "you have a Saturday plan to confirm" (Friday 18:00 local
default, only when next week is still draft). Both default ON; the
APNs permission prompt fires automatically once after first sign-in.

- [x] Phase 1 — Backend device registration + APNs sender. `aioapns`
      dep, `push_devices` table (Alembic 0025), `app/services/push_apns.py`,
      `POST/DELETE /api/push/devices`, admin `POST /api/push/test`.
      Token-based APNs auth (`.p8` key shared with Sign In with Apple).
- [x] Phase 2 — Backend scheduler. `apscheduler` dep, in-process
      `AsyncIOScheduler` boots in lifespan when configured. Two interval
      jobs at 5-min cadence: `_tick_tonights_meal` and
      `_tick_saturday_plan`. ZoneInfo-driven local-time matching, hard
      22:00–07:00 quiet-hours skip, in-memory `_sent_today` de-dup.
- [x] Phase 3 — iOS registration + Settings toggles. `PushService`,
      `SimmerSmithAppDelegate`, `AppState+Push.swift`, `NotificationsSection`
      in Settings. `ensurePushBootstrap()` auto-prompts after first
      profile hydration when toggles read enabled.
- [x] Phase 4 — Tests + verification. 18 new tests in `tests/test_push.py`
      including default-on semantics, quiet-hours, toggle-off,
      Saturday-skip-when-confirmed.
- [x] Phase 5 — Production cutover. `fly secrets set` + `fly deploy`
      (Fly v58) + `./scripts/release-ios.sh` cut TestFlight 28. On-device
      validation pending the user installing the build.

## Backlog

> Self-contained items any agent can pick up. Tier hints are advice, not gating.

- [ ] Design the AI preference interview conversation flow. **Tier hint**: needs Opus to scope.
- [ ] Design the freemium gate architecture. **Tier hint**: needs Opus to scope.

## Constraints

- AI is the primary interaction model
- Do not silently persist AI-generated content
- Postgres-only (Fly.io)
- Single-user accounts at launch
- MCP/agent access is a launch differentiator
