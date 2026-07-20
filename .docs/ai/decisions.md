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


## 2026-05-03: M22 Grocery list mutability + Apple Reminders sync

**Decision**: Make the grocery list a first-class household artifact.
Auto-aggregation from meals stays the seed, but the user can add
custom items, edit quantities/units/notes, soft-remove items, and
check items off as a household-shared state. Mirror the live list
into a Reminders list of the user's choosing so they can shop
without opening the app.

**Schema additions** (`alembic/versions/20260503_0028_grocery_edits.py`):
- `grocery_items.is_user_added` BOOL — never deleted by smart-merge.
- `grocery_items.is_user_removed` BOOL — tombstone preserves the
  user's removal across regen.
- `grocery_items.quantity_override`, `unit_override`, `notes_override` —
  user values that win over auto-aggregated values on display, while
  the auto values stay alongside them.
- `grocery_items.is_checked`, `checked_at`, `checked_by_user_id` —
  household-shared check state. Old local-only `cacheStore.isChecked`
  is now a fast-render mirror; server is source of truth.
- `events.auto_merge_grocery` BOOL DEFAULT TRUE — when on, the event's
  grocery list automatically merges into the week containing
  `event_date` whenever `regenerate_event_grocery` runs.

**Smart-merge regeneration**: rewrote `regenerate_grocery_for_week`
from wipe-rebuild to diff-merge. Items are classified into:
- `untouchable` (`is_user_added` OR has event-merge attribution) —
  not touched.
- `eligible` (auto-managed, possibly with overrides / check state) —
  matched by `(base_or_normalized_name, locked_variation, unit,
  quantity_text)` and updated; items not matched but with user
  investment get `review_flag = "no longer in any meal"`; pure-auto
  unmatched items are deleted.

**Reminders sync direction**: two-way mirror, last-write-wins by
`updated_at`. Per-device `(grocery_item_id ↔ EKReminder.calendarItemIdentifier)`
mapping in UserDefaults JSON keyed by chosen `EKCalendar.calendarIdentifier`.
Server stays the canonical source per household; each member's iOS
device independently mirrors the shared server-side list into THEIR
chosen Reminders list. Title format `"<qty> <unit> <name>"` so the
future M23 cart-automation skill can parse without extra metadata.

**iOS surfaces**: 5th tab (`AppState.MainTab.grocery` was scaffolded
but unwired pre-M22; we wired it). Editable `GroceryView` with
swipe-to-remove, tap-to-edit, "+" toolbar to add. Settings → Grocery
section with Reminders sync toggle + list picker. Per-event
auto-merge toggle on `EventDetailView`. `Info.plist` gains
`NSRemindersUsageDescription` + `NSRemindersFullAccessUsageDescription`.

## 2026-05-03: M23 Cart-automation skill design (deferred — design only)

**Decision**: The Aldi / Walmart / Sam's Club / Instacart cart
automation does NOT live in the SimmerSmith app or backend. It
lives in `~/.claude/skills/simmersmith-shopping/` as a Claude Code
skill (with peer Codex implementation), runs locally on the user's
laptop, and reads the same Apple Reminders list that M22 mirrors
into. This keeps the iOS app free of third-party cookie / web
automation concerns, lets the heavy work run on a beefy laptop
rather than a phone, and avoids putting per-store credentials on
Fly.io secrets.

**Skill input contract** (set by M22, frozen):
- Reminders list title is configurable per device (user picks).
- Each grocery reminder's title is `"<qty> <unit> <name>"` — e.g.
  `"2 cups flour"`, `"1 pkg paper towels"`. Skill parses this with
  a permissive grammar: optional leading number → optional unit →
  remainder is name.
