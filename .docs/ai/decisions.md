# Decisions

This is a concise running ADR log. Add a new entry when a decision changes implementation direction, constraints, or sequencing.

## 2026-03-27 - Shared repo docs are the assistant handoff source of truth

- `.docs/ai/roadmap.md`, `.docs/ai/current-state.md`, and `.docs/ai/next-steps.md` are the required session-start files.
- `.docs/ai/current-state.md`, `.docs/ai/next-steps.md`, and `.docs/ai/decisions.md` are the required session-end update files.
- Chat memory is not the source of truth.

## 2026-03-27 - AGENTS.md and CLAUDE.md follow the shared docs workflow

- Repo-level `AGENTS.md` and `CLAUDE.md` are aligned around the same `docs/ai` session-start and session-end workflow.
- Assistant-specific guidance stays in those files, but shared state must live in `.docs/ai/*`.

## 2026-03-27 - Phase 1 AI recipe suggestions ship as draft-only and library-grounded first

- The first implementation of recipe suggestions is heuristic and grounded in saved recipes plus existing metadata.
- Suggestions open in the existing recipe editor as drafts and are never silently saved.
- This preserves the current MCP-first architecture while keeping the first slice small and testable.

## 2026-03-27 - Phase 2 companion suggestions are recipe-detail-only and return three standalone drafts

- Companion suggestions currently live only on the recipe detail screen, not the recipes list.
- The server returns exactly three draft options per request: a vegetable side, a starch side, and a sauce/drizzle.
- Companion results are standalone recipe drafts, not variants, and are never auto-saved.
- The first implementation is deterministic and cuisine-aware, matching the existing MCP-first but heuristic-first rollout style.

## 2026-03-28 - Assistant is now a first-class tab with server-side threads

- The main tab bar now prioritizes `Assistant` as a primary feature surface.
- `Activity` is preserved but moved under `Week` instead of staying in the main tab bar.
- Assistant conversations are stored on the server in persistent thread/message tables so they survive app relaunch and can be shared across clients connected to the same backend.

## 2026-03-28 - Conversational AI uses direct providers first, then remote MCP

- Assistant turns prefer direct provider APIs when configured.
- If direct provider keys are absent, the server falls back to a real remote MCP execution path instead of invoking `codex` locally.
- Assistant responses use a structured envelope with markdown plus an optional recipe draft artifact.

## 2026-03-28 - Assistant remains draft-only in v1

- The Assistant may answer cooking questions or return one recipe draft per turn.
- Assistant turns must not silently save recipes, mutate weeks, or change groceries in v1.
- Recipe detail and editor shortcuts launch into the centralized Assistant experience rather than creating separate one-off AI UIs.

## 2026-03-28 - Assistant SSE payloads and structured AI envelopes must be iOS-safe and strict

- Assistant SSE events should be JSON-encoded with API-style datetime serialization, not Python `str(datetime)` output.
- The structured assistant envelope schema should keep object payloads strict so both direct-provider and MCP-backed responses are validated before they reach the client.

## 2026-03-29 - Assistant streaming should recover from non-fatal decode drift

- If an assistant turn completes on the server but one SSE event fails to decode on iOS, the client should reload the final thread state and continue instead of surfacing a hard failure immediately.
- This keeps the Assistant usable while server/client event payloads evolve and makes final persisted thread state the fallback source of truth.

## 2026-03-29 - MCP execution is remote Streamable HTTP and persists provider thread IDs

- SimmerSmith should not launch local Codex processes for Assistant turns.
- MCP-backed Assistant execution connects to a user-managed remote MCP server over Streamable HTTP.
- Assistant threads persist the external provider thread ID so Codex-backed conversations continue with `codex-reply` instead of restarting every turn.

## 2026-03-30 - Local laptop MCP testing uses an explicit HTTP bridge, not app-owned Codex execution

- The app runtime still supports only direct providers or MCP over Streamable HTTP.
- For local development, a small helper bridge can expose `codex mcp-server` over Streamable HTTP so the backend can exercise the MCP path without saved provider keys.
- This bridge is a developer/operator tool, not a return to local `codex exec` fallback inside the app server.

## 2026-03-30 - SimmerSmith has its own standard MCP server separate from Codex

- The Codex bridge and the SimmerSmith MCP server are separate concerns.
- `simmersmith` is the standard MCP surface for operating SimmerSmith app domains directly.
- The SimmerSmith MCP server should wrap the existing API/service layer so external AI clients act on the same business logic as the app.

## 2026-03-30 - The SimmerSmith MCP server supports stdio by default and optional Streamable HTTP with simple bearer auth

- `stdio` remains the default transport because it works cleanly with Codex and similar local MCP clients.
- The same server can also run over Streamable HTTP for operator/external-client use.
- Static bearer-token auth is acceptable for the initial operator-focused HTTP mode.
- This HTTP mode is for the SimmerSmith MCP server itself, not the Codex bridge and not the in-app Assistant runtime.

## 2026-03-30 - Direct-provider API keys may be set from iOS but remain server-side only

- The native app may send a new OpenAI or Anthropic API key to the backend for storage.
- The backend must never return the stored key value to the client; it only returns a secret-present flag.
- Clearing the stored key is an explicit destructive action from the client and is performed by sending an empty server-side secret value.

## 2026-03-30 - Direct-provider models are discovered from the provider and selected from iOS

