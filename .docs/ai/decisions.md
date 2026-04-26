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