- Notes field optional, holds source-meal context ("for Spaghetti
  Bolognese") that the skill ignores for matching.
- Skill MAY (not MUST) call SimmerSmith's bearer-token API for
  richer `base_ingredient_id` / preferred-brand metadata if the
  string-only path produces too many ambiguous matches.

**Process** (skill-side, NOT in this milestone):
1. Read the chosen Reminders list (macOS `osascript`,
   `reminders-cli`, or PyXA via `scripts.app` — pick whichever is
   most reliable on macOS 15+).
2. Per-store product resolution + price fetch via Playwright +
   browser-use. Aldi, Walmart, Sam's Club, Instacart targeted in
   that priority order. Kroger stays pricing-only via the existing
   API (M2).
3. Compute a store-split that minimizes cost subject to per-store
   delivery minimums and a "no more than 2 stops" constraint.
   Greedy + 1-store swap heuristic; deterministic.
4. Drive each store's web UI to add items to the cart. Stop short
   of placing the order — leave at "ready to check out" so the user
   reviews.

**Auth**: per-store cookies in a Playwright persistent profile under
`~/.config/simmersmith/skill-profile/`. User logs in once
interactively per store; cookies persist. No credentials in code.

**Why not in the iOS app**: WebView automation against retailer
sites is fragile, runs afoul of mobile cookie restrictions, and
maintaining per-retailer scrapers in Swift is a poor use of mobile
runtime. The laptop is also where the user reviews the cart before
checkout — closer to where the action lands.

**Trade-offs accepted**:
- The skill is non-portable: it runs only on the user's laptop, not
  in the cloud. If we ever want a "tap to shop" button on iOS, we'd
  need a separate hosted automation.
- The two-way Reminders bridge is foreground-only in v1 (no
  BGAppRefreshTask). If the user shops with the app backgrounded,
  the check-state propagation lags until the app is foregrounded.

## 2026-05-20 - Serve RFC 9728 protected-resource metadata at the root path explicitly

- The `mcp` SDK (1.26.0) `streamable_http_app()` registers its
  protected-resource-metadata route at a path computed for
  mount-at-root, and the `/mcp` 401 `WWW-Authenticate` header
  advertises that root URL. Because `app/main.py` mounts the MCP app
  at `/mcp`, the route actually lives at
  `/mcp/.well-known/oauth-protected-resource/mcp` while the
  advertised URL (`/.well-known/oauth-protected-resource/mcp`) 404s —
  breaking RFC 9728 discovery for spec-compliant MCP clients
  (current Claude desktop connector).
- Decision: serve the metadata ourselves via an explicit FastAPI
  route in `app/api/oauth.py` at the advertised root path. Rejected
  alternatives: re-mounting the MCP app at `/` (would shadow the REST
  surface) and patching SDK internals (fragile across SDK upgrades).
- The hand-written document is tiny and stable (`resource`,
  `authorization_servers`, `scopes_supported`,
  `bearer_methods_supported`). Revisit if a future SDK version
  becomes mount-aware.

## 2026-05-23 - Hoist iOS `browsedWeek` from view-local @State to AppState (build 104)

- Bug from this session: when the AI Assistant mutated a non-current
  week (e.g. planning "next week" from the week-picker), the iOS
  view rendered the day empty even though the meals committed
  server-side. Root cause: the SSE `case "week.updated"` handler
  unconditionally wrote `currentWeek = updated.week`, but the
  user-displayed week lived in `WeekView`'s local `@State
  browsedWeek` and never received the patch.
- Considered:
  - **A. Hoist `browsedWeek` to `AppState`** (chosen) — clean,
    mechanical (~17 textual replacements in `WeekView`), restores
    the invariant "AppState owns server-truth state; views observe."
  - **B. Pass a binding/callback into WeekView so AppState can
    update its @State indirectly** — preserves @State locality but
    threads a binding through a state graph that doesn't otherwise
    need one. Net more code and more confusing data flow.
  - **C. Generic `cachedWeeksByID: [String: WeekSnapshot]` cache
    on AppState; views read from the cache** — flexible
    (other views could benefit) but invasive for the immediate
    bug and not justified by current product needs.
- A also unblocked a second fix: `.refreshable` and the FAB
  `.refresh` action can now refetch the displayed week
  (`appState.browsedWeek = try? await fetchWeekByStart(...)`)
  instead of only `/api/weeks/current`. Pull-to-refresh on a
  non-current week now actually refreshes that week.

## 2026-05-22 - Defer `uq_week_day_slot` instead of restructuring `update_week_meals`

- Bug from this session: iOS swap-meals PUT 500s because Postgres
  checks `uq_week_day_slot(week_id, day_name, slot)` per-statement
  and the two-row exchange transiently duplicates the second row's
  current slot before its own UPDATE lands.
- Chosen fix: `DEFERRABLE INITIALLY DEFERRED` on the constraint
  (migration `20260522_0042_defer_week_meal_slot_unique.py` +
  mirroring flags on `app/models/week.py`). The constraint is still
  enforced at COMMIT; only the *timing* of the check shifts.
- Considered + rejected:
  - **Two-pass write with a sentinel slot** in
    `update_week_meals` — works on any DB (including the SQLite
    tests), but introduces a `__pending__` slot value that has to
    be invariant across the codebase forever and adds a second
    flush per swap.
  - **Single raw `UPDATE ... CASE id WHEN`** — atomic at the SQL
    level but bypasses the SQLAlchemy lifecycle hooks (`updated_at`,
    change events, `auto_regenerate_grocery_for_week`) that
    `update_week_meals` already wires up. The fanout would have to
    be re-issued by hand.
- The deferred-constraint fix keeps the application code unchanged
  and is the Postgres-native solution for "swap two rows under a
  unique constraint". SQLite (used in pytest) parses but ignores
  `DEFERRABLE` on UNIQUE constraints, so the end-to-end regression
  test (`test_swap_meals_between_slots_does_not_500`) is skipped on
  SQLite; only the model-declaration unit test runs in CI.
  Acceptable until/unless CI gains a Postgres backend.

## 2026-05-22 - Run the mounted MCP sub-app's lifespan from the FastAPI lifespan

- `app/main.py` mounts the MCP Streamable-HTTP app at `/mcp` via
  `app.mount(...)`. Starlette does not execute the lifespan of a
  mounted sub-app, so the MCP `StreamableHTTPSessionManager` was
  never started — every authenticated `/mcp` request returned 500.
  The remote MCP connector had never worked since build 97; only
  the unauthenticated 401 path was ever smoke-tested.
- Fix: the FastAPI `lifespan` now wraps its `yield` in
  `async with _mcp_app.router.lifespan_context(_mcp_app):`, running
  the mounted app's startup/shutdown (session manager + the MCP
  module's migrate/seed lifespan).
- The MCP module lifespan re-runs migrations + seed; idempotent and
  harmless — not worth refactoring `build_http_app()` to pass a
  no-op lifespan.
- General rule for this repo: any mounted ASGI sub-app with its own
  lifespan must be wired into the parent lifespan the same way —
  Starlette will not do it automatically.

## 2026-05-30 - Bug-sweep fixes land in tiers: auto-fix contained, flag the rest

- A multi-agent sweep surfaced 101 findings (6 crit / 23 high / 35 med / 37 low); see `phases/bug-sweep-2026-05-30-report.md`.
- Decision: auto-fix only the **contained, server-side, test-coverable** confirmed critical/high (14 of them, commits `21072f4..5e31ef7`). Do NOT rush: (a) security-critical crypto (IAP cert-chain F22), (b) architectural changes (MCP identity F11), (c) the delicate assistant streaming/transaction path (F9/F10), (d) iOS fixes that can't be verified without a build (F16/F17/F29), (e) deploy-sensitive migrations (F20). These are flagged for dedicated work.
- **F22 (IAP forgery) is latent, not dormant:** it's currently masked only because trial-mode grants Pro to everyone. It becomes a live paywall bypass the instant M5 monetization turns trial-mode off. Fix it BEFORE flipping `trial_mode_enabled` off. Open decision: official `app-store-server-library` vs hand-rolled Apple Root CA - G3 pinning.
- Systemic root cause noted: multi-tenancy is an app convention, not a schema guarantee (`household_id` is nullable in the DB despite NOT NULL models, F20), and the `CurrentUser(id, household_id)` split is the source of the recurring "passed user_id where household_id expected" IDOR class. A scoped-lookup helper + NOT NULL migration would prevent recurrence.
- Verification method: adversarial 3-lens majority vote per finding; 0 of 29 critical/high were refuted. A per-agent timeout that started at enqueue (not execution) caused false "uncertain" verdicts under the concurrency cap — re-run with a timeout well above total wall-clock.

## 2026-05-30 (pm) — Medium/low sweep: themed batches, verify-before-implement, defer the unverifiable

- Cleared the ~71 medium/low sweep findings in 8 themed commits (`0e34ab3..d7ae052`) grouped by concern (auth/admin, iap, data-integrity, error-handling, robustness, concurrency, iOS) rather than one-finding-per-commit — keeps related changes + their tests reviewable as a unit.
- Re-scoped every finding against current code before touching it. This debunked several false positives that would have been wasted work: M13 session-JWT alg (PyJWT already pins the algorithm for a symmetric secret), M26 entitlements bypass, and the "account takeover" half of M58/M67 (find-or-create matches on provider `sub`, never email). It also surfaced that M63's real committing path is the MCP `ingredients_resolve` tool, not the REST route the finding named (REST `get_session` never commits).
- Concurrency fixes (M15/M27/M30) chose DB-level guarantees over app-level locks: `uq_household_members_user` (migration 0046, with a keep-earliest de-dupe for pre-existing violators) makes "one household per user" a schema invariant; `increment_usage` is a dialect-aware `INSERT … ON CONFLICT DO UPDATE … RETURNING` so the +1 is atomic in the engine; `claim_invitation` takes `with_for_update` (no-op on SQLite tests, enforced on Postgres). Single-threaded TestClient can't exercise a real race, so the auth test forces the recovery branch via a miss-first session proxy + asserts the constraint directly.
- Deferred 7 items (M8, M37, M40, M62, M63, M64, M66) with scoped backlog entries rather than rushing them tail-of-session: each needs either broad cross-cutting threading, perf benchmarking, an iOS build, or a return-shape change with test ripples. Deferring-with-a-plan beats a hasty half-fix.
- iOS reality: only SimmerSmithKit (a SwiftPM package) is buildable in this environment — used `swift build` to verify M44/M45/M48. App-target changes (M41/M42/M43/M47) are inspection-only and flagged needs-build; `os.log` import needs no project change (system module).

## 2026-06-02 — Two product decisions + clearing the deferred sweep findings

- **AI/MCP-resolved ingredients are household-private, not global `approved`.** The catalog is a hybrid: a shared admin-curated `approved` tier + per-household private tiers, with a submitted→review governance path. Auto-promoting every household-driven resolution into the global approved tier bypassed that review and accumulated unvetted/hallucinated rows. Decision: `resolve_ingredient(household_id=…)` mints `household_only` rows for genuinely-new ingredients; existing approved rows are still reused first (common ingredients stay shared, no fragmentation). System/seed paths (no household_id) keep writing global approved.
- **Kroger pricing dropped, not hardened (M37).** It was dormant (no creds, every call 503s) and the per-item fetch had no cap/budget. Rather than add a safety cap, dropped the feature: deleted the Kroger client + store-search + UPC-lookup + the blocking `fetch_kroger_pricing` + the assistant tool. Kept the *generic* manual-pricing surface (import route, RetailerPrice/PricingRun tables, MCP pricing tools) since it's retailer-agnostic. Kept `ACTION_PRICING_FETCH` defined-but-unincremented to avoid churning the profile-usage shape and entitlement tests. No destructive DB migration. iOS: removed the two entry points; since `kroger_location_id` becomes unsettable, the remaining Kroger UI self-hides. Full iOS dead-code deletion deferred to a build-capable pass.
- **Preview vs save split for catalog writes (M64).** `_with_nutrition_summary` (all 6 import/AI-draft *preview* routes) resolves with `persist=False`; the actual save path (`upsert_recipe`) persists with the household. Clean split — preview never writes throwaway rows; novel ingredients mint on save.
- **E2E method.** iOS can't be unit-tested here, so verification = `xcodebuild ... -destination 'generic/platform=iOS Simulator' build` (compiles every iOS change) + a local uvicorn (`SIMMERSMITH_API_TOKEN` bearer, trial mode) curl-smoke of the changed endpoints + a human simulator pass connected via "Use a self-hosted server". The Connection screen's bearer-token field is the dev auth path (no SSO needed for local).

## 2026-06-13 — Ultracode bug bash + T1 household-scoping fixes

- **Bug bash was report-first, not auto-fix.** Unlike the 2026-05-30 sweep (which auto-fixed contained crit/high inline), this run produced a committed audit doc (`phases/bugbash-2026-06-13-report.md`) and stopped for the user to choose. They picked "kill root cause T1 first" — the unfinished M21 pivot, which is exactly the systemic root cause flagged on 2026-05-30 ("`CurrentUser(id, household_id)` split is the source of the recurring passed-user_id-where-household_id IDOR class"). Fixing the cluster (9 bugs) beats fixing each in isolation.
- **Verification-method fix from last sweep worked.** The 2026-05-30 note about a per-agent timeout starting at enqueue (causing false "uncertain" verdicts) — this run set the adversarial-verifier timeout well above total wall-clock and got clean signal: only 10 of 65 findings refuted, high/critical got a 3-lens refute/reproduce/independent majority vote.
- **Constraint re-key is dialect-split, not uniform (migration 0047).** `Base` has no `MetaData(naming_convention=…)`, so Alembic's SQLite batch mode can't reflect the *name* of an inline `UNIQUE` constraint to drop it (verified: `get_unique_constraints` returns `name=None` on SQLite). Decision: branch by dialect — Postgres (prod) does the clean `drop_constraint`+`create_unique_constraint` by name; SQLite (tests) adds the new invariant as a **unique index** and leaves the old user-keyed UNIQUE in place (harmless: for any household-deduped data it's strictly implied by the new constraint, never rejects a valid cross-member row). Tests run on SQLite via `run_migrations()` so the migration itself had to survive there; verified up→down→up. The clean fix for the divergence is a repo-wide naming_convention (arch finding, separate scope).
- **update_profile: scope-to-caller upsert, not plain scope-to-caller delete.** The arch rec was `delete(Staple).where(household_id, user_id)`. But under the new household-wide UNIQUE, a caller re-listing a staple a *housemate* already owns would then IntegrityError on re-insert. Decision: delete only the caller's own rows, flush, then skip any normalized_name a housemate already owns (re-insert only genuinely-absent names). Never touches housemates' rows; never violates the constraint.
- **create_or_get_week recovery uses a SAVEPOINT, not a full rollback.** A bare `session.rollback()` on the IntegrityError (the auth.py M15 pattern) would revert the caller's *other* in-transaction work — the exact M30-class hazard flagged for `create_solo_household`. Decision: `with session.begin_nested(): session.flush()` so only the failed insert unwinds, then re-SELECT and adopt the winner. (No prior `begin_nested` usage in the codebase; this introduces the savepoint pattern the arch review recommended.)
- **AI-gen 120s-timeout → bare 500 deferred, not folded into T1.** Live regression surfaced that `ai_timeout_seconds=120` is too tight for gpt-5.5 full-week generation (~118s direct), so `POST /weeks/{id}/generate` exceeds it and the `httpx.ReadTimeout` (not a `RuntimeError`) escapes the route's `except RuntimeError` as an unmapped 500. This is arch finding T7 (no error mapping) + a config-tuning matter, independent of the tenancy fixes — backlogged separately rather than scope-creeping the T1 commit.
- **Live AI regression is the real gate for backend-only changes.** T1 touched no iOS/schema-contract surface, so a simulator drive would re-exercise unchanged screens. The meaningful check was: does AI still work after the `week_planner` context change? Ran the planner end-to-end with the real OpenAI key — valid 21-meal plan, and `gather_planning_context` now returns the household pantry (empty pre-fix). That + 511 green unit tests is the regression evidence.

## 2026-06-13 (pm) — T7 observability + error-handling

- **The surfaced 120s-timeout/500 was promoted from "deferred" to "done this session"** because the user picked T7 next and it's the same root gap. Fixed inside the T7 cluster rather than as a one-off.
- **`AIProviderError` subclasses `RuntimeError` deliberately.** Provider transport/HTTP/parse failures are now a distinct type, but making it a `RuntimeError` subclass keeps every existing `except RuntimeError` caller (week-gen, rebalance, assistant tools) working unchanged — only the generate route was taught to map it to 503 *ahead* of the generic RuntimeError→422. So no other route regresses; they just get a cleaner error object. The 503-vs-422 split is semantic: 422 = "your input was unprocessable, don't blindly retry"; 503 = "upstream blipped, retry is fine."
- **Kept the `_RequestLogMiddleware` `print()`.** The arch finding flagged "bare print()", but the author's docstring documents *why* — it survives any logging reconfiguration and is ASGI-level so it never buffers/streams. Replacing it would risk the one reliable prod request-log channel. T7 instead fixed the *real* gap: the app's `logging.getLogger(__name__)` loggers were dropped (root at WARNING, no handler). `configure_logging()` adds the root stdout handler; the middleware stays as-is.
- **The 500-handler is observability, not behavior change.** Starlette already returns 500 for unhandled exceptions; the value of `@app.exception_handler(Exception)` is (a) it *logs* method+path+traceback via the now-configured app logger (the REST surface previously had no error sink — that's literally why today's first 500 had no traceback anywhere), and (b) a generic body that never leaks an exception string. Verified the no-leak path in a test (secret in the raised message is absent from the 500 body).
- **Testing the logging config under pytest.** pytest's logging plugin owns the root level during a run (resets it to WARNING), so asserting ambient `root.level == INFO` is flaky. The test instead calls `configure_logging()` and asserts its *direct* effect (root level + a stdout StreamHandler) — deterministic regardless of the plugin.
- **Left as explicit follow-ups (separate scope, in roadmap):** the ~30 `HTTPException(detail=str(exc))` sites, the streaming-loop + `vision_ai` unwrapped provider calls (only `week_planner._call_ai_provider` was wrapped here), and model-output truncation detection. T7 fixed the highest-blast-radius gap (logging + global handler + the live-confirmed week-gen path) without a sprawling cross-route sweep.

## 2026-06-13 (pm) — T6 crashes / dead features

- **#3 cancelled-status: added `'cancelled'` to the schema Literal, did NOT map it to an existing status.** The report offered both. The deciding evidence was the iOS client: `AIAssistantSheetView.swift:331` already branches on `message.status == "cancelled"` and treats the field as a free String. Mapping cancelled→completed/failed would have *broken* the iOS cancelled-turn render. The DB column is already free `String(20)`, so only the `AssistantMessageOut.status` read-Literal needed widening. Left the `AssistantToolCallOut.status` Literal (running/completed/failed) untouched — tool calls never get "cancelled".
- **#18 fix was the column name, not removing the explicit child delete.** The report floated "or rely on ondelete=CASCADE." But SQLite (tests) runs with FK enforcement off, so the explicit `WeekMealIngredient` delete is doing real work there — removing it would orphan rows in the test DB. Fixed `meal_id`→`week_meal_id` and kept the explicit delete. (The sibling WeekMealSide-orphan-on-SQLite is a separate finding, #50, not in T6 scope.)
- **Verification split for T6.** The fixes are surgical (a column name, a Literal value, an exception guard, a tuple comma) and don't touch AI mechanics, so unit tests are definitive (523 green). The one genuinely new end-to-end path — #18, a previously-dead feature — got a live real-AI check (rebalance a day with pre-existing meals → 200 with an AI-rebalanced day), exercising the fixed delete-loop on real rows.

## 2026-06-14 — T4 event↔week grocery merge lifecycle

- **`manually_merged` is a new flag, not a reuse of `auto_merge_grocery`.** The merge state was tracked by `(auto_merge_grocery, linked_week_id)`, which collapses three distinct intents into two values: (a) auto-merged into the date-covering week, (b) user-pinned to a chosen week, (c) auto toggled off → unmerge. (b) and (c) both look like "auto=False + linked set", so the policy auto-unmerged the manual merge (#11). The report's no-migration option — "set auto_merge_grocery=True on manual merge" — fails for a manual merge into a non-date-covering or date-less week (the re-resolve drifts away). A dedicated `manually_merged` boolean (migration 0048) is the only encoding that separates all three; worth the small migration.
- **`keep_link` on `unmerge_event_from_week`.** `regenerate_event_grocery` unmerges-then-rebuilds-then-re-merges, but the unmerge cleared `linked_week_id` as a side effect — which lost the pinned week for a manually-merged event (after rebuild there's no date to re-resolve to). Added `keep_link=True` for the regenerate-internal unmerge so the link survives the rebuild; the public teardown paths (delete, explicit unmerge, #10 re-point) keep the default that clears it.
- **#37 fixed at the detection site, not the stored marker.** The merge writes `source_meals="event:{name}"` and that string IS shown in the iOS grocery row (GroceryView:184), so it must stay the human name. The bug was only that *unmerge* matched the mutable name. Changed the event-only detection to a name-agnostic `startswith("event:")` — the per-event scoping already comes from `merged_into_grocery_item_id`, so the name was redundant for scoping and only a liability on rename. No marker/display change, no migration.
- **#10 lives in `apply_auto_merge_policy`, not `_resolve_target_week`.** Just making `_resolve_target_week` prefer the date-covering week would re-point the *new* merge but leave the *old* week's `event_quantity` stale. The complete fix unmerges from the stale linked week (when `event_date` moved outside it) before re-resolving, so the old week is actually cleaned up.
- **Live check was route + migration, not AI.** T4 is pure merge-state logic — no AI or iOS-contract surface — so the 5 service-level integration tests (the exact functions the routes call) + 46 existing event/grocery tests are the real coverage. Live smoke confirmed the create/patch/merge/delete routes respond with the new column and the migration round-trips up/down/up; no value in a long AI run.

## 2026-06-14 — Backend backlog sweep via file-disjoint parallel lanes

- **Parallel implementation was made safe by file-disjointness, not worktrees.** The user asked (ultracode) to dispatch the remaining backend backlog. The hazard with parallel agents on one shared git tree is concurrent edits to the same file / migration-head collisions. Resolution: partition the 19 findings into 11 lanes whose source-file sets are pairwise disjoint, give each agent ONLY its files + one uniquely-named `tests/test_batch_<lane>.py`, and forbid commits, migrations, and edits to shared files (models/schemas/conftest/main.py) — flag those for the integrator instead. Disjoint files → concurrent edits can't corrupt each other; no worktree merge needed. Agents also did NOT run pytest (another lane's half-written file would import-fail); the full suite is the serialized integration gate I run.
- **Triage was folded into the implement stage, not a separate phase.** Each lane agent re-verified its findings against the post-T1/T4/T6/T7 code and skipped any already-fixed/false ones (the codebase had moved a lot). The pipeline was implement → adversarial review per lane.
- **The adversarial-review stage paid for itself — it caught 5 real defects the implementers shipped green** (because they couldn't run pytest): (1) split_summary's sentence-split left bare "1"/"2" fragments on inline numbered markers; (2) the pantry cadence semantic change silently broke a pre-existing committed test; (3) the SSO lane over-applied the T7 detail-sanitization to hand-authored SsoError messages, breaking 3 existing test_sso assertions and collapsing the provider-mismatch distinction; (4) the planner tests monkeypatched a function-local import that isn't a module attribute (all 4 errored, never ran); (5) the assistant T7 URL-leak fix sanitized the SSE frame but still stored the full exception in the client-visible AssistantMessage.error. Reviews read each lane's diff via `git diff -- <lane files>` (path-filter isolates a lane even on a shared uncommitted tree).
- **SSO T7 over-sanitization was reverted, not patched.** `SsoError` messages are all hand-authored domain strings (no provider URL/body), so the T7 "sanitize provider leaks" directive didn't apply. Reverted `app/api/oauth.py` entirely (the real #36 fix is the IntegrityError recovery in `sso.py`); repurposed the lane's new tests to assert the restored 400/"invalid state" behavior. Lesson for future T7 sweeps: only sanitize details that interpolate a raw httpx/provider error, not domain exceptions.
- **Subscription /verify IDOR honored the appAccountToken product nuance.** The fix raises 409 when a receipt's existing row belongs to another user and isn't positively bound by a matching appAccountToken — it does NOT hard-require the token (iOS doesn't send it yet). Tradeoff flagged: a same-receipt re-install under a fresh app user_id now 409s instead of silently migrating; the durable fix is iOS sending `PurchaseOption.appAccountToken` (out of backend scope, already on the M5/F23-F24 list).
- **Commits are 3 file-coherent thematic groups, not 11 per-lane or 1 mega-commit.** Lane file-disjointness means any whole-lane grouping splits cleanly with no hunk-staging: security/IDOR, correctness/data-integrity, assistant/T7. T7 sanitizations live in their owning lane's files, so they ride along rather than forming a 4th commit.
- **iOS + shopping-skill findings deferred, not attempted.** Swift can't be compiled/verified headless, so shipping client fixes from a non-building agent risks confidently-wrong code. The 16 iOS findings stay in the report for a build-capable pass; backend-only is what this sweep covered.

## 2026-06-14 (pm) — iOS bug-bash findings, done with build + sim

- **iOS fixes were done directly (Opus), not dispatched.** The build (xcodebuild) and simulator are the serialized verification gate, and a headless lane agent can't compile/run Swift — so a parallel dispatch would ship unverified client code. Implemented all 16 directly, then `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 16'` (BUILD SUCCEEDED) is the real gate.
- **Sim verification was scoped to what's actually observable, not all 16.** Stood up an open-mode backend, pointed the app at it (the documented `simctl spawn defaults write app.simmersmith.ios simmersmith.serverURL http://localhost:8080` + an ATS `NSAllowsArbitraryLoads` patch on the built `.app` + re-codesign — build artifact only, never in source), and screenshot-verified the highest-signal fix: MealIcon #2/#3 (Grilled Steak→meat not coffee, Eggplant Parmesan→generic not egg, with tea→coffee and eggs→egg still correct). Confirmed the app launches + connects (no runtime regression from the 16 changes) and `/terms` returns 200. The rest are logic-sound + compile-clean but need StoreKit (subscription #8/#9), APNs (#15), or EventKit (#16) harnesses to exercise — not worth elaborate sim choreography; the build + targeted screenshot is the proportionate gate.
- **#13 FAB overwrite is a two-layer fix.** `firstOpenSlot(dayName:)` makes the Week FAB prefer an empty slot (fixes the common case), AND `addQuickMeal` replaces in place (preserving the existing mealId) when the targeted slot is occupied — so even the all-slots-full edge is a clean recipe swap, never a silent nil-mealId overwrite of a different meal.
- **#16 reminders relies on inout write-back to the caller's mapping.** Moving the `GroceryReminderMapping.shared.save` into a `defer` (right after `mapping` is loaded) persists partial progress because Swift writes an inout Dictionary back to the caller even when the callee throws mid-loop. This matches the report's recommended fix and avoids re-creating duplicate reminders after a partial EventKit failure.
- **#7 added a real backend `/terms` EULA route** (app/main.py, mirroring `/privacy`) rather than relabeling the paywall link to "Privacy" — a functional Terms-of-Use link with subscription/auto-renewal disclosure is an App Store Review requirement on a paywall. The paywall now shows both Terms (`/terms`) and Privacy (`/privacy`).
- **Build number bumped in project.yml only (106→107), pbxproj left stale.** xcodegen/`release-ios.sh` regenerates the pbxproj at archive time, so project.yml is the source of truth; the sim build I verified used the existing 106 pbxproj. The 107 applies on the next TestFlight archive.

## 2026-06-15 — Rearchitect toward Apple-native / offline-first (CloudKit + Foundation Models); shrink, not eliminate, the server

Direction set this session (brainstorm + 8-agent backend inventory + WWDC26 capability verification). Spec: `phases/cloudkit-migration-spikes-spec.md`.

- **Goal reframed from "eliminate the central server" to "shrink it."** Inventory + adversarial critique showed full elimination is not realistic; the win is moving the *data plane* to CloudKit and the *AI plane* to on-device/PCC, retiring most of FastAPI+Postgres+Fly+scheduler+auth.
- **Driver = Apple-native + offline-first** (user's explicit pick). **Apple-only lock-in is accepted** as a deliberate product choice (forecloses Android/web for household data). iCloud becomes the identity → the Apple/Google sign-in + session-JWT layer is dropped, not migrated.
- **Drop the Claude.ai MCP connector** + its OAuth AS + web SSO (retire in SP-D). This is the single feature that otherwise forces a full public server; dropping it is what makes a near-zero-server default possible.
- **No forced payment, no feature gating.** Monetization = AI-cost pass-through: free on-device AFM 3 / Private Cloud Compute (free under App Store Small Business Program <2M downloads), **BYO-key**, or **our AI credits** (the only path needing a small, revenue-funded server). Consequence: the server-side freemium/entitlement/`UsageCounter` machinery is **dropped, not ported**.
- **AI is provider-agnostic** via the WWDC26 Foundation Models framework (one Swift call site → on-device / PCC / third-party clouds with the user's key). Cloud lane targets OpenAI, Anthropic, Gemini, and **OpenRouter→FOSS** (the FOSS lane is a deferred follow-up).
- **WWDC26 changed the calculus** (verified via Apple ML Research + developer.apple.com): on-device AFM 3 is a 20B sparse model (1–4B active) with multimodal + guided generation; third-party apps can call PCC free under the Small Business Program. This makes a free, server-free default AI tier viable — pending the Spike 2 quality check.
- **Spike-first.** Two load-bearing unknowns gate the migration and get throwaway spikes before committing: (1) can the household grocery smart-merge run client-side over CloudKit without corrupting under concurrent edits, and on which sync API (`CKSyncEngine` with explicit conflict resolution vs `NSPersistentCloudKitContainer` LWW); (2) is AFM 3 / PCC week-gen good enough vs gpt-5.5 + Claude. If grocery-merge can't be made CloudKit-safe, a sliver of server survives for it (and event↔week merge); if on-device week-gen underperforms, week-gen becomes a PCC/cloud-only tier.
- **Sub-projects** (each its own spec→plan later): SP-A CloudKit data plane · SP-B AI tiering · SP-C on-device platform (kills APScheduler) · SP-D migration + server retirement · SP-E credits gateway (optional). Household invite re-keying is designed in SP-A around CKShare (no solo-then-merge), not spiked now.

## 2026-06-15 (pm) — SP-A CloudKit data-plane design locked

Spec `phases/cloudkit-sp-a-spec.md` (11-agent blueprint over every model file, adversarially reviewed; resolutions in §11). Key irreversible/directional calls:

- **One household = one custom CKRecordZone = one CKShare.** A CKShare shares a ZONE, so every household-scoped record (weeks, recipes, pantry, events, aliases, household-tier catalog) lives in ONE zone; the zone identity replaces every `household_id` FK — there is no household_id column on any record. Households are **born shared** (day-one CKShare, even a household of one) — this deletes the entire `create_solo_household`→`merge_solo_into`/`claim_invitation` re-keying path.
- **One physical sync stack per household zone = CKSyncEngine.** Two stacks can't co-own a zone (change-token race). The household zone is driven by ONE `CKSyncEngine`; sticky-merge records (grocery, event) get the custom field-merge resolver, plain-CRUD household records ride the same engine as LWW pass-through. The per-user PRIVATE zone (profile/prefs/assistant transcript) uses `NSPersistentCloudKitContainer`; PUBLIC catalog is a read-only cache.
- **recordName policy is irreversible — chosen per record type before Phase 0** (preserved-legacy-PK vs deterministic-key vs random+post-sync-dedupe). Mutable values (e.g. `WeekMealIngredient` content hash) may NOT be recordNames — they become queryable match-key fields. CloudKit schema is additive-only; the Production schema freezes before any user data syncs.
- **iCloud account IS identity** — no user table/JWT; the one-time per-household export→import preserves PKs as recordNames, round-trips sticky fields verbatim, and is gated by a `MigrationReceipt` sentinel + a server migration-status ledger (so "all households migrated" is knowable before SP-D retires Postgres).
- **Adversarial review caught a real reintroduced bug**: the draft's grocery-dedupe "collapse into lower recordName" dropped the M68 `EventGroceryItem` repointing → event double-count; fixed to port the semantic keeper verbatim. Also forced a **Phase 0.5 coexistence spike** (CKShare-participant + dual-stack) before Phases 2-7 build on the unproven §4.2 keystone.
- **In-place migration** (not greenfield) — swap the data + AI layers under the existing SwiftUI app. **Provisioning a CloudKit container under the dev team gates all build phases.**
- Residual open decisions (spec §11): ownership-transfer (pin-to-owner recommended) · dormant-user sunset policy · whether the SP-E curator server is in scope soon vs PUBLIC ships as a frozen seed.

## 2026-06-15 (pm) — Sim CloudKit testing gotchas (verified on-device)

Driving the SimmerSmith app on a sim to test the CloudKit debug panel surfaced two hard-won facts:

- **A sim build that uses CloudKit MUST be code-signed.** `xcodebuild ... CODE_SIGNING_ALLOWED=NO` builds fine but **strips the entitlements**, so CloudKit raises a fatal "significant issue" at `CKContainer.m:747` ("your process must have a com.apple.developer.icloud-services entitlement") and the process **hard-crashes (uncatchable by Swift do/catch)**. Build normally — "Sign to Run Locally" (ad-hoc) embeds the entitlements on a sim; then CloudKit errors become normal catchable `CKError`s. (Also seen: keychain error -34018 "neither application-identifier nor keychain-access-groups entitlements" from the same unsigned build.)
- **CloudKit ops need the SIM signed into iCloud.** With entitlements present but no iCloud account, the op returns a clean `CKError "Not Authenticated" (9/1002)` — caught + shown by the panel, no crash. Signing a sim into iCloud (Simulator → Settings → "Sign in to your iPhone") needs a real Apple ID + 2FA and **cannot be automated** by an agent — it's a manual user step. The agent CAN do everything else: `simctl` install/launch/screenshot, `idb ui tap` by coordinate.
- **idb/simctl multi-sim gotcha:** with several booted sims, `simctl ... booted` and `idb --udid <X>` can target *different* devices (here the app was on "OF Shot iPad13", not the "iPhone 16" idb was querying). Always resolve the exact udid running the app and use it for both. Debug panel made reachable pre-auth via a `#if DEBUG` link on SignInView so CloudKit checks don't require backend sign-in.

## 2026-06-16 — Phase 2c: cross-account CKShare is fully automatable (no UI tap)

The earlier "can't automate share-accept" caveat was wrong — it only applied to the
`UICloudSharingController` tap-a-link UI. The programmatic path works headlessly across two real
iCloud accounts: owner creates the zone + `HouseholdProfile` + a `CKShare` with
`publicPermission = .readWrite`, then `CKFetchShareMetadataOperation(shareURLs:)` +
`CKAcceptSharesOperation` on the participant side accepts it; the participant then reads the root
record from `container.sharedCloudDatabase`. The share URL hands off cross-account through the PUBLIC
database (both accounts can read a public record). Verified live: OWNER on the iPad (one account) +
PARTICIPANT on the iPhone-16 (a DIFFERENT account) — the two CloudKit user-record IDs differ and the
participant reads the owner's profile. So the whole two-device/two-account suite (the standing SP-A
residual) is automatable; sign-IN still needs a human (Apple ID + 2FA), but everything after is driveable.

Sim/account topology used: iPad "OF Shot iPad13" (60369457) = savanne's iCloud; iPhone 16 (BDF51260) =
a different account. App installed on both; the iPhone reaches the debug panel via Settings (gear) →
scroll to Developer → CloudKit checks (it's signed into the backend, so the pre-auth SignInView link
isn't shown there).

## 2026-06-16 — Phase 5: field-merge only on a pending local edit + send-then-fetch ordering

Two related CKSyncEngine correctness rules surfaced wiring the event↔week merge on-sim:

1. **The fetch-seam field-merge runs ONLY when we hold an unsynced PENDING local edit** for that
   record (a genuine concurrent edit). Without a pending edit the remote is authoritative — take it
   (LWW). The earlier code merged on every fetch where a local copy existed; that let a deliberate
   unmerge (which clears `event_quantity` to nil) get *resurrected*: a peer with a stale local copy
   (event_quantity=3) and no edit of its own would run `mergeEventQuantity(3, nil)` → keep 3 (the
   "a stale regen never drops a contribution" writer-ownership rule), so the unmerge never landed.
   Gating on a pending edit fixes it; the other side of a true conflict is still caught at the
   serverRecordChanged seam.

2. **Manual fetch/send must be SEND-then-FETCH.** In the test harness we drive `sendChanges()` /
   `fetchChanges()` by hand. The fetch token lags our own sends, so `fetchChanges()` AFTER a local
   edit re-delivers our OWN previously-sent (now-stale) records as "remote" changes; combined with a
   pending newer edit, the merger resolves our new edit against our stale self-echo and resurrects
   the old value. Ordering each op as `sendUntilDrained()` THEN `fetchChanges()` (drain self-echoes
   while nothing is pending) mirrors what `automaticallySync` does continuously in the real app — so
   this is a harness artifact, not a real-app bug, but the gate (rule 1) makes it robust either way.

## 2026-06-16 — Phase 4: field-merge applies at BOTH conflict seams (not just fetch)

The sticky grocery merge (`FieldMergeResolver`, already built) must run wherever two versions of a
record meet, which on a CKSyncEngine is TWO places: the fetch handler (a peer's change arrives) AND
`serverRecordChanged` on send (our save lost the etag race). The 2a engine's serverRecordChanged
rebase copied ALL local fields onto the server record (local-wins LWW) — for a grocery record that
clobbers the other device's tombstone/override/check-state. So a pluggable `RecordMerger` is consulted
at both seams: grocery → `GrocerySyncMerger` (field-merge), plain records → unchanged LWW. The merger
writes merged fields onto a copy of the REMOTE record so the server change tag is preserved (the
re-save matches). A `needsResave` flag (merged ≠ remote) gates the push-back so two devices don't
ping-pong. `GroceryCodec` stores the logical clocks (createdAt/modifiedAt/check.at) as INT64 — exact
ordering; app-wiring (Phase 7) maps real timestamps → clocks. Verified live: a later auto-regen
concurrent with a peer's check+override converges with BOTH preserved (blanket LWW drops the check —
the Spike-1 corruption); tombstone stays monotonic under a concurrent regen.

Gotcha: CKSyncEngine.sendChanges() can BOTH deliver a serverRecordChanged to the delegate (which
re-enqueues the merged save) AND throw it as a CKError(2) partial failure. `sendUntilDrained` catches
the throw and keeps draining while the delegate left pending work — rethrows only if nothing is pending.

## 2026-06-15 (pm) — Phase 2b household records: manifest-driven codec (single source of truth)

The 12 household plain-CRUD record types are modeled by ONE pure-Swift manifest
(`HouseholdRecords.HouseholdRecordType`) carrying each type's recordName policy (PK passthrough vs
DET), field name+CloudKit type, and the CASCADE/SET-NULL reference graph. The manifest drives BOTH
the CKRecord codec AND the generated CKDSL schema (`allCKDSL()` → appended to phase0-schema.ckdb), so
schema and code cannot drift. Chosen over 12 bespoke value structs because 2b records are inert LWW
pass-through — a generic field-bag value (`HouseholdRecordValue`) carries them; typed domain structs
arrive at app-wiring (Phase 7).

Irreversible classifications locked (verified vs production SQLAlchemy ondelete + spec §6.3 +
phase0-schema §A/§C, with adversarial-review corrections): CASCADE (`.deleteSelf` CKReference) =
recipeIngredient/recipeStep→recipe, recipeStep→parentStep (self), eventAttendee/eventMeal→event,
eventMealIngredient→eventMeal, ingredientVariation→baseIngredient. SET-NULL in-zone (plain
CKReference) = recipe→baseRecipe (self), eventMeal→recipe/assignedGuest, eventAttendee→guest (spec
§6.3 overrides the Postgres guest CASCADE). Cross-DB/forward refs (plain STRING key, never a
CKReference — survives a shared→PUBLIC merge or a not-yet-defined Phase-4 target) = recipeTemplateID,
catalog baseIngredientID/ingredientVariationID, merged_into_id chains, event.linkedWeekID.
Bool→INT64 0/1; household_id/user_id dropped (zone identity replaces them). Deferred to Phase 4:
WeekChangeBatch/WeekChangeEvent/FeedbackEntry (their Week/WeekMeal/GroceryItem parents are Phase-4
records — landing them now would dangle refs + risk validate-schema rejecting an undefined REFERENCE
target). CASCADE is swept client-side by `HouseholdSyncEngine.deleteCascading` (CloudKit's
`.deleteSelf` only fires on the deleting device); the sweep scans the local store for `.deleteSelf`
edges, so it's manifest-independent. `hset:` (deployed) supersedes the stale spec §6 `hsetting:`.

## 2026-06-15 (pm) — Phase 0.5 coexistence verdict: Phase 1 uses NSPersistentCloudKitContainer

Ran the `CoexistenceSpike` live on the iPad sim signed into Taylor's iCloud (container `iCloud.app.simmersmith.cloud`). **Both halves passed in the same container, same process:**

- ✅ **NSPCKC** — `NSPersistentCloudKitContainer` store loaded + a note record written (count=1).
- ✅ **Manual CloudKit** — custom zone + record round-trip ('manual stack') + a `CKDatabaseSubscription`, i.e. the primitives a `CKSyncEngine` drives.

No token/zone/notification clash between the two. **Decision: Phase 1's per-user PRIVATE plane uses `NSPersistentCloudKitContainer`** — it auto-manages the CD_-prefixed schema + LWW for the bulk per-user types (profile/prefs/assistant transcript), and 0.5 proves a custom CKSyncEngine-style stack can coexist in the same container for the grocery-merge types (Phase 4) that need explicit field-merge. We do **NOT** need to go CKSyncEngine-everywhere. (Had either half failed — esp. a change-token/zone/notification clash — the fallback was a single uniform CKSyncEngine stack for all planes.) This unblocks Phase 1 implementation. Phase 0 custom-zone round-trip also returned ✅ live (`round-trip name = Phase 0 Test`), proving the `HouseholdZoneProvisioner` write/read path end-to-end.

## 2026-06-17 — SP-A residual decisions: Phases 6 / 8 / 9 unblocked (build-all directive)

User directed "go through all remaining phases at once," so the three residual §11 decisions are
taken as defensible defaults (build now; revisit if the product calls for it):

- **PUBLIC catalog (Phase 6) ships as a FROZEN ONE-TIME SEED.** The curator identity (SP-E small
  server running USDA/OFF ingest + governance promotion) is separate infra not yet scoped, so PUBLIC
  is curator-seeded once, read-only on device; `submitted`/`rejected` are **inert local flags** until
  the curation server exists (spec §8.1). The client gets the READ path now (`PublicCatalogReader`:
  cache common head → `CKQuery` PUBLIC by `normalizedName` on miss → caller mints a `household_only`
  fallback). No client write-to-PUBLIC path is built (by construction — arbitrary writes would corrupt
  the global catalog). When SP-E lands, the submission flow (household writes `submission_status='submitted'`
  to its OWN shared zone; curator republishes approved rows to PUBLIC out-of-band) layers on additively.

- **Dormant-user policy (Phase 9) = INDEFINITE COEXISTENCE HOLD.** The app never force-evicts a
  household that hasn't launched the iOS-26 build; it keeps working off its last-synced CloudKit state.
  Rationale: the CloudKit data is the user's own (no server cost pressure to evict), matching the
  no-forced-payment / low-pressure ethos. No comms-then-sunset date. SP-D (server retirement) proceeds
  once *active* households confirm their own migration receipt.

- **Migration-completeness signal (Phase 9) lives IN CloudKit, per-household — NO central operator
  view.** Because the server is being retired, there is no central place to aggregate "X% of households
  migrated." The per-household `MigrationReceipt` (in-zone, written by Phase 7's runner) IS the
  completeness signal; a thin client `MigrationLedger` reports the LOCAL household's status
  (notStarted/complete) + per-type record counts. Aggregate operator reporting is explicitly out of
  scope in the server-retired end-state (the spec's "operator view of remaining un-migrated households"
  presumed a surviving server; it doesn't survive).

- **AI seam (Phase 8) SP-A slice = the routing seam + a dropped-table audit; AFM-3 measurement stays
  iOS-27-GA-gated.** `AIProviderKit` (ProviderRouter tier-selection + KeychainKeyStore + provider
  stubs) is already built. SP-A's job is to confirm the seam routes light→on-device / heavy→cloud and
  that NO data-plane code path consults a dropped `Subscription`/`UsageCounter`/server-push record
  (audit: SP-A CloudKit sources are clean — the only "subscription" hits are legitimate `CKSubscription`).
  Real backends + the on-device AFM-3 measurement are SP-B / iOS-27 GA.

## 2026-06-18 — On-device TestFlight CloudKit testing + Phase-6 PUBLIC-write finding

SP-A CloudKit data plane verified ON A REAL DEVICE via TestFlight (builds 109–112): the in-app
"CloudKit checks" panel (Settings → developer, gated DEBUG || TestFlight sandboxReceipt) runs all
phases against the user's real iCloud account in the **Production** CloudKit environment. Getting
there required: schema deployed to Production via the CloudKit Dashboard "Deploy Schema Changes to
Production" (cktool can't write prod schema), iCloud entitlement in Release + a portal-regenerated
App Store provisioning profile with iCloud (manual signing — the ASC API key can't cloud-create
profiles), and the catalog fixtures seeded to prod PUBLIC via `cktool create-record --environment
production` (record CRUD works against prod even though schema import doesn't). Build 110 added a
"RUN ALL CHECKS" button (unified pass/fail); 111 fixed a false-fail (count a ❌ only when it starts
a line); 112 auto-retries transient network blips once.

**REAL FINDING (Phase 6 §8.1 invariant, caught on-device): the deployed Production schema grants
`_icloud` the CREATE permission on the PUBLIC catalog types, so any client can WRITE the global
catalog** — violating "the client cannot write public; a curator must" (spec §8.1). Root cause: the
manifest CKDSL generator emits `GRANT READ, CREATE TO "_icloud"` for every type; that's fine for the
private/shared household types (their writes are owner/participant-authorized, not role-based) but
WRONG for the PUBLIC catalog types. **Fix (SP-E curator hardening, TODO):** in the CloudKit Dashboard,
set the `_icloud` role to Read-only (remove Create/Write) on **BaseIngredient, IngredientVariation,
RecipeTemplate**, then Deploy to Production. Consequence: curator seeding then needs a CloudKit
server-to-server key (the cktool USER token becomes read-only on those types) — that server-key
curator path IS the SP-E infrastructure. The share-link publish path + household submissions are
unaffected (they don't write those catalog types to PUBLIC). Left RED in the on-device run-all as a
deliberate, tracked exception; the data plane itself is fully green.

## 2026-06-28 - Open-model AI providers (GLM-5.2 / Kimi-K2.6 / MiniMax-M3) with full reasoning replay

- **Direct per-vendor keys, ONE "Open models" Settings entry** (not an OpenRouter aggregator, not three
  sibling rows). The single entry's model dropdown spans all three vendors; the chosen model determines the
  vendor key (Keychain: zai/moonshot/minimax) + base URL. Chosen over OpenRouter to avoid the +5.5% fee and
  the per-call host-routing nondeterminism that would break the 6-iteration tool loop.
- **Full reasoning preservation (not the disable-thinking hybrid).** Two regimes by call shape: one-shot
  generate() disables thinking (clean JSON); the assistant tool loop ENABLES thinking and captures+replays the
  vendor's reasoning verbatim each iteration. Per-vendor: GLM `thinking.clear_thinking:false` + reasoning_content;
  Kimi `keep:"all"` + reasoning_content + HARD temperature 1.0 (descriptor overrides the loop's 0.3 — the #1
  silent-failure risk); MiniMax `reasoning_split:true` + reasoning_content + reasoning_details (replayed whole).
- **Descriptor registry replaces the binary openai/anthropic assumption** (`ProviderDescriptor`/`ProviderRegistry`);
  OpenAI/Anthropic keep their existing dedicated methods (zero regression surface). A vendor-agnostic
  `ReasoningTrace` (style + text + detailsJSON) threads through the loop; only the parser (capture) and encoder
  (replay) know the per-vendor style.
- **Reasoning replay is IN-MEMORY only — NO CloudKit migration.** Cross-user-turn history rebuilds from persisted
  markdown, so reasoning never needs to persist; the load-bearing change is one line in `AssistantEngine.drive`.
- **Empty vendor → GLM default** everywhere (resolveConfiguration / keychain id / Settings labels) so "accept the
  displayed default" is always a resolvable config (fixed a review-caught silent key-save no-op).
- **Out of scope v1:** OpenRouter; China-region hosts; vendors' Anthropic-compatible endpoints; json_schema strict
  mode; MiniMax image input. MUST-VERIFY-IN-CODE (live key, on-device gate): GLM clear_thinking:false replay
  contract; MiniMax /models existence + response_format honoring; Kimi 400 "reasoning_content is missing" string.
- Spec: `phases/oss-ai-providers-spec.md`. Shipped TestFlight build 134 (NOT pushed to origin).

## 2026-06-29 - Household sharing v1: zone-wide CKShare + adopt (no merge)

- **Adopt, not merge.** A joining partner ADOPTS the owner's household (sees + edits it); their own solo
  household zone stays PARKED in their private DB, never merged. CloudKit can't cheaply move records between
  two accounts' zones, and a non-atomic multi-table merge is the risk the old Fly path took — so v1 writes
  NO merge code. (Merge-into-shared is a deliberate later feature.)
- **Two CKSyncEngine instances, one per database scope** (Apple's documented model — one engine per scope).
  Owner runs the existing private-DB engine; a participant runs a SECOND engine on `sharedCloudDatabase` +
  the owner's zone. Realized as a `Role` (owner|participant(sharedZoneID)) on `HouseholdSession`, default
  `.owner` so every existing call site is unchanged. The engine was already DB-generic, so it barely moved.
- **Zone-wide CKShare**, not hierarchical (`CKShare(recordZoneID:)`, not `rootRecord:`) — a hierarchical share
  only shares the profile record, leaving the participant an empty household. NEW zone-wide methods were added
  alongside the hierarchical helpers (CloudKitDebugView still uses those). Named-participant model
  (`publicPermission = .none`, UICloudSharingController) for exactly one partner.
- **Per-scope sync-state** (`engine-state.json` vs `engine-state-shared.json`) and the
  CKShare record is filtered out of owner ingestion (`isShareRecord`). Zone-revocation purge is gated `!ownsZone`
  so an owner's own zone-deletion never wipes the owner mirror.
- **Accept-before-mint** (the critique's one real correctness hole): `ensureHouseholdSession` checks a pending
  share (PendingShareInbox) AND a durable participant marker BEFORE owner discovery, so a cold accept never
  orphan-mints a solo owner zone. Accept entry is the iOS-26 scene-delegate path (the deprecated app-delegate
  callback doesn't fire for SwiftUI WindowGroup); `CKSharingSupported=YES` required.
- **Post-accept fetch is best-practice INFERENCE, not Apple-documented** — the accepting device usually gets no
  push for its own acceptance and `accept()` can return before the zone is created, so we double-fetch with a
  1.5s backoff. This + the scene-delegate accept + zone-wide-share↔engine coexistence are MUST-VERIFY-ON-DEVICE
  (no Apple CKSyncEngine+sharing sample exists) — hence the mandatory two-real-device gate.
- **Fly invite/join retired**; `AppState.joinHousehold` hard-gated to a no-op so no path can merge/delete a
  household. Fly auth/identity untouched. Out of scope v1: N members, leave/un-adopt, settings sharing,
  owner-also-participant.
- Spec: `phases/household-sharing-spec.md`. Code-complete, NOT pushed; two-device gate published to harness-deck.

## 2026-06-29 - Voice week-planning: ~80% on-device split + review-before-apply, bypassing the assistant tool-loop

- **NLP/AI split (user's core question) = ~80% on-device / ~20% cloud, in 4 layers**: transcribe (on-device
  SFSpeech) → parse (on-device FoundationModels `@Generable`; cloud fallback) → resolve recipe-match (on-device,
  pure) → apply (on-device). The cloud only ever sees short dish strings, never the raw monologue. Guiding
  principle (from the tesela ref): *voice is a capture channel, not an intent engine.*
- **Two ParsedWeeklyPlan types on purpose**: the canonical plain `ParsedWeeklyPlan` + resolver + availability live
  in **SimmerSmithKit** so the date math + matching are **host-testable via `swift test`** (the critique's UTC
  off-by-one landmine deserved a runnable test, not a compile check); the app-target `@Generable
  GenerableWeeklyPlan` is a thin model-output adapter that maps into it. One tested resolve path.
- **No OS-version gate** — deployment target is iOS 26, so Speech + FoundationModels are always present; the
  on-device-vs-cloud choice is a pure RUNTIME `SystemLanguageModel.availability` branch. SFSpeech is the
  runtime-robustness transcription fallback, not a version fallback.
- **Bypass the assistant tool-loop for review-before-apply**: `sendAssistantMessage`/`AssistantEngine.run`/
  `weeks_update_meals` COMMIT on call (→ CloudKit). That conflicts with the user-locked review screen, so voice
  uses a one-shot structured `AIService.generate` (no write tool) for cloud parse and only calls `saveWeekMeals`
  AFTER the user confirms. `weeks_update_meals` is the commit seam only.
- **Intents map to existing app conventions** (T0 spike): non-recipe meals are just `MealUpdateRequest(recipeId:
  nil, recipeName:)` — eatOut→"Eating Out" (matches WeekView's manual path), leftovers→"<dish> Leftovers",
  skip→omit the row. No new model field.
- **Ineligible-HW-without-key product decision**: always show the "Plan by voice" entry; if neither on-device
  parse nor a cloud key exists, tapping shows a "set up an AI provider" prompt — never a hidden button or silent
  dead-end. Dictation + manual review still work without parse.
- API grounded in the **actual iOS 26 SDK headers** (`SpeechAnalyzer`/`SpeechTranscriber`, `SystemLanguageModel`,
  `respond(to:generating:)` String overload, `GenerationError`) — not session writeups. SpeechTranscriber engine
  itself is a deferred v1.1 enhancement; v1 ships SFSpeech transcription (works on every iOS 26 device).
- Spec: `phases/voice-week-planning-spec.md`; report: `phases/voice-week-planning-report.md`. Build 137 on
  TestFlight; on-device human gate published to harness-deck. NOT pushed.

## 2026-06-29 - Voice transcription = system keyboard dictation (custom audio engine removed; build 138)

- The build-137 custom `DictationService` (AVAudioEngine + SFSpeechRecognizer + AVAudioSession) **crashed**
  on-device with `_dispatch_assert_queue_fail` ("Block was expected to execute on queue") on the 2nd mic tap
  (re-entrant audio-session setup off the expected queue) and showed a blank listening sheet on first launch.
- **Decision (user):** don't run our own Parakeet/Whisper/SFSpeech transcription. The feature is just a **text
  box** that uses the **system keyboard's on-device dictation** (the keyboard mic) OR typing. This is what
  open-feelings does. Custom/third-party transcription is **deferred to iOS 27** to see if Apple opens up
  third-party dictation methods.
- Implementation: deleted `DictationService`; `VoicePlanningCoordinator` now takes `plan(text:)` (no audio);
  `VoicePlanningEntry` is a `TextEditor` sheet → Review. The composer mic button was reverted (the assistant's
  TextField already gets keyboard dictation natively). The PARSE layer (on-device FoundationModels / cloud) and
  the resolve/review/apply pipeline are unchanged — only transcription moved to the system keyboard.
- Net: zero app-level audio/speech APIs → the entire AVAudioEngine crash surface is gone; far simpler.

## 2026-06-29 - Voice parsing: on-device Foundation Models feature-flagged OFF; use the Settings model (build 140)

- Build 138/139 on-device parse (FoundationModels `@Generable`) hallucinated a full week from a one-meal
  input. Root cause was the schema description ("A FULL WEEKLY MEAL PLAN…") telling a small model to complete a
  week; fixed in 139 (extract-only prompts + dedup). But on-device quality is unproven and the FOSS cloud models
  are the near-term target.
- **Decision (user):** park on-device behind `OnDeviceParseService.isEnabled` (default **false**). Voice parsing
  always routes to `CloudParseService` → `AIService.generate` = whatever model is configured in **Settings**
  (GLM / Kimi / MiniMax / OpenAI / Anthropic). Dial in parse quality with the FOSS models first; revisit
  Foundation Models later by flipping the flag (restores on-device-first + cloud-fallback). No-key CTA unchanged.
- The on-device code (OnDeviceParseService, GenerableWeeklyPlan, VoicePlanningAvailability) stays compiled but
  dormant behind the flag — no deletion, ready to re-enable.

## 2026-06-29 - Voice apply MERGES into the week (fix: was wiping planned meals; build 141)

- **Data-loss bug:** `WeekRepository.saveWeekMeals(weekID:meals:)` is a full REPLACE — it deletes every existing
  `.weekMeal` whose id is not in the passed array (`existingNames.subtracting(newNames)`). The voice review
  applied ONLY the voice-proposed meals, so Apply **deleted the rest of the user's planned week**. (CloudKit has
  no trash; the deleted meals were unrecoverable.)
- **Fix:** `VoicePlanResolver.merge(voice:into:)` (SimmerSmithKit, host-tested) folds the reviewed meals into the
  week's existing meals keyed by `day|slot` — a voice meal overwrites its slot **preserving the existing slot's
  `mealId`** (updates in place, no duplicate), every untouched meal is kept. The review reads existing meals from
  `appState.currentWeek`/`browsedWeek` and saves the merged FULL set. Voice = add/update, never replace-the-week.
- Audited all `saveWeekMeals` callers: only voice passed a partial set. WeekGen's replace is intentional
  ("generate a fresh week"); WeekView edits all build `week.meals.map{…}` (full set) first.
- Also fixed: blank sheet on first open — `.sheet(isPresented:)` raced the coordinator binding; switched to
  `.sheet(item:)` (coordinator made Identifiable) so it presents atomically.

## 2026-06-29 - Sharing: share/invite works (142); accept fixed for the cold-launch race (143)

- **142:** `UICloudSharingController` was the root of a SwiftUI `.sheet` → it rendered then self-dismissed
  (it must be presented modally, not embedded). Fixed: `CloudSharingPresenter.present` shows it directly from
  the top view controller. Owner side then correctly listed the partner as "Invited" — share + invite confirmed.
- **143 (accept side):** partner tapped the link, app opened, nothing happened; owner still showed "Invited".
  Root cause: COLD-LAUNCH RACE — `ShareSceneDelegate.scene(willConnectTo:)` deposits the metadata in an async
  `Task`, while `ensureHouseholdSession` drains `PendingShareInbox` in its own task. Drain-before-deposit →
  metadata missed → boots as OWNER → `householdLaunchPhase = .ready` → the foreground retry (gated on `!= .ready`)
  never re-fires → metadata orphaned. Fixes: (1) call `processPendingShare()` right after `ensureHouseholdSession`
  in the launch task (a late deposit is drained and `adoptSharedZone` warm-swaps owner→participant); (2) drain on
  EVERY foreground (`scenePhase .active`), even when `.ready`; (3) `containerIdentifier` is a non-optional String
  — guard compares directly + is non-silent; (4) `print("[Sharing] …")` at every boundary so a TestFlight run is
  diagnosable via the device console. The two-real-device gate is still the proof.

## 2026-06-30 - Backup & restore: generic store-level snapshot + additive recover (build 145)

- **Safety net** after the voice data-loss incident. Architecture: a GENERIC store-level snapshot — every
  household-zone record via `HouseholdRecordCodec.decode` → `HouseholdRecordValue` → JSON (HouseholdRecords is
  now Codable + has `HouseholdBackup`/`BackupCodec`/`BackupFilePolicy`). Covers all 19 record types with exact
  IDs (chosen over a domain-level meals+recipes JSON: complete + faithful + one codepath). Images excluded
  (CKAsset, regenerable).
- **Restore = RECOVER (additive):** fetchChanges, then upsert each backup record (`apply` onto the existing
  store record to preserve the change tag, else fresh encode), sendUntilDrained, reload+mirror. Records present
  now but absent from the backup are LEFT ALONE — restore can only bring data back, never destroy.
- **Auto rolling snapshots:** once/day on launch (post-interactive), keep newest 14 in Application Support;
  manual "Back up now"; ShareLink export + `.fileImporter` restore. UI: `BackupRestoreSection` in Settings.
- **Adversarial review (10 findings, 3 critical — all on restore) fixed:** (C1) skip overwriting field-merger
  types (grocery check-state / event quantities) so an old backup can't clobber a member's live edit — preserving
  the change tag had bypassed the merger; (C2) participant-restore confirm warns it rewrites the SHARED household;
  (C3) raise sendUntilDrained to 30 passes + log if still draining (records are local + queued; bg sync finishes).
  Deferred: I5 (auto-snapshot runs post-interactive, not blocking launch), I2 (silent type-mismatch only on
  CloudKit corruption), M1 (scoped-resource already safe).
- 43 HouseholdRecords tests pass (serialization round-trip + retention policy). Device gate: the recover round-trip
  (back up → delete a meal → recover → it returns) — harness-deck `simmersmith/backup-restore-device-test`.
  Spec: `phases/backup-restore-spec.md`. NOT pushed.

## 2026-06-30 - PrivatePlaneStoreTests: skip-under-`swift test`, not `.disabled`

- Root cause confirmed: `ModelContainer(for:configurations:)` over a CloudKit-capable `Schema` hard-traps
  (SIGTRAP) in the un-entitled SPM `swift test` binary — even with `cloudKitDatabase: .none` — because the
  trap is about the binary's missing entitlement, not network/account state. `FileManager.ubiquityIdentityToken`
  was rejected as a gate for this reason: a dev Mac signed into iCloud would still trap.
- Chose a Swift Testing `ConditionTrait` (`.enabled(if:)`) keyed on an env var
  (`SIMMERSMITH_PRIVATE_PLANE_ENTITLED_HOST`) over moving the tests into the entitled `SimmerSmithTests` app
  target — same coverage, zero cross-target plumbing, and `swift test` now reports the 8 tests as explicitly
  skipped (with reason) instead of trapping the whole process and falsely printing "Test Suite ... passed".
  No host currently sets the var; running them for real still requires an entitled host (e.g. `xcodebuild test`
  against the app target) — that path is documented in the test file's header comment but not yet wired up.
- `SimmerSmithKit/Tests/SimmerSmithKitTests/PrivatePlaneStoreTests.swift`. `swift test --package-path
  SimmerSmithKit` now exits 0, no `signal code 5`, 117 tests pass / 8 skipped.

## 2026-07-01 - Assistant streaming Phase 3: fix within-message multi-block separator, keep deferring multi-turn

- Phase 3 verification (5-lens adversarial audit workflow) found the app wiring already forwards
  incremental deltas correctly (one shared `messageId` → `applyAssistantDelta` appends onto the seeded row;
  `URLSession.bytes.lines` streams; `@Observable` MainActor mutation re-renders per delta) — NO wiring change
  was needed. The audit's value was catching one Phase-2b correctness gap the 352 passing tests missed.
- **The gap:** an Anthropic message with ≥2 non-empty text content blocks (e.g. `[text, tool_use, text]`)
  streamed each `text_delta` verbatim, so `accumulatedText` = `"AB"`, while `parseAnthropicToolTurn` /
  `assembleTurn` join text blocks with `"\n"` = `"A\nB"`. Because `turnDidStream=true`, the engine uses
  `accumulatedText` and DISCARDS the correctly-joined `turn.text` → persisted/displayed content_markdown ran
  the two blocks together. **Fix:** `streamWithToolsAnthropic` now tracks `lastStreamedTextIndex` and yields a
  single `"\n"` delta when the live stream crosses into a different non-empty text block — matching the
  `"\n"`-join exactly (fires once at the boundary, never per-delta, never before an empty block).
- **Why NOT also "fix" the multi-TURN separator:** the spec's "Phase 1 separator nuance" note deliberately
  accepts that streamed text across >1 tool-loop ITERATION concatenates verbatim while the non-streamed
  fallback `"\n"`-joins turns — and calls the streamed form "more faithful (exactly what the model emitted)."
  That's a different case: separate model emissions across iterations, where no separator is the truthful
  rendering. The within-MESSAGE multi-block case is materially different — Anthropic's blocks are one emission
  the API consumer is expected to separate, and running them together drops whitespace mid-answer. So we align
  the streaming path to the non-streaming contract for multi-block, and leave the spec-acknowledged multi-turn
  divergence alone (revisit only if a real multi-text-turn case looks wrong on device).
- Anthropic-only: OpenAI/open-models stream a single `content` field, so their parse paths never `"\n"`-join.
- `SimmerSmithCloudKit/Sources/AIProviderKit/BYOKeyProviderTools.swift` + `BYOKeyProviderStreamingTests.swift`
  (1 new regression test). 353 CK tests pass; app builds. Device gate (live streaming proof) still HUMAN.

## 2026-07-01 - Streaming device test FAILED: AsyncLineSequence drops SSE blank lines (root cause) + error over-redaction

- **Device gate result (live keys):** Anthropic "did not stream"; OpenAI showed "temporarily unavailable"
  (key passed the Settings Test-Key button). Root-caused via a 4-lens audit workflow + empirical Swift check.
- **ROOT CAUSE (critical):** `URLSessionTransport.lines(for:)` split the response with `URLSession.bytes.lines`
  (`AsyncLineSequence`), which SILENTLY DROPS empty lines. SSE dispatches an event on the BLANK line, so
  `SSEParser` (dispatch-on-blank) never fired mid-stream on device → zero `.textDelta`s ("did not stream"),
  and at flush every `data:` payload had collapsed into one field = invalid JSON → empty turn. Verified
  empirically: feeding `data:{}\n\ndata:{}\n\n` through `.lines` yields the data lines with **all blank lines
  removed**. Fixtures never caught it because BOTH `MockLinesTransport` and the default `HTTPTransport.lines`
  (`split(omittingEmptySubsequences:false)`) preserve blanks — only the production `.lines` path drops them.
- **Fix:** new `SSELineSplitter` (byte→line, LF split, strip trailing CR, PRESERVE empty lines); the transport
  feeds `session.bytes` through it instead of `.lines`. New regression tests incl. a bytes→splitter→parser
  integration test that exercises the real framing path. Landmine recorded so no one reintroduces `.lines`.
- **Secondary (why OpenAI ERRORED not just went blank):** `streamWithToolsOpenAI` can only throw on a genuine
  non-200, so OpenAI returned a real HTTP error — but `AssistantEngine.describe()` flattened `.httpError` (which
  carries status + a redacted body) into the generic "temporarily unavailable", hiding it. The Settings Test-Key
  button only calls `listModels()` (GET /v1/models), so it passes even when chat/completions fails (quota/model/
  org-verification). **Fix:** `describe()` now delegates `.httpError` to the already-rich `AIError.errorDescription`
  (401→"rejected the API key", 429→"rate-limiting", else→"HTTP N + provider message"; body pre-redacted, truncated)
  so the next device test names the real OpenAI cause instead of masking it.
- `Providers.swift` + `SSEReader.swift` + `AssistantEngine.swift` (+ tests). 357 CK tests pass. Live streaming
  re-test pending on a fresh build.

## 2026-07-01 - OpenRouter replaces direct GLM/Kimi/MiniMax as the open-models provider

- **User decision (device test):** managing direct per-vendor keys (GLM/Z.ai, Kimi/Moonshot, MiniMax)
  is a pain; the models are cheap on OpenRouter. Use OpenRouter (one key, OpenAI-compatible, many open
  models by slug) as THE open-models path; keep direct-vendor support in code to re-enable later.
- **Architecture:** OpenRouter is modeled as a new `OpenModelVendor.openRouter` case — NOT the separate
  dormant `CloudModel.openRouter(String)` stub. This reuses the ENTIRE descriptor-driven open-models path
  (chatWithToolsOpenModels, streamWithToolsOpenModels, listModels, AIModelCatalog, key storage) with zero
  new provider code — the descriptor is the only kit addition. The app keeps the internal provider tag
  "openmodels" (so resolveConfiguration / persistence / keychain plumbing is untouched); only the picker
  label ("OpenRouter"), the visible vendor (pinned to `.openRouter`, GLM/Kimi/MiniMax hidden), and the
  vendor defaults changed.
- **Descriptor choices:** keychainKeyID "openrouter"; chatURL openrouter.ai/api/v1/chat/completions;
  `modelsURL: nil` (so Test-Key does a REAL authenticated chat probe — better validation than /models, and
  it catches quota/model errors); `reasoningStyle: .none` + no-op thinking params (OpenRouter normalizes
  reasoning across providers itself — sending vendor-specific `thinking`/`reasoning_split` would be wrong).
  Curated `fallbackModels` (verified live against the OpenRouter /models API 2026-07-01): glm-4.6/glm-5,
  kimi-k2.6/kimi-k2-thinking, minimax-m3, deepseek-v3.2, qwen3-235b-a22b-2507, llama-4-maverick; default
  z-ai/glm-4.6. UI: curated dropdown + a "Custom…" free-text slug field (user's chosen UX).
- **Reasoning replay is DEFERRED for OpenRouter** (`.none`): the tool loop threads messages + tool results
  without replaying reasoning. Works for the vast majority of models; if a specific model needs its
  reasoning fed back (OpenRouter's `reasoning_details` passthrough), that's a later refinement.
- **Migration:** a legacy persisted direct-vendor draft (glm/kimi/minimax) is migrated to OpenRouter on
  provider (re)selection (resetting the model), and empty-vendor resolution defaults to `.openRouter`
  everywhere (resolvedOpenVendor, resolveConfiguration) — consistent with the picker.
- Files: AIProvider.swift (enum), ProviderDescriptor.swift (descriptor) + tests; app: SettingsView.swift,
  OpenModelsPickerRow.swift, AppState+AI.swift, AIService.swift. 358 CK tests pass; app builds. Device gate
  (live OpenRouter key) pending a shipped build.

## 2026-07-01 — Architecture review ADRs (report: `phases/arch-review-2026-07-01-report.md`)

Five decisions from the 80-agent adversarially-verified review; all work filed as beads. User approved all
2026-07-01 plus: Reminders → port to CloudKit (keep feature) · backup export gets optional passphrase ·
iOS 26.0 deployment floor is intentional (FoundationModels).

### ADR-1 — SP-D is port-then-retire, two workstreams (epic 990)

Seven features are still Fly-backed and silently broken for migrated households (gated behind
`hasSavedConnection` = false): vision, seasonal, substitutions, recipe memories, ingredients/nutrition,
push scheduling, Reminders-grocery sync. **Nothing is deleted until its port lands** (beads 990.1–990.7).
Then the retirement chain: strip fallback branches (990.8) → retire the migration bridge (990.9, HUMAN
gate: final pg_dump archived + explicit confirmation; migration-loader receipts do NOT prove completeness
— loaders `try?`-drop per-item failures) → delete the 2,335-line APIClient (990.10). Terms/privacy re-host
off `simmersmith.fly.dev` happens BEFORE the server dies (990.11) — PaywallSheet and App Store metadata
reference those URLs. Python backend deleted last (990.12, archive branch first). Push becomes LOCAL
notifications (no server); the APNs entitlement stays — CKSyncEngine uses CloudKit pushes.

### ADR-2 — Monetization, CloudKit era: local StoreKit 2 truth; launch free; paywall dark

`Transaction.currentEntitlements` (SubscriptionStore, already serverless-ready) becomes the ONLY isPro
source; the Fly verify endpoint, App Store webhook, usage counters, and the "server wins" profile.isPro
invariant die with SP-D. Rationale: BYO-key removed the AI-cost pressure that motivated server-enforced
caps, and the current state is actively dangerous — a fresh install can complete a REAL purchase whose
only fulfillment path is the dying backend (bead 7f2 is the launch slice). Launch = free, upgrade UI
hidden behind a default-off flag. Future keyless-user revenue = credits-gateway tier
(`AITier.creditsGateway` already anticipates it) on a small non-Fly endpoint — post-launch spec (bead
bx1). Epic 98v re-scoped accordingly. This also resolves the App-Review tension of shipping a paywall
next to BYO keys.

### ADR-3 — Observability baseline before launch

Today: 66 `print("[Tag]")` sites vs 2 real Logger files, zero crash reporting, no log export; the Fly-era
`syncPhase`/`lastErrorMessage` actively suppress CloudKit errors, and `lastSyncError` on all 8 repositories
is read by no view — a TestFlight "my week vanished" is undiagnosable. Decision: (a) failed-save policy —
classify transient (re-enqueue w/ backoff) vs permanent (surface), with `quotaExceeded` a named path (bead
dab); (b) a CloudKit-era SyncStatus surface + banner (qrt); (c) `Logger` adoption with the existing bracket
tags as categories + OSLogStore-based export in Settings (79y). Fly-era sync state retires with 990.8.

### ADR-4 — Launch gates (blocks App Store submission)

Blocking: paywall fix (7f2) · PrivacyInfo.xcprivacy (he2) · destructive-action confirmations (ary) ·
Fly-migration sections hidden from new users (8o7) · data-loss guards (enx, 9i6, gju) · sync-failure
visibility MVP (dab→qrt) · accessibility pass on core flows (1sz — zero a11y API usage today) · App Review
notes must cover the no-BYO-key reviewer path (manual recipes are the 4.2 mitigation; note on bead vwq).
Explicitly NOT blocking (deliberate): localization (English-only v1), CloudKit query perf/pagination,
HouseholdLocalStore memory growth (c86, revisit at scale), CloudKitDebugView modularization.

### ADR-5 — Data-plane hardening: kill the full-REPLACE class; wire the repair layer

The build-141 voice data-loss bug was one instance of a CLASS: any path handing a partial set to a
full-replace save. The assistant's `weeks_update_meals` (highest-traffic mutation, LLM-driven) still has
it — merge-by-day|slot becomes the required pattern for every meals-set write (enx). Backup RECOVER gets
later-wins protection on plain record types so restore can only bring data back (9i6). The
built-and-tested-but-debug-only repair layer (WeekRepairAdapter, grocery dedupe) wires into production
sync (gju) — two-device households WILL produce duplicate slots/weeks and nothing self-heals today.
Engine wiring: merger set at init (not post-boot; window bypasses FieldMergeResolver), zoneEnsured locked,
adopt-vs-mint ordering audited (c7r); CKRecord copies at actor hand-off (pr9); account-change lifecycle
handled post-launch-gate (yqm).

## 2026-07-02 — From-zero re-review reconciliation (Fable; report: `phases/arch-review-v2-2026-07-02-report.md`)

The 2026-07-01 review's judgment layer was re-derived from zero (user request: prior orchestrator was
Opus): a fresh independent 114-agent evidence sweep (8 mappers + 8 lenses incl. two v1 never ran —
steady-state/scale and product-truth — one skeptic per finding, completeness critic, anti-anchoring rule
barring agents from reading v1's outputs), then Fable personally re-adjudicated every lead-tier judgment,
verifying the two highest-stakes claims by direct code read. 40 confirmed findings. Verdicts on the
standing decisions:

**CONFIRMED unchanged:** ADR-1 (port-then-retire — v2's product-truth lens independently verified the
ported features work and the residue inventory matches the plan) · ADR-2 (local StoreKit 2, dark paywall —
v2 found zero monetization findings post-fix) · the 990.4 recipe-memories schema and 990.5 ingredients
specs (v2 independently re-found memories as its own critical, validating the port's priority) · the
ToolRegistry no-capability-boundary arbitration (v2's skeptic refuted the same framing; the residual
testability concern is the god-object track, post-launch).

**AMENDED — ADR-5 (data plane), materially.** v1 missed the two deepest data-plane issues, and one v1
"sound area" was wrong:
- **Cold-launch store/token split (new, critical):** HouseholdLocalStore is rebuilt empty every launch
  while the CKSyncEngine token persists, so the store is silently partial after every relaunch — masked
  for browsing by the SwiftData cache and mostly healed on write by the rebase path, but auto-backups
  snapshot a PARTIAL household and store-dependent flows (assistant week ops, repair scans,
  restore-reload) run on incomplete data; retroactively explains the Week-not-found/participant-empty-week
  bug class. Decision: interim token-reset-on-empty-store (bead r8q, P1), then proper store persistence
  (e0a) which retires the hack.
- **Rebase is local-always-wins, not LWW (new, critical):** the serverRecordChanged branch copies every
  local field onto the server record for all 16 non-merger types — a field-level lost-update on ordinary
  two-device edits. v1 praised this seam (structure, not semantics — recorded as a review-method lesson).
  Decision: record-level updatedAt LWW at the rebase seam (6ce); FieldMergeResolver stays for the 3
  sticky types.
- The full-REPLACE kill extends to UI callers: the enx fold must become the repo-boundary choke point,
  not a tool/voice-only guard (eky).
- Our own day-old gju code carries an isolation race + a swallowed destructive-pass error (9zf) —
  fleet-written code gets the same lens as legacy; adversarial verify of new code stays mandatory.

**AMENDED — ADR-4 (launch gates), additions:** published privacy policy is factually FALSE for the
current architecture incl. allergy-data flows (5w8 — content rewrite, beyond 990.11's re-hosting);
every assistant entry point outside Week dead-ends in ComingSoon (7pr); per-meal Create-with-AI +
Manage-sides on the default tab call the dead backend (962); PUBLIC catalog CREATE grant still open
since 2026-06-18 (9wr, user Dashboard op); share-accept parks solo data unwarned (lwi); the orphaned
onboarding interview gets deleted (mm1 — nothing reads its outputs; CloudKit-era onboarding is product
work, bead exc). ASC privacy nutrition label must match the BYO-key data flows (user step, in 5w8).

**AMENDED — ADR-3 (observability), elevated:** the critic's framing is adopted as the ADR's test —
"how would we know any confirmed failure mode is happening to real users?" MetricKit crash/hang
telemetry joins Logger+OSLogStore export as the baseline (0g5 + 79y); dab/qrt priorities re-validated
independently by v2.

**Review-method lessons (recorded):** (1) a "sound area" verdict requires semantic verification, not
structural reading — v1's rebase praise was wrong; (2) product-truth (feature-by-feature functional
sweep) and steady-state/scale lenses are mandatory for any future full review — they produced 3 of the
4 criticals; (3) resume-after-session-limit works (implements cache) but big fleets should launch just
after a reset window.

## 2026-07-02 — ADR: eky week-meal save is BASELINE-AWARE delete, not a slot-fold (refines the earlier "repo-boundary fold" note)

**Context.** `WeekRepository.saveWeekMeals` is a full-REPLACE: it deletes every store `.weekMeal` for the week whose id isn't in the passed array. All 9 WeekView UI mutators build that array from `week.meals` (a possibly-stale `displayedWeek` snapshot; the r8q cold-launch empty-store issue makes snapshots MORE stale), so a concurrent partner add the snapshot never saw is silently deleted. The earlier note said "make the enx fold the repo-boundary choke point." On implementation-grounding that proved insufficient:
- **Upsert-only (never delete absent)** breaks `rebalanceDay` and week-gen regen, which REPLACE a day/week's slots by passing new-mealId meals and relying on delete-by-omission → old day meals linger (a duplicated day).
- **Slot-keyed fold (MealMergeResolver) at the repo** reassigns mealIds by (day,slot): a `moveMeal` (same meal, new slot) becomes a new-slot upsert + a kept/duplicated source slot unless the caller emits an explicit CLEAR; swaps rebind record identity to slots; and it can't distinguish "removed" from "concurrent add" without CLEAR-marker plumbing in remove/move.

**Decision.** `saveWeekMeals` gains a `knownMealIDs: Set<String>` param = the mealIds the caller's SOURCE snapshot contained. Delete set becomes `existing − desired ∩ knownMealIDs`: a store meal is deleted ONLY IF the caller KNEW it (it was in their snapshot) AND dropped it. A concurrent add (id the caller never saw) is never in `knownMealIDs` → always kept. Correct for every caller, mealIds preserved on move:
- UI edits/add: known = displayedWeek ids; nothing dropped → no delete; concurrent adds survive.
- removeMeal: removed id is known + dropped → deleted.
- moveMeal: the meal keeps its id (upsert relocates in place) → no delete, no dup.
- rebalanceDay / week-gen regen: old day/week meals are known + replaced by new-id meals → deleted; concurrent adds on untouched days (not in the snapshot) survive.
- assistant/voice: keep their `MealMergeResolver.fold` (partial→full desired); pass known = the fetched `existing` ids so an explicit CLEAR (fold-removed slot) is deleted while concurrent adds survive.

**Testable core:** a pure `weekMealsToDelete(existing:desired:known:) = existing.subtracting(desired).intersection(known)` (host-tested); per-caller known-set correctness is code-reviewed + covered by the runbook Gate-1 two-device edit-storm device test. **Supersedes** the slot-fold-at-repo direction. Chosen by Opus (bead delegates the pick); user was away when surfaced.

## 2026-07-03 — Succession: Sonnet 5 is acting Lead while Opus/Fable are unavailable (weeks)

**Context.** Anthropic weekly usage limits exhausted 2026-07-03; Opus/Fable (the standing Lead
tier) are unavailable for weeks. The launch queue (epic 0lm) must keep moving across whatever
harness/model picks it up.

**Decision.** Sonnet 5 assumes acting Lead — an extension of the 2026-07-01 promotion (Sonnet 5
already owns all-but-hardest Lead work; `delegation-method` memory). The arch-v2 execution-plan
non-negotiables apply unchanged: independent adversarial verify per bead; personal backstop (run
BOTH swift-test suites + app xcodebuild yourself before commit — never trust an implementer's
report); impl agents get the explicit no-git/bd-authority line. Two things DEFER to Opus's return
rather than proceed: (a) sign-off on NEW CloudKit record-type schemas beyond the already-signed
990.4 spec (schema is additive-only/irreversible), (b) re-architecting anything an adversarial
verify rejects twice (escalation invariant). If Sonnet is also constrained: GPT-5.5 / qwen3.7-max /
glm-5.2 per the model scorecard (standing-authorized). Mirrored in bd memory `lead-succession`.

## 2026-07-06 — Conductor Arena judging failed (judge JSON format-bug + no unique winner); acting lead applied candidate A after independent review

**Context.** Conductor Arena `arena-20260706-111821-simmersmith-pwf` (opencode-go-harness-shootout, 6 candidates: pi/opencode × glm-5.2 / minimax-m3 / qwen3.7-max, `--parallel 1`) on bead `simmersmith-pwf` (BGTask double-complete + APNs `.noData`-before-work, senior/S). Pre-run I fixed the bead's `verify_cmd` from bare `xcodebuild build` (worktree-root-unsafe — no `.xcodeproj` at root, it's in the `SimmerSmith/` subdir) to path-explicit `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=<UDID> CODE_SIGNING_ALLOWED=NO`, and proved it locally before launch.

**Run outcome.** All 6 candidates implemented + externally verified BUILD SUCCEEDED — first Arena run here with a clean 6/6 verify (the verify_cmd fix held across every harness×model combo). Judging: 3 judges ran (qwen3.7-max, gpt-5.5, nw-glm52). `nw-glm52` emitted a substantively-correct verdict wrapped in a prose preamble + a ```json fence → Conductor's strict JSON parser aborted at line 1 ("key must be a string") before writing `report.json` or applying anything. The judges also did NOT converge on a unique winner: gpt-5.5 + nw-glm52 ranked candidate A (pi-glm52) #1; qwen37max ranked C (pi-minimax-m3) #1 and flagged E (pi-qwen37max) unsafe.

**Decision.** Acting lead (Sonnet 5, per the 2026-07-03 succession) took over selection + apply, treating the Arena's 6 verified candidates + 3 judge verdicts as decision INPUT (not authority). Independent adversarial review of A/C/D diffs verified C's disqualifying bug myself (not just trusting nw-glm52's claim): `syncTask` is `Task<Void, Never>`, so `try await syncTask.value` in C's `do { … } catch { setTaskCompleted(false) }` never throws → catch is dead → C reports `success:TRUE` on iOS expiration, contradicting the budget-honesty goal. Applied candidate A (pi-glm52, worktree commit `644b994` → re-committed `de6289b` on main with an Arena-attribution trailer), backstop-verified `** BUILD SUCCEEDED **` on main myself, closed the bead. A is clean, minimal-scope, 2/3 judges' #1, satisfies the literal acceptance (exactly-once + cancellation reach + sequence `.noData` after work); its conservative `.noData` (vs C/D's `.newData`) is honest for this app's deep-link-routing case (no new data fetched).

**Non-obvious points.**
1. **The conductor-arena skill's "don't patch around Conductor" rule was NOT violated.** Conductor produced NO result — it crashed on a judge format-bug. That rule governs rigging a result Conductor DID produce (or forcing a winner it refused to pick); here there was nothing to patch around, and the repo's `delegation-method` + `lead-succession` rules task the acting lead with backstop-verify + commit + close when the automated path fails. Resolved: lead-applied after independent review + personal verify, not a manual winner-pick over Conductor's objection.
2. **iOS-Xcode beads' `verify_cmd` MUST be path-explicit.** A bare `xcodebuild build` runs from the Arena worktree ROOT, where no `.xcodeproj` exists (it's in the `SimmerSmith/` subdir) → every candidate fails external verify identically. Fixed form (proven 6/6 this run): `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=<SIM-UDID> CODE_SIGNING_ALLOWED=NO` (UDID, not a spaced `name=` destination, so it survives `bd --set-metadata` + Conductor's shell without quoting). This is the THIRD Arena run here hit by a verify_cmd/CWD issue (7mb: `x2` shorthand; mm1: `swift test x2`; pwf: bare `xcodebuild build`) — set worktree-root-safe verify_cmds at bead creation.
3. **`nw-glm52` (neuralwatt/glm-5.2 thinking) is unreliable as a structured-output JUDGE** (fine as a candidate model): it emits verdict JSON wrapped in prose + a ```json fence, breaking Conductor's strict parser. gpt-5.5 emits pure JSON; qwen3.7-max emits prose+JSON but parsed OK. The harness-conductor judge pool should either strip prose/fences before JSON parse, or drop nw-glm52 from `[arena_judge]` (keep it as a candidate). Filed as a harness-conductor concern — not fixed here (this repo doesn't own Conductor).
4. **Judge reliability varies on the SAME bug:** qwen37max ranked C #1 but MISSED C's dead-catch bug; nw-glm52 ranked C #5 and CAUGHT it. The 3-judge panel surfaced the bug via the dissenting judge — argues for keeping the panel, not collapsing to one judge, even though it sometimes yields no-unique-winner.

## 2026-07-07 — Fable day: data-plane ownership + boot serialization (beads pr9, 0gf; also landed 13j/qrt/ebu/7mb)

**pr9 — HouseholdLocalStore owns its CKRecord instances (copy-in AND copy-out).** The Explore
sweep proposed copy-on-READ only (minimal choke point; write paths "already receive single-owner
instances"). Overruled: that safety rests on an UNENFORCED invariant (no caller mutates after
`save()`) — one future post-save mutation silently reopens the race. Store copies both directions
+ the three mergers and `rebaseNonMergerRecord` now genuinely copy the tag-bearing `remote`/`server`
before mutating (their "copy of remote" comments were reference-copies — CKSyncEngine's own event/
error instances were being mutated in place). Enabling fact, probe-verified: `CKRecord.copy()`
preserves `changedKeys()` exactly (and a full NSKeyedArchiver round-trip does too — recorded on
bead e0a for the store-persistence design). Cost: µs-scale copies; 5k-record cliff-guard test.

**0gf — one SerialTaskQueue for ALL session boots + sessionBootEpoch.** ensure's task-dedup never
covered the warm share-accept path; fix serializes both entry points (strict FIFO; ensure op
re-checks `householdSession` after predecessors → accept wins under both arrival orders;
`bootParticipantSession` must never self-enqueue — self-deadlock). The adversarial verify caught a
real regression in the queue-only design: a QUEUED boot op could run after sign-out teardown and
resurrect a session from the never-cleared participant marker (the old guard made second callers
merely await; the queue gave them their own deferred op). Fix: `sessionBootEpoch` captured at
request time, bumped first in teardown, re-checked at dequeue + every commit point; stale ops
detach what they built. Verify-gate lesson: lead-authored designs get the same adversarial gate —
it caught the lead's bug. Pre-existing mid-wire teardown window (identical under the old guard)
deliberately NOT pulled into scope → bead v89 (P4).

## 2026-07-09 — Replace OpenRouter with Ollama Cloud + NeuralWatt for visible open-model BYO-key AI

**Context.** The iOS app's open-model path was already descriptor-driven under the internal
`openmodels` provider tag. OpenRouter was only the visible `OpenModelVendor.openRouter` descriptor
in Settings, not a separate provider stack. The user asked whether Ollama Cloud subscription API keys
and NeuralWatt could replace OpenRouter entirely, and chose **Ollama Cloud + NeuralWatt only**; do not
ship `opencode-go` because its non-coding app-traffic terms are unverified.

**Decision.** Keep `ai_direct_provider = "openmodels"` and replace the visible vendor set with:
- **Ollama Cloud** — Keychain id `ollama`, OpenAI-compatible endpoint `https://ollama.com/v1`,
  defaults/fallbacks `glm-5.2`, `kimi-k2.6`, `minimax-m3`.
- **NeuralWatt** — Keychain id `neuralwatt`, OpenAI-compatible endpoint
  `https://api.neuralwatt.com/v1`, defaults/fallbacks around `glm-5.2-short` + GLM/Kimi variants.

OpenRouter remains only as a hidden legacy enum/descriptor so old code/tests can decode the value, but
it is not returned by `ProviderRegistry.allOpenModelVendors`, not offered in Settings, and persisted
hidden vendors (OpenRouter or the old direct GLM/Kimi/MiniMax cases) remap to Ollama Cloud at Settings
and runtime resolution. This closes the headless bypass where a stored `openrouter` value could keep
calling OpenRouter without the user opening Settings.

**Why.** This preserves the working BYO-key architecture, Keychain-only secret storage, model picker,
assistant tool loop, streaming, and Test Key plumbing while replacing the aggregator account. It avoids
a new top-level provider/migration surface and avoids using `opencode-go` in product until its terms are
verified.

## 2026-07-09 — Fable resumes Lead; arch-v3 = delta review + forward tracks (supersedes the 2026-07-03 succession)

**Context.** Opus/Fable returned from the multi-week rate-limit outage. The 2026-07-03 succession
ADR made Sonnet 5 acting Lead and deferred two things to Opus's return: (a) new CloudKit
record-type schema sign-off beyond the signed 990.4 spec, (b) re-architecting anything an
adversarial verify rejected twice. Both are now unblocked.

**Decision.** Sonnet 5 reverts to all-but-hardest Lead + Senior implementation per
`delegation-method`. The launch queue (epic 0lm, `phases/launch-runbook.md`) is unchanged and
still gated on user/device work. Session scope, user-approved 2026-07-09: **delta review of the
post-arch-v2 commits** (a907de6..HEAD) + **forward architecture** for four tracks + **new-product
proposals** + rolling implementation dispatch. Deliberately NOT a third from-zero review — the v1
(80-agent) and v2 (114-agent) reviews converged and the bead queue is their consensus; the
standing "don't re-review, implement" rule holds for everything they covered.

**Delta-review outcome (26-agent fleet: 5 lens finders → 3 diverse adversarial verifiers per
finding).** 7 findings raised, 7 confirmed (21/21 verifier votes), 0 refuted; Fable personally
re-verified the top three by direct code read. Filed: `glw` (P1, critical class),
`c57` (P1, fixed + committed `02b1974`), `ioj` (P1), `44q`/`bnh`/`gd5` (P2).

**The load-bearing finding — `glw`, and the lesson it carries.** `RepairScheduler.deactivate()`
has ZERO production call sites; its doc comment asserts the premise "a household session
activates once per launch and stays active," which `0gf` (the adopt-swap) had falsified *the day
before* `vda` shipped that comment. Consequences: an armed or in-flight destructive repair pass
outlives session teardown and the owner→participant swap; worse, in factory reset
(`deleteAllHouseholdZones` deliberately precedes teardown) an in-flight pass's next save hits
`.zoneNotFound`, and `handleFailedSave`'s owner path **re-creates the zone the user just asked to
erase**. The lesson generalizes the arch-v2 "fleet-written code gets the same lens" rule:
**a comment asserting an invariant is not evidence the invariant holds — check it against what
landed adjacent to it.** Each of `vda`, `0gf`, `7mb` was verified in isolation; nothing verified
their composition. Any future wave that lands multiple concurrency primitives in one cycle must
include a composition review before the build ships.

**Panel-dispatch lesson (scorecard-logged).** Three external reviewers were dispatched on the same
delta. gpt-5.5 and glm-5.2 (both lanes) **timed out at pi's 10-minute wall producing nothing**;
minimax-m3 returned truncated but usable output (its `automaticSync`-vs-`AsyncSerialGate` concern
is now an audit note on bead `hwi`). This is a TASK-SHAPE failure, not a capability verdict:
open-ended tool-loop repo spelunking does not fit a 10-minute one-shot. **External panel reviews
must be pre-digested** — inline the diff/spec into the prompt, no tool loop — which is exactly how
the same models were then used successfully to review the gateway spec.

## 2026-07-09 — ADR: credits gateway = subscription allowance on a Cloudflare Worker (realizes ADR-2's keyless tier)

**Context.** ADR-2 (2026-07-01) killed Fly-era server enforcement, made local StoreKit 2 the only
`isPro` truth, and named a future "credits-gateway tier on a small non-Fly endpoint" for keyless
users. `AITier.creditsGateway` exists in `ProviderRouter` and nothing serves it. Keyless users
have no cloud AI at all.

**Decisions (product half locked by the user 2026-07-09).**
- **Subscription with a monthly AI allowance**, reusing the existing `simmersmith.pro.monthly` /
  `.annual` products — not consumable credit packs. The D1 ledger supports packs later (a pack is
  a `balances.credits +=` fulfillment); shipping one product type keeps the App Review story and
  the fulfillment path single.
- **One-time trial grant** for keyless users, keyed on App Attest, with a self-reported
  private-plane `trialClaimed` marker as an honesty check. Gives App Review a working keyless AI
  path; prices in bounded reinstall fraud rather than building account infrastructure to stop it.
- **Cloudflare Worker + D1.** Deliberately not Fly (ADR-2), not a new always-on VM.
- **Identity = `appAccountToken`**, a UUID minted once per iCloud user and persisted in the
  CloudKit private plane (survives reinstall, syncs across the user's devices), set on every
  StoreKit purchase. This also finally activates the F23/F24 rebind check the Fly era left open.
- **JWS verification validates the x5c chain to Apple Root CA**, not just the embedded leaf — the
  F22 lesson, carried forward into the new gateway rather than re-learned.

**Architecture consequence worth stating.** The gateway is modeled as one more
`ProviderDescriptor` against an OpenAI-compatible endpoint, so `chatWithToolsOpenModels` /
`streamWithToolsOpenModels` / the tool loop / Keychain plumbing are reused with **zero new
transport code** — the same move that made the Ollama/NeuralWatt swap a descriptor change. What
the descriptor abstraction does *not* express (metering, 402→paywall, session refresh) is
confined to session acquisition beside `SubscriptionStore` and a `creditsAvailable` router input.

**Spec:** `phases/credits-gateway-spec.md`. Panel-reviewed (qwen3.7-max / glm-5.2 / minimax-m3).
Post-launch: nothing here blocks submission; the privacy-policy addendum for proxied prompt
content is an **activation** gate, not a launch gate.

## 2026-07-09 — ADR: the structural track's real product is a test host, not tidier files

**Context.** `AppState` measures 8,228 lines across 19 extension files. Epic `z69` has sat as an
untouched "post-launch structural" umbrella since 2026-07-02, framed as decomposition + protocol
seams + app-target tests.

**Decision.** Sequence it as S1 coordinator extraction → S2 protocol seams + fakes → **S3
app-target unit-test host** → S4 per-domain extraction wave (fan-out) / S6 ToolRegistry capability
boundary, with S5 (debug-view split) free-floating. Beads `z69.1`–`z69.6`, dependency-chained;
S1 is blocked on `glw` because they touch the same files.

**Why this order, and why S3 is the point.** The track's value is not aesthetic. Two arguments
decide it:
1. **The bugs cluster where ownership is diffuse.** `0gf` (boot races), `v89` (mid-wire teardown),
   `glw` (scheduler outlives session) are all the same shape: session lifecycle spread across
   `AppState+Recipes`, `AppState+Sharing`, and loose `AppState` fields. S1 gives that class one
   auditable home.
2. **Nothing app-side is testable, and that is why policy bugs ship.** `qrt`'s sync-status
   derivation and `ioj`'s failure-clearing policy both shipped untested because only the packages
   have test targets. S3 is the single highest-leverage bead in the repo: it makes app-side work
   **command-verifiable for the first time**, which is precisely what converts a bead from
   "in-session Lead work" into "ralph/pi-loop dispatchable."

**The dispatch corollary.** After S1–S3, each S4 domain bead owns exactly one `AppState+X.swift`
plus its new service file — **file-disjoint by construction**. That retires the hand-written
collision map this repo currently needs for every parallel lane (bd memory `parallel-lanes-build`).
The structural track is therefore an investment in cheap-model throughput, not in beauty.

## 2026-07-09 — ADR: no conversational onboarding interview (bead exc)

**Context.** The orphaned Fly-era preference interview was deleted in `mm1` (`416840f`); nothing
read its outputs. Bead `exc` reads "design the AI preference interview conversation flow," and the
obvious build is a chat that asks twenty questions.

**Decision.** Don't build it. Onboarding is **deterministic and keyless-safe**: a four-screen
non-AI flow capturing household size, hard avoids/allergies (writing real `IngredientPreference`
rows), cuisines, and week-start/timezone. Zero AI calls. AI deepening is offered **later** — once
a key exists or gateway credits are granted — as a pre-seeded assistant thread using the existing
tool loop and existing preference tables. No new interview engine, no new record types.

**Rationale.** (1) A keyless user cannot run a conversational interview at all, so it would be the
first thing a new user hits and the first thing that fails — and it is on App Review's reviewer
path. (2) The interview's real job is cold-start, and cold-start needs about five facts, not a
conversation. (3) The facts worth capturing are the ones that are load-bearing *and actually
wired*: hard avoids and allergies, which reach the planner via `hard_avoids` and the emphasized
allergy prompt line (`WeekGenContextGatherer.swift:46-60`).

**Correction, same day.** An earlier draft of this ADR argued partly that "the app already learns
preferences from `PreferenceSignal` scores and meal feedback, which beats a cold interview's
data." **That is false on the shipping architecture**, and is now bead `b9z`: rating a meal calls
the dead Fly backend, `PreferenceRepository.upsertSignal` has zero production callers, and
`WeekGenContextGatherer` hard-codes `strongLikes`/`likedCuisines`/`dislikedCuisines` to `[]`.
Only the ingredient avoid/allergy half is live. The conclusion stands — arguably strengthened,
since deterministic onboarding captures precisely the facts that *do* reach the planner — but the
reasoning must not rest on a learning loop that does not run. Do not claim the app learns from
feedback until `b9z` lands.

**Success metric for the spec:** a first-run user with no key reaches a plannable week without
hitting an AI dead-end — the same manual path that mitigates guideline 4.2.

## 2026-07-09 — ADR: the product-proposal fleet found what two review fleets missed

**Context.** A 50-agent fan-out generated new-feature proposals from five lenses (retention,
AI-native, friction, household-social, keyless), then stress-tested each with three adversarial
critics. Exactly **one** proposal survived. That looked like a poor yield until the *kill*
rationales were read.

**What the critics actually found.** To refute proposals they had to check whether the features
those proposals built upon were real. Two were not:

- **`b9z` (P1, Gate-2 blocker)** — meal feedback is a silent no-op end to end. The rating UI
  exists, its handler targets the dead Fly backend, `upsertSignal` has no callers, and the
  planner hard-codes empty likes/cuisines. M1's headline promise ("deprioritize poorly-rated
  meals via signal scores"), marked complete on the roadmap, does not run.
- **`80s` (P3)** — `recipes.lastUsed` is never written, so the "Never used" filter matches every
  recipe and the `lastUsed` sort is a no-op.

**Why both architecture reviews missed them.** ADR-1's inventory of Fly-backed features names
seven; feedback is not among them, and `bd search feedback` returned nothing. The v1 (80-agent)
and v2 (114-agent) reviews both asked "is this code correct?" and "does this feature call a dead
backend?" — but neither asked **"does this feature's *value loop* actually close?"** A rating that
posts successfully to a guard-nil'd client is not a dead-backend call; it is a dead *loop*.

**Decision (review method).** Add a **value-loop lens** to any future full review, phrased as:
*for each feature that claims to learn, adapt, or accumulate — trace the write, the read, and the
place the read changes behavior. If any link is missing, the feature is decorative.* Product-truth
(does it call a live backend?) is necessary but not sufficient. Recorded because the cheapest way
to find this class turned out to be asking a product question, not a correctness question — a
proposal fleet is a review instrument, and its kill rationales are the deliverable.

## 2026-07-09 — ADR: feedback→signal scoring is deliberately simple and inspectable (bead b9z)

**Context.** `b9z` found that the feedback→signal→planner loop does not close. The storage exists
on both ends (`PrivatePreferenceSignal` is a real `@Model` in the private-plane container;
`PreferenceRepository.upsertSignal` writes it), and the private plane is the correct scope —
taste is per-user, not per-household, consistent with the M21 ADR. **So there is no schema work
and no Lead schema sign-off**: only three edits (write on rating, add a list accessor, read it in
`WeekGenContextGatherer`).

The one genuinely non-mechanical piece: the Fly server derived signal scores from sentiment, and
that logic died with it. Something must replace it.

**Decision.** Keep it simple enough to reason about and test at the boundaries:
- A meal rating writes signals for **both** the recipe name and the meal's cuisine, as separate
  `signalType`s.
- `score += sentiment`, clamped to `[−3, +3]`.

  **Correction (same day, found at backstop).** I originally wrote "sentiment ∈ {−1, 0, +1}".
  That is not what the UI emits. `FeedbackComposerView` has a five-way picker:
  `Avoid = −2 · Bad = −1 · Neutral = 0 · Good = +1 · Great = +2`. So a single **Great** lands
  on score 2 — which *is* the `strongLike` threshold — and a single **Avoid** lands on −2, the
  dislike threshold. **Keep that behavior**: "Great" and "Avoid" are emphatic, one-tap
  statements and should count as one; "Good"/"Bad" are the incremental signals that need
  repetition. But say so out loud, clamp the *input* to `[−2, +2]` so no caller can leapfrog
  the thresholds, and test the ±2 path — the first implementation tested only ±1, i.e. only
  the values the UI never sends.
- `strongLikes` = recipe signals with `score ≥ 2`; `likedCuisines` = cuisine signals `≥ 2`;
  `dislikedCuisines` = cuisine signals `≤ −2`.
- Thresholds are constants in `SimmerSmithKit`, host-tested at the boundaries.

**Why so plain.** The failure mode here was never a bad weighting — it was a loop that did not
run at all, silently, for months, while the roadmap marked M1 complete. A clever decay curve
would add a second thing to be wrong about before the first thing works. `WeekGenPrompt.swift`
already renders these four sections faithfully; the prompt needs no change. Ship the closed loop,
watch it on real data, then tune.

**Reversible.** The scoring rule is an implementation detail behind constants, not a schema or a
contract. Changing it later costs one commit and re-derives from the stored `score` history. The
irreversible part — where signals live — is already settled by the private-plane model.

**If the rule stalls:** hiding the rating affordance remains a legitimate scope cut (option (b) on
the bead). What is *not* acceptable is the status quo: a visible control that does nothing.

## 2026-07-12 — Recipe memories port (990.4.2/.3): three boundary contracts

**Context.** Closing milestone `990.4` (Recipe Memories → CloudKit). Three small design calls with
long shadows, locked here so 990.8's fallback-strip and any future memories work inherit them.

**1. The UI keeps consuming `RecipeMemory`; the repository's `RecipeMemoryEntry` is mapped at the
AppState boundary.** `photoUrl` becomes a `ckmem:<id>` sentinel iff `hasPhoto` — the UI provably
uses it only as an existence flag + `.task(id:)` cache-buster, never as a URL. Repo order
(oldest→newest) is reversed once at the boundary to the section's newest-first contract, pinned by
`RecipeMemoryMappingTests`. Rationale: zero churn in four UI files; mirrors how every other ported
domain surfaces Kit DTOs. When 990.8 strips Fly, the sentinel can be revisited (or the DTO swapped)
in one place.

**2. Migration: memory TEXT is receipt-blocking; photos are best-effort.** Unlike images
("recoverable by re-attaching", per the recipe-image precedent), memory text is family cook-history
with no other copy. A real fetch failure saves what it got, drains, and withholds the "recipes"
receipt so the next launch retries (idempotent via PK-preserving upserts). 404 counts as "no
memories", not failure — otherwise a pre-M15 server would re-run the whole migration every launch
forever.

**3. `fetchRecipeMemories` surfaces 404 as `.notFound`, aligned with its M15 siblings.** The
generic `decodeResponse` folds 404 into `.server(...)`; the adversarial verify panel caught that
this made (2)'s 404 branch unreachable — my spec bug, prescribed from the sibling's shape without
grepping the actual decode path. Contract now pinned by `RecipeMemoriesNotFoundTests` over a
stubbed `URLSession` (first URLProtocol stub in the Kit tests; reuse it for future endpoint
contracts).

## 2026-07-12 — Ingredient resolution identifies a base before applying private preference

**Context.** The original `990.5` spike ordered resolution as locked variation → private
preference → PUBLIC → household → mint. Grounding before implementation found that private
preferences are keyed by base ID, not normalized name; `PublicCatalogReader` also lacked record-ID
and variation-by-base reads. A literal implementation would need a second preference index or
would silently skip preferences. The same pass found the manifest transform existed but no
production loader fetched Fly ingredient rows.

**Decision.** Locked links still short-circuit. Otherwise establish a base candidate first
(existing link → PUBLIC exact match → household exact match → household provisional mint), then
overlay an active preferred variation/brand for that identified base. Stale, inactive, avoidance,
or unresolved preferences preserve the candidate. Add read-only PUBLIC identity/reference/search
capabilities; never write PUBLIC. Migrate the complete household-owned Fly ingredient set through
a receipt-gated typed loader before switching reads; global approved rows remain PUBLIC.

**Why.** This preserves the product meaning—an explicit user preference wins—without duplicating
private-plane indexing or smuggling catalog ownership into the preference store. The migration
correction prevents a green CRUD port from silently abandoning existing household-only rows. Both
choices are reversible implementation policy over existing record types; no schema is added.

## 2026-07-13 — Release notes key on the build number, not MARKETING_VERSION

**Context.** Bead `simmersmith-224` specified a What's New catalog "keyed by MARKETING_VERSION",
presenting the current version's notes once per install/update. The purpose of the feature is that
a non-technical TestFlight tester learns what changed in each build she receives.
`MARKETING_VERSION` has been `1.0.0` for 150+ TestFlight builds and stays there until launch;
`CURRENT_PROJECT_VERSION` is what increments on every upload.

**Decision.** Catalog entries are keyed on `CURRENT_PROJECT_VERSION`. `MARKETING_VERSION` is
displayed alongside the build but never gates. Persist `lastSeenBuild` per-device in
`UserDefaults` (`release_notes_last_seen_build`); show every catalog entry with
`lastSeenBuild < build <= currentBuild` that has at least one item, newest first. An entry with
all three item lists empty is the explicit "nothing user-visible this build" answer: it satisfies
the release preflight and raises no sheet. `release-ios.sh` refuses to archive a build with no
entry.

**Why.** Keyed on the marketing version, the sheet would have fired exactly once and then stayed
silent through every subsequent TestFlight build — failing the only thing the bead exists to do.
The build number is additionally the sole monotonic release identity we ship, so it supplies the
total order the "everything since you last opened the app" query needs for free; no separate
sequence or date comparison is required. Reversible: the catalog is a Swift literal, and re-keying
is a filter change plus a defaults migration.

**Corollary worth keeping.** The gate is a pure function (`ReleaseNotesGate.unseen`) precisely so
these policies are pinned by tests rather than implied by view code. The clean-install rule
(`lastSeenBuild == nil` is treated as `currentBuild - 1`, not `0`) is load-bearing: reading a
missing key with `UserDefaults.integer(forKey:)` yields `0`, which would dump the entire release
history on every new install. That mistake is mutation-tested in `ReleaseNotesStoreTests`.

## 2026-07-13 — Leftover household zones are deleted automatically, on a fail-closed census

**Context.** Earlier builds' repeated orphan-minting left empty `household-*` zones in the
owner's private DB (13 on the reporting device). Discovery picks the data-richest zone and
ignores the rest, so they were harmless — but the app announced them on every launch via
`lastErrorMessage`, the *error* channel, warning triangle and all. Bead `simmersmith-auc`
proposed either a Settings button or a pass on the discovery result.

**Decision.** Cleanup runs **automatically**, detached, after `householdLaunchPhase = .ready`,
deleting only the leftovers it can *prove* are empty. No banner. A leftover that holds real
records survives and surfaces as a Settings row; one that merely couldn't be read stays silent
and is retried next launch. `deleteEmptyHouseholdZones` takes its OWN census rather than
accepting a caller-supplied count.

**Why the census returns `Int?`.** `recordCount` used to discard the CloudKit operation's
`Result` and return whatever it had tallied — `0` on failure. That is the *safe* direction for
RANKING (an unreadable zone must never outrank a readable data zone; an all-unreadable field
falls to `isAmbiguous` instead of guessing) and the *lethal* direction for DELETING, where `0`
is indistinguishable from "provably empty" — one transient CloudKit failure would delete a zone
full of recipes. The two callers therefore take deliberately opposite policies on the same
value, which only works if the value can express "I don't know". Hence `Int?`: ranking keeps its
fail-open `?? 0`; deletion is fail-closed and keeps anything it could not census. **Do not
collapse `nil` to `0` in the delete path.**

**The related trap.** `DiscoveryResult.ignoredHouseholdIDs` means *not chosen*, NOT *empty* — a
tie-break loser is ignored while holding every one of its records (`tieBreaksLowestID` pins a
loser with 40). The old banner's copy ("N leftover **empty** household(s)") was therefore wrong,
and the tempting one-liner — delete that list — would have destroyed live data. Cleanup never
trusts it; it re-censuses.

**Why automatic rather than a Settings button.** The user's data is loaded from the richest zone
either way, so there is no decision for them to make and nothing for them to inspect; a
confirmation prompt would only ask them to rubber-stamp a fact they can't verify. Running it
detached after `.ready` keeps a destructive CloudKit pass off the path that opens the kitchen,
and the pass is idempotent, so "it threw — retry next launch" is a complete recovery strategy.
The decision rule lives in a pure `classifyLeftovers` so the safety contract is unit-tested
rather than implied by the I/O code — same split as `chooseRichestHousehold`.

## 2026-07-14 — ADR: the six-week depth+stability program (audit-driven; supersedes the submit-ASAP posture)

**Context.** Owner-directed architecture + product-truth audit (Fable Lead; 5 Sonnet discovery
agents incl. a ~200-affordance census; adversarial peer panel gpt-5.6-terra / glm-5.2 /
gpt-5.6-sol in the pre-digested no-tools mode — 3/3 elite results, mode now validated). Full
report: `phases/arch-audit-2026-07-14-report.md`. 45+ verified findings → 24 new beads, 30+
updated, 2 folded. Owner locked direction the same day.

**Decisions (owner, 2026-07-14):**
1. **Depth + stability BEFORE submission; ~6 weeks.** The runbook's gates still define done;
   the week-by-week program in roadmap `### Now` defines how. Week 1 is stop-ship class and
   rides build 154 (headline: a TestFlight-reachable debug check that destroys real private-plane
   data — `deh`).
2. **Monetization: ADR-2 confirmed** — launch free, paywall dark, StoreKit products configured;
   NO credits gateway in this program. Activation gate (all must pass before the paywall ever
   shows): working keyless hosted-AI journey end-to-end; adversarial billing tests (JWS, App
   Attest, replay, idempotent accounting, restore, account switch, partner device); per-user +
   global spend ceilings, rate limits, provider timeouts, remote kill switch; graceful
   trial/subscription exhaustion to the manual app; complete privacy/support/review-notes/pricing;
   BYO mode stays free (or the sub carries clearly separate non-token value); a TestFlight soak
   with measured usage and bounded cost.
3. **Recipe images: restore photo rendering** (image-first, illustration fallback). Invisible
   spend stops in wk1 regardless (`xwb`).
4. **Dead-Fly duo:** hide the grocery feedback swipe for launch (signal semantics undecided);
   port Plan Shopping as a deterministic on-device store-split in wk4 ONLY if it stays bounded,
   else it stays hidden (`4ii`/`32i`).
5. **Assistant scope (owner override of Sol's stricter cut):** the read/proposal/commit ladder
   steps 1-4 PLUS token streaming (`3sf`) PLUS the first reversible write tools (grocery items,
   executor-validated, undoable) are pre-submission scope. Web search / deletes / bulk ops /
   preference writes stay post-launch. Streaming is the first cut if the program slips.
6. **Fly retirement split (Sol):** 990.8 (strip runtime fallbacks) pulls forward under strict
   conditions — fix/hide 4ii+32i first, APIClient quarantined behind a CI-enforced boundary,
   bridge stays fail-closed (`91e` first), defer if it grows. 990.10+ stay post-launch behind
   990.9's human gate. 990.11 (privacy/terms re-host) decouples and lands pre-submission with 5w8.
7. **z69 re-scope (Sol):** pull the OUTCOME forward, not the refactor — z69.3 (app tests in CI,
   timeboxed) is wk1; z69.1/.2 extract only the seams e0a needs; full structural wave post-launch.
8. **e0a rollout = shadow → cutover → recovery** (Terra requirements + Sol sequencing, recorded
   on the bead + report). The named risk: sync state advancing ahead of the durable mirror
   silently skips server changes forever — shadow digest comparison + forced-crash tests are
   mandatory before cached data drives UI.
9. **Onboarding is submission scope** (`jfn`): the recorded deterministic 4-screen flow, fully
   skippable, keyless-honest. exc stays the design record.

**Method notes (for future reviews).** (a) The pre-digested no-tools peer-review mode is now
3/3 at 5/5 quality across glm-5.2/terra/sol — tool-loop headless dispatch to these lanes stays
banned for review work. (b) The census's self-verification pattern (sub-agents + lead spot-checks
before reporting) caught the audit's worst finding (`deh`); keep it. (c) Adversarial verification
killed 3 plausible-but-wrong claims before they became beads (fast-path resurrection, same-turn
tool race, "fresh users never boot") — the backstop cut toward my own conclusions twice.

## 2026-07-15 — e0a uses a generation bundle and write-ahead intent journal

**Decision.** The persistent HouseholdLocalStore mirror will be a scope-validated generation
bundle, not a record archive beside `engine-state.json` or a new database. Every local mutation
and delivery acknowledgement first writes a monotonically sequenced durable transition; a serial
checkpointer writes the complete record/asset/outbox/receipt snapshot before the opaque CloudKit
state serialization, then atomically publishes one verified generation with the journal high-water
mark. The serial delegate's state update is bound to a mirror-coverage revision, so a token may lag
its records but can never lead them. Scope is container + database role + signed-in account record
name + zone owner/name + household + format version. P1 observes and canonical-digest-compares this
bundle while full fetch remains authoritative; P2 is the only phase allowed to restore it into the
active store.

**Why.** Two independently atomic files retain the catastrophic token-ahead-of-mirror window,
and CloudKit's pending-ID state cannot replay a pending save/delete or an explicit field clear.
The generation pointer makes incomplete record/state pairs unreachable; the journal covers the
window before a snapshot publishes; the included-sequence high-water makes post-pointer/pre-compaction
replay idempotent. Keyed-archive bytes are integrity-checked but never treated as a deterministic
logical digest. Asset bytes also need their own durable copy and the archived record must point at
that copy because current `CKAsset` URLs live under Caches. This deliberately costs more than a
keyed archive, but it makes the persistent cache safely recoverable across a crash, account switch,
and owner/participant swap rather than merely fast on the happy path.

## 2026-07-15 — P1 shadow capture waits for identity but never for active-engine construction

**Decision.** `HouseholdSession` resolves the account record name in an unstructured boot task.
Until it is available, P1 capture is disabled; the active `CKSyncEngine` still receives nil cached
state and takes the existing full-fetch path. Once identity resolves, a scope-validated runtime
observes the latest complete fetch/state boundary only; it never loads records into the active
store. The runtime synchronously persists local save/delete and delivery transitions before their
in-memory effects. One logical gate captures records, generation bookkeeping, state coverage, and
the exact outbox high-water; generation I/O then runs from that immutable boundary after the gate
releases while retaining later WAL frames. A missed/WAL mutation quarantines the scope
persistently; a failed candidate publication can retain the prior verified generation; a
same-launch boundary mismatch quarantines. Every failure leaves the shipping nil-state/full-fetch
session unchanged.

**Why.** A scope without the account record name cannot prove account isolation, while waiting for
`userRecordID()` before engine construction would turn a diagnostic shadow into a launch dependency.
The split preserves P1's safety boundary: a missing/late identity costs only shadow telemetry, not
access to current server data. Clear, account changes, and owner-to-participant detach fence the
old runtime before clearing or parking its scope, preventing a stale callback from publishing into
the next session.

## 2026-07-15 — Shadow durability uses dedicated GCD lanes and exact delivery generations

**Decision.** The checkpoint writer owns a serial GCD state/WAL lane and a separate serial
generation lane. Synchronous repository mutations call the state lane directly so their WAL frame
is fsynced before the in-memory mutation; async checkpoint publication awaits GCD completion and
never bridges through a blocked Swift task or semaphore. Generation construction cannot block WAL
appends, but final pointer installation, read-back, compaction, and recovery return to the state
lane. Session clear/park closes an immediate publication fence; clear atomically retires the root
before deleting it asynchronously, so neither lifecycle path waits on generation I/O. Direct
destructive writer APIs still drain already-started publications before mutation, and the
generation lane preserves publication order.

CloudKit delivery handling also resolves the exact mutation generation that was sent. A stale save
ack/failure may rebase a newer save but cannot resurrect over a newer delete; a stale delete result
consumes only the old delete and never tries to attach a record payload to that acknowledgement.
Failed deletes are no longer ignored: already-absent record/zone results consume the tombstone,
transient failures return it to pending, and permanent failures remain durably blocked. These stale
branches intentionally tighten the active conflict behavior because preserving a later user
mutation is the same invariant the shadow outbox records; keeping the older blanket replacement
would make the live store and durable intent disagree.

**Why.** The prior actor-to-synchronous bridge parked cooperative Swift threads while waiting for
another Swift task, which could starve the pool during initial fetch and put diagnostic shadow work
on the launch critical path. Dedicated GCD execution preserves the required synchronous durability
without that dependency cycle. Exact delivery transitions are required for crash recovery: an ack
or failure for generation N cannot be allowed to consume, rewrite, or resurrect generation N+1.

## 2026-07-15 — Live delivery generation remains one stamp per record

**Decision.** Keep `sentGeneration` as one replaceable stamp per record, not a FIFO. CKSyncEngine
finishes a batch and serially delivers its `sentRecordZoneChanges` event before requesting the next
batch; the pending list also deduplicates record changes. The reachable race is therefore one local
mutation between a payload stamp and its acknowledgement, which the existing generation comparison
detects. Two same-record payloads cannot reach the required stamp-stamp-ack ordering on one engine.

**Why.** A FIFO was proposed during adversarial review as protection against concurrent batches,
but that premise conflicts with CKSyncEngine's documented batch/event ordering. A provider callback
can still be stamped and then canceled before any sent event; the current replaceable slot heals on
the next send, while a FIFO would retain the orphaned head and misassociate later acknowledgements.
The single slot plus `AsyncSerialGate` for explicit operations is the safer invariant.

## 2026-07-15 — Cross-record repair adapters persist only their changed write set

**Decision.** Pure repair results may expose both a complete converged view and an explicit write
set. For grocery dedupe, `keepers` remains the complete survivor set for reporting and callers;
`changedKeepers` contains only survivors whose payload actually changed. `EventMergeAdapter`
persists `changedKeepers`, tombstoned losers, and repointed event links—never unchanged survivors.
The same diff-before-save invariant applies to future scheduler-driven cross-record repairs.

**Why.** TestFlight build 157 produced the same 65 `GroceryItem` identities at generations 2,
250, 251, and 252. The loop was deterministic: a completed send fired `onStoreChanged`, which
scheduled repair; dedupe returned all singleton survivors; the adapter saved all 65; that send
scheduled repair again. Full `keepers` still has legitimate semantic value, so changing it to a
write-only result would silently break callers. Splitting the two roles preserves that contract
and makes scheduler convergence explicit. A mutation-checked regression produced 57 passes in
100 ms with the old loop and exactly two with the changed-write-set path.

## 2026-07-15 — Ballast voice-parse adapter remains quarantined and default-off

**Decision.** The Ballast retrofit lives in a new local `SimmerSmithBallastAdapter` package.
`SimmerSmithKit` will never gain a dependency on the sibling Ballast repository. The adapter uses
a developer-local Ballast checkout by local path; that deliberately non-hermetic requirement
must be documented in SimmerSmith before any merge to `main`.

The supported developer layout is the normal sibling checkout:

```text
/Users/tfinklea/git/ballast/
/Users/tfinklea/git/simmersmith/
```

Feature work may instead place SimmerSmith under
`/Users/tfinklea/git/.worktrees/simmersmith-ballast-voice-parse/`. The adapter manifest resolves
Ballast from either layout; it does not vendor, copy, or add Ballast to `SimmerSmithKit`. A checkout
without the sibling Ballast repository is intentionally unsupported while the flag is private.

The CI nested checkout is the only non-sibling layout exception: CI checks out Ballast into the
workspace's `ballast/` directory at pinned commit `b4e37f891d9d3e90c71fb6f32ffbe87ca520a5be`,
authenticated by the read-only `BALLAST_DEPLOY_KEY` repository deploy key. This does not vendor or
copy Ballast into the SimmerSmith repository, and it does not change the default-OFF rollout gate.
For fork and Dependabot-authored pull requests, the reduced gate still runs both Swift package tests,
xcodegen installation, and project generation without private credentials; the private Ballast
checkout and Ballast-dependent app build/test checks run only on pushes and trusted same-repository
pull requests.

`CloudParseService` remains verbatim and is supplied as an injected application-level fallback
closure. It is neither folded into `FallbackPolicy` nor rewritten as part of this port.

`VoicePlanningCoordinator.useBallastParse` remains default OFF. `simmersmith-zyp` is the separate
rollout gate and may enable it only after the frozen live-Foundation Models golden evaluation meets
its predeclared criteria on Apple-Intelligence hardware. The `ballast-voice-parse` branch/worktree
exists specifically to protect SimmerSmith's dirty `main` checkout while this default-OFF work
proceeds.

The frozen synthetic wiring gate is:

```bash
swift test --package-path SimmerSmithBallastAdapter
swift run --package-path SimmerSmithBallastAdapter SimmerSmithBallastEval --mock
```

The separate hardware gate runs three passes per case and compares aggregate-only output with an
aggregate production-cloud baseline:

```bash
swift run --package-path SimmerSmithBallastAdapter SimmerSmithBallastEval --live --baseline <cloud-metrics.json>
```

The live command fails closed unless the baseline is supplied. The candidate and baseline must
carry distinct typed roles (`liveFMCandidate` / `productionCloudBaseline`), non-empty provider and
model identifiers, and the same frozen 60-case corpus ID, SHA-256, and three-run provenance. A
provider failure is never scored as an exact empty-plan match. These commands never enable the
flag. Eval output must not persist real user transcripts.

Literal evidence containment is necessary but not sufficient: each entry's evidence must also be
one ordered meal clause with one day/slot assignment and lexical support for its claimed dish and
intent. Support normalization is deliberately narrow (case, punctuation, whitespace, and the
frozen ASR `dinner`/`diner` variant); `at <venue>` is structural, not a generic `at` marker. Every
golden label passes the production validator. Cloud fallback runs through one cancellation-checked
boundary so the injected closure is invoked at most once even when it throws a Ballast error.

**Why.** This keeps an experimental sibling dependency and new reliability layer outside the
shipping Kit boundary, preserves the production cloud fallback's provider-compatibility behavior,
and prevents a live behavior change until hardware evidence supports the rollout.

## 2026-07-15 — Cache-first launch is staged behind exact-scope and authority gates

**Decision.** Implement e0a P2 behind a single injected gate whose shipping default stays off
until P1e and the P2 device matrix clear. A checkpoint is resumable only as one exact-scope unit:
validated records/assets, all contiguous WAL suffixes, normalized durable intents, and decoded
CloudKit state. Because `CKSyncEngine` accepts its serialization only at construction but may call
its delegate immediately, an automatic candidate starts behind a closed delegate gate; its opaque
pending state must match the recovered outbox before any callback or send can proceed. A mismatch
fails closed to exact-scope quarantine and nil-state full fetch.

Cached content is renderable but non-authoritative. Destructive/absence-based work is denied at
the data plane until reconciliation succeeds; a remote delete beats a pre-authority cached edit
without silent resurrection. Account identity is always proved by CloudKit, account boundaries
clear the whole mirror root, and verified participant revocation clears both the exact scope and
participant marker before another ready state. Offline cache display is best effort when identity
can still be proved, not a reason to persist or guess identity.

`8qy` remains a separate evidence-triggered optimization rather than a correctness dependency.
Default-on, build cutting, upload, TestFlight assignment, and installed-device confirmation remain
controller-owned release operations after automated, two-device, token-resume, crash, and launch
latency gates pass.

**Why.** Restoring only records or only a token creates complementary data-loss modes. Staging the
complete restore path preserves P1's fail-closed control while making the slow full fetch removable
from the visible launch path. The authority and lifecycle gates trade some offline capability for
cross-account privacy and prevent stale cached absence from creating, cascading, or resurrecting
CloudKit data.

## 2026-07-17 — P2c SDK probe runs in the app-target suite; State.Serialization decode is a weak gate

**Decision.** The spec §3.3 real-engine serialization probe lives in `SimmerSmithTests`
(simulator-hosted, entitled app), not the CloudKit package suite. Empirically, constructing any
`CKContainer` in the unsigned `swift test` host executes a hard `brk` trap inside CloudKit
(EXC_BREAKPOINT, uncatchable) before an engine exists — a platform constraint, not an SDK-contract
failure. The §8 "package/app matrix" already spans both suites; P2c's package verify stays
`swift test --package-path SimmerSmithCloudKit`, with the probe exercised by every app-suite run
(P2e+ verify commands), which also satisfies "rerun after any SDK/Xcode change."

Second finding: `CKSyncEngine.State.Serialization`'s `Codable` init accepts arbitrary opaque
bytes — garbage decodes without throwing. The P2c decode proof (materializer decodes the stored
bytes) is therefore necessary but nearly vacuous; the genuine local gate is P2d's post-construction
reconciliation of engine pending state against the normalized durable plan, and the genuine token
gate stays the §8 signed-device resume proof. Package-suite happy paths decode a genuine
serialization captured by the probe (fixture in `ShadowMirrorBootstrapCatalogTests`); if an SDK
update changes the format, that fixture stops decoding and surfaces the probe rerun requirement.

Probe environment pinned 2026-07-17: Xcode 26.6 (17F113), macOS 26.5.2, iOS simulator runtime
26.5 (23F77), Swift 6.3.3. Probe result: non-automatic construction, `stateUpdate` after
`state.add`, byte-identical JSON re-encode, exact pending-set reconstruction in a second engine,
and clean `state.add`/`state.remove` reconciliation all hold.

**Why.** Moving the probe to the only host that can construct CloudKit objects preserves the
spec's stop-gate semantics with real evidence instead of a vacuous or skipped package test, and
recording the decode-is-not-validation finding prevents P2d from treating a successful decode as
proof the cached engine state is usable.

## 2026-07-17 — P2d engine seam: uniform candidate quarantine, structural publication fence

**Decision.** Three calls inside spec §3.3's bounds. (1) *Any* candidate failure at the engine
construction seam — identity/marker recheck, missing `zoneEnsured`, database-state or
pending-set reconciliation — takes one uniform path: gate rejected, store cleared, generation
lease released, exact scope quarantined (moved under `quarantine/`, bytes preserved), error
rethrown for nil-state fallback. No softer "release-only" branch for identity mismatch.
(2) The bootstrap publication fence is structural, not a separate mechanism: every capture that
could publish a generation flows through a gated delegate callback (`stateUpdate`/fetch epochs),
so a closed gate *is* the fence; pinned by the app-suite gate-hold test. (3) Construction is
two-phase — gated `init(bootstrapCandidate:)` then one-shot `activateBootstrapCandidate()` —
because reconciliation must read direct engine state after the engine exists, and the externally
observable closed-gate window is also what lets a real-engine test prove the gate holds genuine
delegate callbacks (per the 2026-07-17 app-suite precedent, real-engine tests live in
`SimmerSmithTests`; the package pins the pure reconciler/gate/validation core).

**Why.** Uniform failure handling is spec-literal ("the exact scope is quarantined"), keeps the
fail-closed matrix small, and quarantine preserves evidence rather than deleting it. A separate
publication-fence flag would duplicate what the gate already guarantees and could drift from it.

**Flag for P2e/P2f.** A participant that never made a local edit checkpoints
`zoneEnsured == false` (only `save()` sets it), so its cached candidate is rejected and
quarantined at the seam on every launch — safe but wasteful (full fetch each boot, cache never
sticks). P2e/P2f should either demote such checkpoints to recovery-only at the catalog or give
participant scopes their own zone-ensured semantics before the opt-in device gate.

## 2026-07-18 — P2e cached boot stays default-off and treats durable state as authority, not convenience

**Decision.** P2e adds only an injected/testable cache-first switch; the shipping default remains
off and there is no UI or TestFlight override. An owner may render only an exact account-bound
owner/private checkpoint. A participant may render only after a typed proof records a successful
fetch of that exact shared zone; legacy Boolean `zoneEnsured` never grants participant authority
and instead yields recovery-only. Recovery-only always completes the existing nil-state P1 full
fetch before atomically overlaying the durable plan.

Every cached/recovery mutation and delivery transition must be durable before local mutation or
CloudKit handoff, including conflict rebases, sent markers, acknowledgements, failures, and remote
delete supersession. Cached sessions deny repair, dedupe, migration, absence-derived creation,
zone recreation, cleanup, and reset entry points. A generation lease pins checkpoint and WAL
asset roots through engine/batch teardown; scope/root retirement becomes durable deferred work
while any process lease remains. Account change and participant revocation increment the boot
epoch before teardown so stale async work cannot restore authority.

Cached authority is published before buffered authority callbacks drain, while legacy store,
repair, and sync-status callbacks remain immediate. `SyncStatusCenter` keeps its P1 Boolean
pending contract (`0`/`1`); only the new authority projection receives exact counts.

**Why.** P2e is allowed to improve cold-launch visibility but not to reinterpret stale absence,
lose durable intent, expose participant data without positive server proof, or weaken the exact P1
fallback. Keeping the feature default-off and making every unsafe ambiguity fail closed leaves
P2f/P2g to add broader authority/lifecycle behavior and performance evidence without turning this
test-only slice into a release control.

## 2026-07-19 — P2f lifecycle authority is session-local, crash-replayable, and account-bound

**Decision.** Data-plane authority belongs to one engine/session object and is revocable, never to
a global cached-mode Boolean. A cached session starts denied; only reconciliation for the same
epoch and exact session may promote it. The first typed lifecycle event synchronously revokes that
authority, waits for any cache mutation already inside the gate, fences later explicit-operation
results, and advances AppState through an epoch-first non-ready handoff. Deferred migrations,
repair, cleanup, and absence-derived work run as claimable session-local stages only after
promotion; interruption abandons the stage for serialized retry rather than marking it complete.

Account boundaries and factory reset clear the whole shadow root; participant revocation and
unexpected owner-zone deletion clear only the validated exact scope. Each handoff is recorded in
an integrity-bound lifecycle transaction outside that root before invalidation. A transaction is
idempotently replayed but never overwritten by different work; malformed or conflicting bytes
fail closed. Namespace invalidation is the durable boundary: the active root/scope becomes a
non-catalog retired sibling and its parent is synchronized before any successor session may enter;
recursive deletion is retryable cleanup.

An accepted participant marker must be durably stored before parking the owner or publishing a
participant. Marker failure leaves the owner untouched and keeps the join retryable; adoption
failure after that boundary retains the marker for restart recovery. Factory-reset remote deletion
is bound to the account recorded by its transaction: verify before enumeration, immediately before
mutation, and after return. Replacement boot carries the same expected account and rejects a
switch immediately after identity lookup, before participant handling, cache selection, discovery,
or mint. Completing a reset against one account can therefore never create a zone in another.

P1e's signed-device prerequisite remains open, so P2f does not add an opt-in control and the
shipping cache-first default remains off.

**Why.** A process-local flag cannot survive a crash between teardown steps, and a global authority
bit can be accidentally reused by a successor session. Persisting the exact transition before
namespace invalidation makes every suspension and restart resume toward less exposure. Binding
both destructive deletion and replacement minting to one verified CloudKit account closes the
last cross-account window after the reset transaction itself is complete.

## 2026-07-19 — P2h consumes build 162 as a crash-only production hotfix

**Decision.** Build 161 cannot close P1e: after offline grocery save/delete survived reconnect, its
foreground convergence path hit CKSyncEngine's client assertion against awaiting a delegate-
reentrant call. `RepairScheduler` now detaches only its scheduler-owned debounce task, preserving
explicit cancellation, MainActor repair isolation, and automatic synchronization. Build 162 ships
that reviewed fix with cache-first still default-off. The planned default-off opt-in vehicle moves
to build 163 and the eventual default-on release moves to build 164.

A locally signed Xcode build is not an equivalent gate: the available development provisioning
profile routes CloudKit to the development environment, and this Mac has no production-capable ad
hoc profile. Replacing the preserved TestFlight container with that build could mutate the wrong
CloudKit environment and would not prove production convergence. The hotfix therefore follows the
normal non-`[skip ci]` feature commit -> exact CI -> `[skip ci]` release commit -> TestFlight path.

**Why.** The production household state is the only faithful reproduction of the crash boundary.
Using a crash-only TestFlight vehicle preserves that state, avoids weakening the P1e gate, and keeps
the cache-first rollout serial and default-off until all original device and review requirements
pass.

## 2026-07-20 — P1e proves shadow durability; P2 owns replay

**Decision.** Build 162 closes the P1e device gate when it remains crash-free, preserves the normal
full-fetch active store, and retains every unresolved offline mutation as a valid exact-scope shadow
intent without digest mismatch or quarantine. P1 must not hydrate or re-enqueue that outbox. The
build-163 P2 opt-in gate owns replay, active-store projection, and exactly-once convergence.

The P2h execution plan previously required the default-off build 162 to drain the shadow outbox.
That contradicted the P1 specification's explicit write-only boundary. Live Roshar evidence made
the contradiction observable: the full-fetch UI remained server-rendered while both grocery save
payloads stayed intact and pending in the mirror. The gate wording is corrected rather than adding
P2 restore behavior to the crash-only hotfix path.

**Why.** Treating a durable shadow intent as lost would understate P1's evidence; treating it as
already converged would overstate user-visible recovery. Keeping the boundary explicit preserves
the validated fallback and gives build 163 one discriminating recovery test: both retained saves
must project and drain exactly once with no resurrection or quarantine.