- The iOS app should not ask the operator to type model IDs manually.
- The backend is responsible for discovering available models from the selected provider using the effective configured key.
- The chosen model is stored server-side as profile state and read back as normal non-secret settings.

## 2026-03-30 - After AI/MCP validation, the roadmap returns to import quality work

- The current AI/MCP/provider-model discovery slice is validated enough to stop blocking the recipe roadmap.
- The next active product phase is `Import quality lab`, followed by `Scan/photo/PDF import hardening`.
- Remaining AI/MCP items are follow-up hardening and operator decisions, not blockers for resuming recipe-platform work.

## 2026-03-30 - Recipe import UX and hardening is now the next active roadmap phase

- The current import UI buries camera/photo/PDF import under the `Import from URL` action, which is misleading.
- The next active phase should treat recipe import as one cohesive workflow covering discoverability, UX, fixtures, and parser hardening.
- Import UX and hardening now takes precedence over the next AI feature slice.

## 2026-03-30 - Recipe ingredients keep human text but now resolve to canonical ingredient identity

- Recipe, inline meal, and grocery ingredient rows should preserve their human-readable text fields for fidelity and editing.
- The app should attach canonical ingredient identity alongside that text using `base_ingredient_id`, optional `ingredient_variation_id`, and `resolution_status`.
- Grocery, nutrition, and preference logic should prefer canonical ingredient identity and only fall back to raw strings when no safe resolution exists.

## 2026-03-30 - Household ingredient preferences resolve groceries unless a recipe explicitly locks a product

- Structured ingredient preferences now live on canonical base ingredients instead of string-only brand or ingredient signals.
- Grocery resolution precedence is:
  1. locked recipe variation
  2. household preferred variation / brand
  3. resolved recipe variation
  4. base ingredient only
- This lets recipes stay generic while still turning grocery output into the right household-specific product choice.

## 2026-03-30 - Native import methods are first-class create actions and ingredient review starts as a per-row sheet

- URL, camera scan, photo import, and PDF import should be directly discoverable from the Recipes create menu instead of being hidden behind a misleading URL import entry point.
- The first native ingredient review UX is a per-ingredient sheet launched from the recipe editor, not a full bulk-review screen.
- The first sheet supports reviewing the suggested canonical ingredient, choosing a different base ingredient, selecting a stored variation, and optionally locking the recipe to that product.

## 2026-03-30 - Household ingredient preferences are first edited in Settings

- The first native UI for structured ingredient preferences lives in Settings, not in recipe review or grocery review flows.
- Preference editing is centralized around canonical base ingredients, optional stored variations, choice mode, optional preferred brand text, and active/inactive state.
- Recipe review and grocery review can link into the same preference system later, but the first slice keeps creation and editing in one stable operator-facing place.

## 2026-03-30 - Bulk ingredient review is centralized in a shared review queue and reuses existing editors

- The first bulk-review UX is a shared native queue reachable from both `Recipes` and `Grocery`.
- Recipe-side review items do not get a separate bespoke resolver screen; they route into the existing recipe editor so one canonical recipe-editing workflow remains the source of truth.
- Grocery-side review items can launch the same household ingredient preference editor when the grocery row already has enough canonical identity to make a household preference meaningful.

## 2026-03-31 - Recipe import regressions now live in a fixture corpus on disk

- Import regressions should be captured as files under `tests/fixtures/recipe_import` instead of only as inline strings inside test functions.
- The fixture corpus should cover URL imports, direct text imports, and OCR/PDF-style noisy text so parser and cleanup regressions can be reproduced from the repo alone.
- Real-world bug reports, such as the Burnt Ends ingredient parsing failure, should be preserved as durable regression fixtures when practical.

## 2026-03-31 - Ingredient review can create catalog entities in place

- Users should be able to create missing base ingredients and product variations directly from the native ingredient review sheet.
- Newly created catalog entities should be immediately selected back into the current ingredient-resolution workflow instead of forcing a second manual lookup.
- This keeps recipe import and cleanup momentum inside one editing flow and reduces the need to bounce into separate admin/catalog screens.

## 2026-03-31 - The web admin mirrors the recipe-level ingredient review flow first

- The first web ingredient-review slice should mirror the existing recipe-level workflow instead of introducing a separate catalog-management surface.
- Operators should be able to find review-needed recipes from the Recipes page and resolve ingredient matches inside the recipe editor.
- Grocery review on the web remains recipe-first for now; canonical ingredient corrections still happen in the source recipe editor rather than directly on grocery rows.

## 2026-03-31 - Direct-provider API keys are stored per provider, not as one shared secret

- OpenAI and Anthropic now have separate server-side profile secret keys.
- Switching providers should not require overwriting or re-entering the other provider's key.
- The client still only receives provider-specific secret-present flags; it must never read stored key values back.

## 2026-03-31 - Assistant bubbles need fallback text when a provider returns only a draft artifact

- Providers may legitimately return a recipe draft without companion markdown.
- The backend and iOS UI should both synthesize a short fallback message instead of rendering a visually blank assistant response.
- This keeps OpenAI and Anthropic turns aligned at the UI layer even when their structured outputs differ.

## 2026-03-31 - New import-time ingredient resolution may create immediate base ingredients to keep review searchable

- When import resolution cannot find an existing safe catalog match, the server may create a base ingredient immediately so the ingredient becomes searchable in preferences and review flows without a later reseed.
- This is a pragmatic bridge for the current catalog rollout, not the final branded-import policy.
- Follow-up work should refine how literal those auto-created base ingredient names are and when product variations should be suggested or locked.

## 2026-03-31 - Product work should focus on backend, iOS, and MCP; the web frontend is being decommissioned

- The user no longer wants the web frontend to be a supported product surface.
- New roadmap effort should prioritize backend API, iOS, and MCP workflows.
- The existing web frontend should only receive maintenance needed to keep the repo stable until decommissioning is handled deliberately.

## 2026-03-31 - Ingredient preferences need a browseable catalog, not search-only setup

- The first settings-only preference editor was too hidden and too dependent on guessing the right search text.
- Settings now includes a lightweight ingredient catalog browser so preference editing can start from real base ingredients already in the system.
- This is still a first step, not a full ingredient-management console; edit/merge/archive behavior is a follow-up decision.

## 2026-03-31 - Failed assistant turns must render as explicit errors, not blank bubbles

- If a provider turn fails after the user sends a message, the persisted assistant message should carry readable error text.
- The iOS assistant UI should render stored error text before falling back to an empty bubble.
- This is especially important for Anthropic troubleshooting, where schema-output failures otherwise look like blank assistant replies.

## 2026-04-01 - Ingredient management now lives in a dedicated native area, not only inside Settings search flows

- The app now has a dedicated native `Ingredients` management experience for browsing and maintaining canonical ingredient data.
- Ingredient management is reachable from both `Settings` and `Recipes`, but it is treated as a real product surface with detail/edit/merge/archive flows.
- Recipe text remains the source of truth for user-facing ingredient phrasing, while the `Ingredients` area manages canonical base ingredients and product variations behind that text.

## 2026-04-01 - Ingredient catalog seeding is source-aware and must fail gracefully under external API limits

- USDA FoodData Central and Open Food Facts are the initial external sources for generic calories and branded/package product data.
- The seed pipeline should continue running and report skipped requests when external APIs throttle or intermittently fail; transient third-party issues should not crash the entire ingest run.
- Production seeding strategy is still undecided, but the code path assumes source provenance and local SimmerSmith overrides are first-class.

## 2026-04-02 - USDA seed credentials are server-side config, not command-line-only inputs

- SimmerSmith now exposes a dedicated `SIMMERSMITH_USDA_API_KEY` server setting.
- The ingredient seed script prefers that server-side setting automatically and only falls back to `DEMO_KEY` if neither the CLI flag nor the env var is set.
- Docker also passes the USDA key through so local production-style runs and seed workflows can share the same configuration.

## 2026-04-02 - Live ingredient seeding should target the Docker-backed app database, not only temp local databases

- The first real operator seed should run inside the `simmersmith` container from `/workspace` so it uses the same migrations, config, and writable SQLite file as the live app.
- Temp local seed databases are still useful for smoke tests, but they are not enough to prove the live product catalog is populated.
- The first live USDA-backed seed worked, but the resulting corpus still needs review for search quality and noisy matches before treating it as the final default catalog experience.

## 2026-04-02 - USDA ingest should seed one curated base ingredient per term, not one row per search hit

- The first naive USDA seed produced too much catalog noise because it created a base ingredient for every matching USDA search result.
- The current ingest path now picks one best USDA candidate per curated seed term and stores that candidate's provenance and nutrition on the canonical ingredient for the term.
- Search now uses phrase-aware matching plus singular/plural variants so ingredient lookups behave like ingredient search rather than raw substring matching.

## 2026-04-03 - Default ingredient browse/search is generic-first; product-like rows are opt-in

- The default ingredient browse/search experience should favor clean generic bases that make sense for recipe resolution and household preferences.
- Product-heavy or package-form rows remain in the catalog, but they are hidden from default browse/search unless the client explicitly opts into `include_product_like=true`.
- Product-like classification should catch not only branded OFF rows, but also packaging-heavy names such as `... jar`, `... bottle`, or literal imported rows like `1 can refrigerated biscuits`.

## 2026-04-03 - Clearing local cache should immediately resync when a server connection is saved

- `Clear Local Cache` is a local-state reset, not a disconnect.
- If the app still has a saved server URL/token, clearing cache should immediately trigger a fresh server sync instead of leaving screens empty until the user manually reconstructs state.
- This keeps cache clearing safe for QA and troubleshooting without making the app look like server data was deleted.

## 2026-04-03 - TestFlight prep produces a signed IPA locally, but upload depends on separate ASC credentials

- Local release prep can be split into two phases:
  1. archive + export a valid App Store Connect IPA
  2. upload that IPA to App Store Connect
- Code signing identities and provisioning on this machine are sufficient for archive/export, but they are not enough to guarantee upload.
- App Store Connect upload should now be treated as requiring its own verified credential path:
  - working Xcode account auth on the machine
  - or a dedicated App Store Connect API key flow
  - or a later CI/release automation path

## 2026-04-04 - The roadmap now separates formal phases from a small-model-safe backlog

- The roadmap now has two explicit lanes:
  1. formal premium-model phases for architecture, product-policy, and contract-shaping work
  2. a parallel small-model-safe backlog for narrow, localized, low-risk work that can run alongside those phases
- Smaller assistants may own localized code cleanup, tests, docs, release hygiene, CI/build hygiene, and similarly bounded maintenance work.
- Smaller assistants may not decide architecture, API or MCP contracts, import-policy behavior, ingredient-model policy, AI workflow policy, or migration design.
- Backlog items should be tagged by area plus delegation safety, and if a backlog task exposes a deeper issue it should be promoted into formal roadmap or ADR work and stopped rather than completed opportunistically.

## 2026-04-04 - Inferred exact branded variation matches stay suggested unless the user explicitly locks them

- If ingredient resolution infers a stored variation from an exact normalized-name match, that match should remain `suggested`, not `locked`.
- The app should only persist an override `resolution_status` when the client explicitly set one; schema-default `unresolved` values from omitted fields must not wipe out inferred resolution.
- Explicit user locks and other explicit client-supplied statuses still win over inference.
- This keeps branded/product import matches reviewable during the current trustworthiness phase while preserving a clear path for user-approved locking.

## 2026-04-05 - Canonical product modeling is now generic-first with an operator rewrite path for legacy rows

- Product-like ingredient resolution should prefer a clean generic base ingredient over a literal branded/package-heavy base row.
- Strong product evidence may attach a suggested variation under that generic base, but the app still must not auto-lock that variation without explicit user action.
- Existing legacy product-like base rows should be normalized through a deliberate operator-run dry-run/apply workflow, not a background runtime migration or an Alembic schema migration.
- When a legacy product-like base is rewritten into a variation under a generic base, existing recipe, inline meal, grocery, and preference links should be repointed to that suggested variation before the old base is merged.

## 2026-04-05 - Product pivot: AI-first public App Store product

**Context**: Product research conversation revealed the existing Codex-generated roadmap was a developer feature log, not a product strategy. The user's actual vision is significantly broader.

**Decision**: SimmerSmith is now an AI-first public product targeting the App Store. AI is the star — it plans weeks, optimizes groceries, and makes every part of meal planning easier. This replaces the prior framing as a personal tool with secondary web admin.

**Key changes**:
- AI is the primary interaction model, not a side feature
- Public App Store product with 2-3 month timeline
- Freemium AI billing (boundaries TBD after usage data)
- Supabase cloud (Postgres) for production, self-hosted (SQLite) as first-class option
- Supabase Auth for multi-user (single-user at launch, household sharing post-launch)
- Web frontend is being removed entirely (not decommissioned — killed)
- MCP/agent access is a launch differentiator
- Guided onboarding with full AI preference interview
- Store-specific grocery pricing is must-have for launch
- Push notifications and analytics are launch features
- Full code quality audit required before building new features (Codex output is untrusted)

## 2026-04-05 - Dual database support: SQLite for self-host, Postgres for production

**Context**: Self-hosting is a first-class option. SQLite is perfect for single-user self-hosted deployments. Postgres (via Supabase) is needed for multi-user cloud.

**Decision**: Support both SQLite and Postgres through SQLAlchemy dialect abstraction. Alembic migrations must work on both dialects. Self-hosted defaults to SQLite; Supabase cloud uses Postgres.

## 2026-04-05 - Supabase Auth replaces bearer token auth for cloud deployment

**Context**: The current auth model is a single optional bearer token (`SIMMERSMITH_API_TOKEN`). This doesn't support multi-user.

**Decision**: Supabase Auth for the cloud product. Self-hosted mode retains the bearer token option. The FastAPI middleware must handle both auth modes based on configuration.

## 2026-04-10 - Stack pivot: Fly.io + Postgres + Apple/Google Auth

**Context**: The dual-database (SQLite + Postgres), Supabase Auth, and two-tier catalog model was overengineered. The actual deployment target is a single Fly.io instance with Postgres. Simplifying the stack gets to App Store faster.

**Decision**: 
- **Hosting**: Fly.io with Neon Postgres (free tier) or Fly Postgres.
- **Auth**: Apple Sign-In + Google Sign-In via pyjwt[crypto] + PyJWKClient JWKS verification. Server issues its own session JWTs. Legacy bearer token kept for dev/MCP.
- **Database**: Postgres-only. SQLite kept only for test suite.
- **Catalog**: Shared reference data with no user_id. Only user-owned tables (weeks, recipes, assistant_threads, ai_runs, profile_settings, staples, preference_signals, ingredient_preferences) get user_id.
- **Supersedes**: "Dual database support" (2026-04-05), "Supabase Auth replaces bearer token" (2026-04-05), and the Phase 0 multi-user isolation design doc.

## 2026-04-15 - AI week planner uses PlanningContext for preference-aware generation

**Context**: The AI planner had rich preference/feedback/history data available (PreferenceSignal scores, staples, meal history) but only used flat profile settings in the prompt.

**Decision**: Added `PlanningContext` dataclass that bundles all enrichment data. `gather_planning_context()` fetches from DB using existing service functions. The prompt builder adds structured sections (avoids, likes, cuisines, staples, recent meals) only when data exists. Post-generation guardrails and scoring validate the output. New users get the same prompt as before (graceful degradation).

## 2026-04-15 - Kroger API is the primary grocery pricing integration

**Context**: Evaluated Kroger API, Instacart, Spoonacular, Walmart, and Edamam for store-specific pricing. Walmart has no public API. Instacart doesn't return raw prices (redirect only). Spoonacular only has estimates.

**Decision**: Kroger API selected as primary integration — free, self-service, real store-specific prices at ~2,750 locations. Existing batch import flow preserved for other retailers. Instacart planned as secondary "shop now" action. Spoonacular as estimated-cost fallback.

## 2026-04-05 - AI handoff docs migrated from docs/ai/ to .docs/ai/

**Context**: Global Claude Code convention uses `.docs/ai/` (dot-prefixed). This project used `docs/ai/` (old convention).

**Decision**: Migrated all handoff docs to `.docs/ai/`. Updated all references in CLAUDE.md, AGENTS.md, and the docs themselves. Old `docs/ai/` directory removed via git.

## 2026-04-20 - Assistant context is per-message, not per-thread

**Context**: M6 originally keyed planning-mode on `AssistantThread.thread_kind == "planning"` with a `linked_week_id` column. After the Nebular-News-style UX pivot, every tab publishes an `AIPageContext` to a single global coordinator and that context ships with every message.

**Decision**: The backend now treats per-message `page_context.week_id` as the authoritative "which week does this conversation care about" signal. `thread.linked_week_id` is kept for backward compat but no longer set by the iOS client. The tool loop fires whenever a message carries a `week_id` — so a single `thread_kind="chat"` thread can switch between "general cooking help" and "plan Wednesday" turn-by-turn based on which screen the user has open. This matches the one-coordinator / many-contexts pattern from Nebular News (`/Users/tfinklea/git/nebularnews-ios/NebularNews/NebularNews/Features/AIAssistant/`).

## 2026-04-20 - Tool-result payloads are always jsonable_encoded before being shown to the model

**Context**: `_run_openai_tool_loop` appends `{role: "tool", content: json.dumps(result.to_model_reply())}` after each tool call. Mutating tools embed the fresh `week_payload` in the result so the model can reason about the new state. The week payload contains `date` / `datetime` objects (week_start, meal_date, etc.) which plain `json.dumps` can't serialize.

**Decision**: Always route tool replies through `fastapi.encoders.jsonable_encoder` before `json.dumps`. Same normalization the SSE emitter (`encode_sse`) has been doing all along. Regression test in `tests/test_assistant_tools.py::test_tool_result_reply_is_json_serializable` keeps us honest.

## 2026-04-20 - Backend streams OpenAI deltas instead of buffering + chunking

**Context**: The first cut of the tool loop called chat-completions non-streaming, then chunked the final text server-side into `assistant.delta` events. The user saw one long pause + a dump of text instead of true streaming.

**Decision**: The tool loop now uses `client.stream("POST", …, json={"stream": True, …})` and emits each OpenAI `content` delta directly through the `on_event` SSE pipe. Tool-call deltas accumulate per `index` across incremental chunks (OpenAI sends function name + arguments piecewise). `AssistantTurnResult.streamed_deltas` tells the endpoint whether to skip the fallback `chunk_text(...)` so we don't double-emit. The envelope-JSON fallback (MCP / legacy Anthropic) still uses the chunk-on-complete path.

## 2026-04-20 (evening) - M5 freemium deferred in favor of M7 polish

**Context**: The roadmap listed M5 (Freemium + Subscription) as "next" after M6 shipped. During the same session the user surfaced six shakedown bugs on the live assistant flow (pull-to-refresh cancel, sheet-dismiss not cancelling the turn, mid-stream persistence gap, hallucinated actions, Anthropic tool-use gap, per-day gen not real). The user explicitly asked to postpone freemium so the focus could be polish.

**Decision**: M5 is parked under "deferred". M7 "Assistant Polish" is the active milestone. Phases 1–4 of M7 shipped this session (URLSession isolation, mid-turn persistence, client-disconnect cancel, hallucination guardrail). Phases 5 + 6 (Anthropic tool-use, true per-day gen) are deferred as follow-ups — Phase 6 in particular has a 7× token cost impact that needs a cost gate, which was the original motivation for M5. Do not restart M5 work without explicit re-authorization; saved to memory as `project_m5_freemium_deferred.md`.

## 2026-04-20 (evening) - Dedicated URLSession for SSE streaming

**Context**: iOS pull-to-refresh on the Week tab raised a `CancellationError` in the assistant stream whenever a stream was live. Root cause: `SimmerSmithAPIClient` used `URLSession.shared` for both `bytes(for:)` SSE streaming and regular requests, so concurrent requests could cancel the stream's data task.

**Decision**: `SimmerSmithAPIClient` now owns a dedicated `streamingSession` (separate `URLSessionConfiguration` with 300s request timeout, 600s resource timeout, `waitsForConnectivity: true`). `streamAssistantResponse` uses the dedicated session; every other request path stays on the shared session. Isolation between shared-request cancellations and long-lived SSE is now a structural guarantee rather than a happy accident.

## 2026-04-20 (evening) - Client-disconnect cancels the server assistant turn

**Context**: Before today, dismissing the assistant sheet mid-stream left `_run_openai_tool_loop` running to completion — up to 6 tool iterations worth of OpenAI tokens were spent on a reply no one would read. There was no cancel path on the server and no task retention on the client.

**Decision**: Two-sided cancellation:
- **Server**: the SSE endpoint spawns a `_watch_disconnect` coroutine that polls `request.is_disconnected()` on a 1s cadence and fires a `threading.Event`. The tool loop checks the event between OpenAI chunks, before each tool invocation, and between iterations. On abort it returns `AssistantTurnResult(cancelled=True, ...)` with whatever text arrived pre-abort. The endpoint persists `status="cancelled"` on the message, `AIRun.status="cancelled"`, and emits a final `assistant.cancelled` SSE frame.
- **Client**: `AIAssistantCoordinator` retains the streaming `Task` and exposes `cancelInFlightTurn()`. `AIAssistantSheetView.onDisappear` calls it so closing the sheet closes the TCP connection via Swift's structured-concurrency cancellation chain (`URLSession.bytes` → stream continuation → disconnect).

## 2026-04-20 (evening) - Hallucination guardrail lives on iOS, not the backend

**Context**: The M6 tool loop is permissive — if the model narrates "I swapped Tuesday's dinner" without firing `swap_meal`, the UI previously showed the text as if the swap happened. Users reasonably assumed the change was applied.

**Decision**: Detection is iOS-only for now. `AssistantMessageInlineBubble` flags completed assistant messages with mutation-verb prose and an empty `toolCalls` list, rendering an amber "Nothing changed in your plan — run it now?" affordance. The pattern list is inline and deliberately permissive (false positives over false negatives). Backend persistence of the flag would require a migration (`assistant_messages.flags_json`); we'll add that later if we want the warning to survive app restarts. For a shakedown fix this is enough.

## 2026-04-26 - M13 Cooking Mode is iOS-only with on-device voice and manual timers

**Context**: M13 wraps M11's `cook_check` chip and the existing assistant launch context into a hands-free, big-text, screen-awake cook flow. Three real product choices were locked in via AskUserQuestion before the plan: voice scope, timer behavior, and entry placement.

**Decision**:
- **Voice is on-device only.** `VoiceCommandService` sets `requiresOnDeviceRecognition = true` so audio never leaves the phone. No backend speech route. We accept the slight accuracy hit because cooking happens in noisy kitchens with confidential context.
- **Audio buffer auto-restart.** `SFSpeechRecognizer` audio buffers cap around 60 seconds. The service restarts the recognition request every ~50s and right after every recognized keyword (which both clears the buffer and prevents a stale partial result re-firing the same command).
- **Manual timers, not AI-suggested.** `CookingTimerChip` uses fixed quick chips (5/10/15/20/Custom). No `step_timer_ai` service, no extra latency on entering cook mode. AI-suggested timers can be revisited if user data shows manual feels redundant.
- **No bundled chime asset.** Timer-done feedback is a warning haptic plus a TTS "Timer done." utterance through the existing `SpokenStepService`. Adds zero MB to the app bundle and matches the in-flight TTS audio session cleanly.
- **"Stop" command shows a confirmation alert.** A misheard "stop" or someone in the next room saying "stop" should not yank the user out mid-cook. The alert is the cheap insurance.
- **No backend changes.** M13 is iOS-only. The existing `POST /api/recipes/{id}/cook-check` route and `beginAssistantLaunch(...)` cover everything cook mode needs.

This keeps the milestone shippable in a single iOS-side push and avoids a Fly deploy in the same release as TestFlight build 17.

## 2026-04-29 - M17 image-gen provider toggle is per-user and stored in profile_settings

**Context**: M14/M16 ship recipe images via OpenAI's `gpt-image-1`. Adding the planned Gemini-direct alternative needed a way to pick between providers. Three options were on the table: a single global setting flipped via Fly secret, per-user choice, or auto-failover. The user picked per-user toggle.

**Decision**:
- **Per-user via `profile_settings`.** `image_provider` is a row in the existing key/value `profile_settings` table — same pattern `user_region` (M12 Phase 3) uses. No Alembic migration. The cost is loose typing (any string can land in there); `_resolve_provider` whitelists `openai|gemini` and falls back to the global default for anything else, so a stale or malformed value is safe.
- **Global default stays OpenAI.** `settings.ai_image_provider = "openai"` so existing users see no behavior change on upgrade. Each user opts into Gemini via Settings → Recipe images → Picker.
- **Shared prompt across providers.** `_build_prompt` is reused by both `_generate_via_openai` and `_generate_via_gemini`. Variety is provider-driven (different model, different aesthetic), not prompt-driven. If dogfooding shows Gemini benefits from a different shape, we'll split.
- **Backward-compatible service signatures.** `is_image_gen_configured` and `generate_recipe_image` gained a keyword-only `user_settings: dict[str, str] | None = None` param. Existing tests that patch `app.api.recipes.generate_recipe_image` keep working unchanged because dispatch happens *inside* that function — the mocks intercept before `_resolve_provider` ever runs. New tests target `_generate_via_openai` / `_generate_via_gemini` directly.
- **Lossy provenance.** `recipe_images.prompt` stores the same auto-built prompt regardless of provider. We don't track which provider rendered which image. Adding a `provider` column would buy debug clarity at the cost of a migration; deferred until cost telemetry actually wants it.
- **No auto-failover.** If a provider 5xxs, the existing best-effort try/except just skips image gen for that save (gradient fallback) or 502s the regenerate route. Auto-failover (OpenAI fail → retry on Gemini) is on the M17+ list but introduces non-obvious behavior — when an image looks "off", you can no longer assume which provider drew it. Saved for if dogfooding demands it.

## 2026-04-29 - TestFlight uploads use the App Store Connect API key, not Xcode-account auth

**Context**: Build 26 uploaded fine via `xcodebuild -exportArchive` against `ExportOptions.plist`. A few hours later the same command failed for build 27 with "Failed to find an account with App Store Connect access." Diagnosis: `ExportOptions.plist` has no `authenticationKey*` entries, so `xcodebuild` falls through to the Xcode GUI account flow — which is not durable across non-interactive shell sessions and silently expires. The 2026-04-03 ADR ("upload depends on separate ASC credentials") flagged this risk but never produced a path forward; meanwhile three `AuthKey_*.p8` API keys had been dropped in the repo root and gitignored, but were never wired into the upload command.

**Decision**:
- **Always use the API key.** New `scripts/release-ios.sh` runs the canonical archive → export → upload flow with `-authenticationKeyPath`, `-authenticationKeyID`, and `-authenticationKeyIssuerID` flags. No more reliance on the Xcode-account session.
- **Credentials live in `.release-ios.env`** (gitignored, repo root). Two values: `IOS_RELEASE_KEY_ID` (matches the `AuthKey_<ID>.p8` filename) and `IOS_RELEASE_ISSUER_ID` (UUID from App Store Connect → Users and Access → Integrations). The script sources the file; required vars cause a fail-fast exit if missing. We pair the issuer ID with the .p8 in the same gitignored bucket because either one alone is useless — keeping them adjacent matches the operational reality.
- **Build number flows from `project.yml`.** The script reads `CURRENT_PROJECT_VERSION` so `/tmp/SimmerSmith-build${BUILD}.xcarchive` is automatic. Bumping the build is still a manual `project.yml` edit (matches existing milestone cadence), but the script picks it up.
- **Why a script instead of fixing `ExportOptions.plist`.** The plist *can* embed `authenticationKeyPath` etc., but those values are then committed to git. A wrapper script keeps the credentials out of the plist and gives one place to add future steps (e.g. a release-notes CHANGELOG bump, a Slack ping, etc.).

This closes out the open ADR from 2026-04-03 and unblocks future TestFlight cuts from any shell.

## 2026-04-30 - M18 push scheduler runs in-process on the FastAPI app (APScheduler)

**Context**: M18 needs a background job that fires every 5 minutes to check whether any user's
notification window has arrived. Three options: (1) Fly cron + `fly machines run`, (2) a separate
worker process/dyno, (3) in-process `AsyncIOScheduler`.

**Decision**:
- **APScheduler in-process.** Single Fly machine (`shared-cpu-1x`), single scheduler. The scheduler boots in
  the FastAPI lifespan context alongside the existing migrations/seed hooks and shuts down cleanly on app stop.
- **Disabled by default in tests.** `SIMMERSMITH_PUSH_SCHEDULER_ENABLED=false` in `tests/conftest.py` ensures
  pytest never spawns an APScheduler thread. The config field defaults to `true` so production needs no
  explicit opt-in.
- **Disabled when APNs is unconfigured.** `start_scheduler` returns `None` when any of the three required
  APNs secrets is empty. Dev + CI environments without the key never run the scheduler.
- **Scale-out caveat.** If the app ever scales to 2+ Fly machines, both schedulers would fire for the same users,
  potentially double-delivering (collapse-id handles the APNs side, but server-side duplicate delivery is possible).
  The right fix is a Postgres advisory lock or `fly machines run` cron. Documented here as a known v1 limit;
  record in `next-steps.md` to revisit if we scale beyond one machine.
- **In-memory de-duplication.** `_sent_today` dict keyed by `(kind, user_id, date_key)` prevents double-delivery
  during a single app run. A server restart within the same notification minute could re-fire once; acceptable at
  v1 volume. APNs `collapse-id` is the backstop on the device side.

## 2026-04-30 - M19 assistant tool loop is provider-agnostic via a small adapter ABC

**Context**: M6 shipped the assistant tool loop as `_run_openai_tool_loop`, hard-wired to OpenAI's Chat Completions API. Anthropic-direct planning threads silently fell back to envelope-JSON parsing — the same 11 tools never ran for Anthropic users, and `assistant.tool_call` / `week.updated` SSE events never fired. iOS was already provider-agnostic. The gap was purely backend.

**Decision**:
- **Abstract via a per-turn `ProviderAdapter` ABC**, not a Protocol. The adapter owns its `messages` list and per-stream accumulator state for one turn. Five abstract methods cover request shaping (`request_url`, `request_headers`, `request_body`), stream parsing (`parse_stream_line` returning normalized events + `reset_stream_state`), and message mutation (`record_assistant_turn`, `record_tool_results`). Two concrete adapters: `OpenAIAdapter` and `AnthropicAdapter`.
- **`_run_provider_tool_loop` replaces `_run_openai_tool_loop`.** Outer control flow (max iterations, `abort_event`, throttled persistence, `on_event` emission, `tool_transcript`) is unchanged — only per-chunk parse + per-message shape calls flip to `adapter.*`.
- **`NormalizedStreamEvent`** carries one of three kinds: `text_delta`, `tool_call_complete`, `turn_done` (with `is_terminal`). Both adapters emit the same vocabulary so the loop never sees provider-specific shapes. Critically, `tool_call_complete` is emitted only after the full args JSON is accumulated — the loop never deals with partial tool calls.
- **OpenAI accumulates incrementally**; Anthropic streams `input_json_delta` chunks per `tool_use` block and assembles on `content_block_stop`. The adapter handles both internally.
- **Dispatch lookup table** at `run_assistant_turn`: `_PROVIDER_ADAPTERS = {"openai": OpenAIAdapter, "anthropic": AnthropicAdapter}`. New providers (e.g. Mistral, Gemini text models) just add an adapter — no loop changes required.
- **Anthropic API version stays at `2023-06-01`.** Tool-use is supported on this header value; no migration needed. The same version was already used by the existing envelope path.
- **Envelope-JSON path kept** for non-planning threads (`use_tools=False`). Cooking-help and general chat still parse a JSON envelope; only planning threads with tool-runner enabled go through the adapter loop.
- **Tests parallel the OpenAI path.** Six new Anthropic tests: tool invocation, multi-turn tool result loop-back, text-only delta cadence, two dispatch routing tests (Anthropic + OpenAI regression guard), and an import sanity check. `test_abort_event_cancels_tool_loop_mid_stream` was updated to construct an `OpenAIAdapter` and call `_run_provider_tool_loop` directly.

**Trade-offs accepted**:
- One adapter instance per turn. Cheap (no I/O on construction) and avoids state sharing bugs across concurrent turns.
- The adapter doesn't expose tool deltas to iOS — only completed tool calls. iOS today renders only completed cards, so no UX loss. If we ever want to show "Tool building..." with streaming args, that's a future event-type addition, not an architectural change.
- No `anthropic` SDK dependency. Raw httpx mirrors the existing OpenAI path's style and keeps the adapter visible. The SDK would shave ~30 lines but adds a dep for marginal value.

## 2026-05-01 - M21 household_id is additive (creator user_id stays as metadata)

**Context**: M21 moves single-user planning to household-shared planning. The big design call was how to migrate ~5 shared tables (Week, Recipe, Staple, Event, Guest) without losing creator metadata, breaking existing queries, or shipping a destructive migration.

**Decision**:
- **Additive schema (option C from the plan).** Shared tables gained a `household_id` column. The pre-existing `user_id` column stays as creator metadata. Queries flip from `user_id ==` to `household_id ==`. Unique constraints (e.g. `Week (user_id, week_start)`) stay user-scoped — two members can each have a "May 4" week without colliding; the iOS Week tab picks the most-recently-touched. This was simpler than redefining every constraint and accepts the cost of two coexisting weeks per date per household as a UI concern, not a DB-level invariant.
- **Phase 1 ships nullable**, **Phase 2 makes it logically required.** The Phase 1 migration adds `household_id` as nullable, backfills existing rows, and stops there. Phase 2 wires every writer to populate it. NOT NULL enforcement is deferred (would be a future migration once we're confident every write path passes it). This avoided the trap where ORM-level `nullable=False` on a column the model doesn't know to populate causes IntegrityError.
- **Lazy solo-household creation in `get_current_user`.** Every authenticated request that lacks a `household_members` row gets one auto-created. This means new users (Apple/Google first sign-in) and legacy pre-M21 users converge to the same code path. The dedicated provisioning hook in `auth_apple` / `auth_google` was deferred — lazy creation handles both cases cleanly.
- **Auto-merge on invitation claim.** When a user joins a household, all of their solo's shared content (Week / Recipe / Staple / Event / Guest) is re-pointed at the target household via UPDATE statements; the empty solo is deleted. No "move your data first" prompt. The user picked this behavior over the strict-409 alternative because real-world flow is "tech-forward partner installs first, the other one joins a week later" and we shouldn't make them factory-reset.
- **Per-user data stays per-user.** DietaryGoal, IngredientPreference, PreferenceSignal, ProfileSetting, PushDevice, AIRun, AssistantThread, ImageGenUsage, Subscription, UsageCounter all keep user_id scope. Each member has their own taste memory, allergies, push toggles, AI provider, and (when M5 un-defers) subscription.
- **`profile_settings` not split yet.** The plan called for splitting household-scoped keys (timezone, household_name, week_start_day, store info, etc.) into a separate `household_settings` table. Phase 1 created the table; Phase 2 didn't migrate the data because the readers still go through `profile_settings_map`. This becomes a future cleanup once household-vs-user setting reads are clearly separated in code. The behavioral cost today: each member has their own copy of `timezone` etc.; in practice they'll match because they're in the same household.
- **Invitation codes are 8 chars alphanumeric, 7-day expiry, single-use.** No email path — Apple's "Hide My Email" relay-emails make email invites unreliable, and a copy-pasteable code works on both iOS Settings flow and any messaging app via ShareLink.

**Trade-offs accepted**:
- 5 shared tables now have an extra column on every row. Storage cost is trivial (36 chars per row). Index churn was bounded — we added a household_id index and kept the user_id index for creator-attribution queries that may emerge later.
- The auto-merge isn't transactional across all 5 tables in the strictest sense — a failure mid-merge could leave content half-pointing-at-the-new-household. Acceptable at v1 user volume; if we hit it, wrap merge_solo_into in `with session.begin_nested()`.
- No "leave household without joining a different one" UI in v1. Anyone who needs it can sign out + reset.
