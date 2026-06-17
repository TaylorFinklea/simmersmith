# SimmerSmith Architectural Review

**Reviewer:** Claude Opus 4 (Pi session)  
**Date:** 2026-06-17  
**Scope:** Full-stack review — FastAPI backend, SwiftUI/iOS client, CloudKit migration, AI/provider architecture, security, operations, and testing.  
**Sources inspected:** `app/`, `SimmerSmith/`, `SimmerSmithKit/`, `SimmerSmithCloudKit/`, `.docs/ai/phases/`, `.docs/ai/roadmap.md`, `.docs/ai/current-state.md`, `.docs/ai/decisions.md`, `pyproject.toml`, `fly.toml`, `Dockerfile`, Alembic migrations, and the 2026-06-13 ultracode bug-bash architecture report.

---

## Executive Summary

SimmerSmith is a remarkably well-engineered app for its stage. The backend has a clean FastAPI structure, a mature AI assistant streaming tool loop, a thoughtfully scoped household-sharing model, and a strong test culture (48 migrations, 68 test modules, ~600 passing pytest cases). The iOS client uses modern SwiftUI patterns, a disciplined `@MainActor @Observable` AppState, and a custom SSE pipeline. The CloudKit migration is being attacked with proper spike-first rigor, and the team has already validated the riskiest algorithmic pieces (field-merge resolver, CKShare cross-account, CKAsset imagery) before provisioning the production container.

That said, the project is at an architectural inflection point. The roadmap is moving the data plane to CloudKit and the AI plane to on-device Foundation Models, while the existing FastAPI/Postgres backend is simultaneously carrying production traffic and accumulating features. The result is a codebase with **two overlapping systems of truth** (Postgres `household_id` FKs vs. CloudKit zones/shares, server-side AI vs. on-device AI) and a number of structural debts that are cheap to fix now but expensive after the migration hardens.

The highest-value improvements fall into five buckets:

1. **Data integrity:** Add real FKs for `household_id` and adopt a SQLAlchemy `naming_convention` before the next migration.
2. **AI robustness:** Detect LLM truncation, unify JSON extraction, gate assistant turns, and capture token usage.
3. **iOS state hygiene:** Centralize the displayed-week slot model and add a real auth-failure handler.
4. **CloudKit transition discipline:** Decide ownership-transfer policy now, and build a deterministic zone-creation contract.
5. **Security / ops:** Enforce MCP scopes, pin OAuth issuer discovery, add structured logging/metrics, and fix the remaining IDOR surface in the ingredient resolver.

Below is a full-stack assessment with prioritized, file-level recommendations.

---

## 1. Backend Architecture

### 1.1 What is strong

- **Clear layer separation.** Routes in `app/api/`, business logic in `app/services/`, models in `app/models/`, schemas in `app/schemas/`. The presenters pattern (`app/services/presenters.py`) keeps response shaping out of the route handlers.
- **Consistent tenancy model.** `CurrentUser` carries both `id` and `household_id`; almost every route filters by `household_id`. The MCP tools reuse the REST handlers, so there is one enforcement point per operation rather than a parallel under-guarded surface.
- **Migration discipline.** 48 Alembic migrations, nearly all with working downgrades and explicit Postgres-vs-SQLite branching where needed. Notable care: the deferred unique constraint on `week_meals` (`uq_week_day_slot`, migration 0042) and the household NOT NULL backfill (0043).
- **AI streaming architecture.** The assistant SSE path in `app/api/assistant.py` and `app/services/assistant_ai.py` is genuinely well-built: provider-agnostic adapter, client-disconnect abort via `threading.Event`, heartbeat keepalives, partial-text persistence, and tool-crash rollback.
- **Request lifecycle.** `get_session` is dependency-injected and never commits; mutating routes commit explicitly. `session_scope` provides a transactional context manager for service/tool use.

### 1.2 Structural concerns

#### 1.2.1 `household_id` has no FK on any content table

`household_id` is the documented tenancy unit, yet on `weeks`, `recipes`, `events`, `staples`, `guests`, `base_ingredients`, `household_term_aliases`, etc. it is a bare `String(36)` — indexed and NOT NULL, but with **no foreign key to `households.id`**. Only `household_members`, `household_invitations`, and `household_settings` reference `households.id`.

*Files:* `app/models/week.py`, `app/models/recipe.py`, `app/models/event.py`, `app/models/catalog.py`, `app/models/aliases.py`, `alembic/versions/20260501_0027_households.py`, `20260530_0043_household_id_not_null.py`.

**Risk:** Orphaned rows on household delete/merge; no cascade cleanup; the multi-tenant boundary relies entirely on application discipline.

**Recommendation:** Add `household_id -> households.id` FKs on all content tables in a single migration. Choose semantics deliberately:
- `ON DELETE RESTRICT` forces explicit teardown (matches current merge logic).
- `ON DELETE CASCADE` lets the DB tear down a household's content.

At minimum, `RESTRICT` makes the orphaning class of bug impossible at the schema level.

#### 1.2.2 No `naming_convention` — migrations are fragile and dual-dialect

`app/db.py` declares `Base = DeclarativeBase()` with no metadata `naming_convention`. Implicit constraint/index names therefore vary by dialect and SQLAlchemy version. The migration history shows the cost: migrations 0014 and 0031 fork into hand-written Postgres-vs-SQLite paths with full-column-list table rebuilds. Those rebuilds hardcode complete column sets, so an omitted column is silently dropped on SQLite (and the test suite, which runs on SQLite, will not catch it).

*Files:* `app/db.py`, `alembic/versions/20260410_0014_users_and_multi_tenant.py`, `20260504_0031_household_ingredients.py`.

**Recommendation:** Adopt the standard SQLAlchemy `naming_convention` on `Base.metadata` and configure `alembic/env.py` with `render_as_batch=True` for SQLite. New constraints then get deterministic names referenceable directly with `op.drop_constraint` on both dialects. Existing constraints created under implicit names will need a one-time reconciliation pass, but every future migration stops needing bespoke SQLite table rebuilds.

#### 1.2.3 Unique constraints still keyed on `user_id` instead of `household_id`

Post-M21 the sharing unit is the household, but uniqueness invariants on `Week` (`uq_weeks_user_week_start`) and `Staple` (`uq_staples_user_normalized_name`) are still scoped to `user_id`. In a multi-member household, two members can each create a Week for the same `week_start`, producing duplicate/conflicting shared rows.

*Files:* `app/models/week.py`, `app/models/profile.py`.

**Recommendation:** Migrate these constraints to `household_id`. De-duplicate existing rows first (as migration 0046 did for memberships). Preferences, dietary goals, and profile settings may legitimately stay per-user.

#### 1.2.4 Model/schema drift on `ImageGenUsage`

Migration 0026 declares `image_gen_usage.user_id -> users.id ON DELETE CASCADE` and `recipe_id -> recipes.id ON DELETE SET NULL`, but the ORM model in `app/models/image_usage.py` declares both columns as plain `String` with no `ForeignKey`. This is the only table with a `user_id -> users.id` FK; every other user-scoped table has bare `user_id`.

**Recommendation:** Make model and schema agree — either add the two `ForeignKey`s to `ImageGenUsage` or drop the lone migration FK if the bare-String convention is intentional. Separately, decide a uniform user-deletion/cleanup policy.

#### 1.2.5 Postgres-only invariants are not regression-tested

The deferred unique constraint on `week_meals` and the partial unique indexes on `base_ingredients` are Postgres-only. The test suite runs on SQLite, so the exact transaction interleaving that broke meal-swap cannot be reproduced in CI.

*Files:* `app/models/week.py`, `alembic/versions/20260522_0042_defer_week_meal_slot_unique.py`, `20260504_0031_household_ingredients.py`.

**Recommendation:** Add a lightweight dockerized-Postgres integration job for the constraints that diverge. Document in each affected model which invariants are Postgres-only so future editors do not assume SQLite parity.

---

## 2. Multi-Tenancy & Security

### 2.1 What is strong

- **Household-scoped loaders.** `get_recipe`, `get_week`, `get_event`, and friends all filter on `household_id`.
- **Catalog visibility tier.** Global `approved` vs. household-private `household_only` rows are enforced on read/mutate routes with regression tests (`test_ingredient_idor`, `test_catalog_scoping`, `test_isolation`).
- **OAuth/MCP hardening.** PKCE is mandatory (S256-only), redirect_uri allow-list rejects dangerous schemes, authorize-page HTML escapes attacker-influenced values, codes are single-use, and access tokens carry `aud="mcp"` with HS256 pinned.
- **SSRF protection.** Recipe import resolves and validates URLs against private ranges and disables/revalidates redirects.

### 2.2 Remaining gaps

#### 2.2.1 Ingredient resolver bypasses the visibility tier

`resolve_ingredient` in `app/services/ingredient_catalog/__init__.py` is the shared chokepoint for recipe save, import, draft application, `/api/ingredients/resolve`, and MCP tools. It resolves base/variation rows with **no household visibility filter**: explicit IDs are loaded via `session.get()` and only checked for `active`/`not_archived`; name lookups run bare `WHERE normalized_name = X`. Because partial unique indexes allow multiple private rows for the same normalized name, the resolver can return another household's private ingredient and persist its ID on the caller's recipe/grocery rows.

*Files:* `app/services/ingredient_catalog/__init__.py`, `app/services/ingredient_catalog/shared.py`.

**Risk:** Cross-tenant private-catalog read and foreign-id link; fragments the tier model.

**Recommendation:** Push the visibility rule into the resolver. Thread `household_id` into `_active_base_by_normalized_name` and the variation-by-name query; reject rows where `submission_status != 'approved'` and `household_id != caller`. Treat `household_id=None` as approved-only (seed/system path). Add a regression test where household A creates a private base with a unique name and household B resolving that name gets a fresh B-private row, never A's ID or name.

#### 2.2.2 No structural backstop for household scoping

Every query must remember to add `.where(Model.household_id == current_user.household_id)`. There is no Postgres RLS or scoped-session guard. The resolver gap above is exactly the kind of bug this produces.

**Recommendation:** Add a defense-in-depth layer sized to appetite:
- Cheapest: a SQLAlchemy event or CI lint that flags `session.get(<HouseholdScopedModel>, ...)` and bare selects on household-scoped tables outside approved loader helpers.
- Stronger: Postgres RLS policies keyed on a per-request `SET app.household_id`, set in `get_session` from `CurrentUser`.

#### 2.2.3 MCP scopes are declared but not enforced

The OAuth/MCP stack advertises `scopes_supported=["mcp"]`, the JWT carries a `scope` claim, but `AuthSettings.required_scopes=[]` and no MCP tool checks scopes. Any bearer can call every tool, including destructive ones (`recipes_delete`) and paid AI turns (`assistant_respond`).

*Files:* `app/mcp/__init__.py`, `app/mcp/auth.py`, `app/mcp/*.py`.

**Recommendation:** Decide whether scopes are real. If yes, define a small vocabulary (`mcp:read`, `mcp:write`, `mcp:ai`), set `required_scopes`, and add per-tool scope guards. If no, delete the scope plumbing so the surface does not imply an authorization model it lacks.

#### 2.2.4 OAuth discovery has two sources of truth

The app's own handlers in `app/api/oauth.py` derive issuer/endpoint URLs from request headers (`_public_base_url`). The MCP SDK side in `app/mcp/__init__.py` hardcodes `issuer_url` to `https://simmersmith.fly.dev` via `getattr(settings, 'oauth_issuer', '')`, but `oauth_issuer` is not a defined `Settings` field. The two protected-resource metadata responses also disagree on `scopes_supported`.

*Files:* `app/api/oauth.py`, `app/mcp/__init__.py`.

**Risk:** On any deployment whose public origin is not `simmersmith.fly.dev` (custom domain, staging, branch deploy), the 401 WWW-Authenticate challenge points clients at the wrong host.

**Recommendation:** Collapse to one issuer source. Make the issuer request-derived (or add a real `OAUTH_ISSUER` config) and pass the same value into `AuthSettings.issuer_url` and `resource_server_url`. Reconcile `scopes_supported`. Fail fast on boot if the configured issuer does not match the deployment origin.

#### 2.2.5 Authorization code is pre-minted and reused across three trust phases

The `code` in `OAuthAuthorizeRequest` is minted at `/authorize` before authentication, then reused as the hidden form field, the SSO carrier, and the literal OAuth authorization code returned to the client. Approval is modeled as setting `user_id` on the same row rather than minting a fresh post-auth code.

*Files:* `app/services/oauth.py`, `app/api/oauth.py`.

**Risk:** The grant-bearing secret is exposed in HTML/redirect URLs before authentication. PKCE contains the blast radius, but the design couples three trust phases to one mutable artifact.

**Recommendation:** Separate the pending-request identifier from the issued authorization code. Keep the pre-auth row keyed by an internal ID for the approval/SSO round-trip, and mint a fresh short-TTL authorization code at approval time.

#### 2.2.6 No GC for pending OAuth requests, no revocation for 30-day tokens

Pending `OAuthAuthorizeRequest` rows accumulate forever unless exchanged. Access tokens are stateless 30-day JWTs with no `jti`, no server-side record, and no `OAuthClient.revoked` check at verify time.

*Files:* `app/models/oauth.py`, `app/services/oauth.py`.

**Recommendation:** Add a periodic/opportunistic sweep deleting expired pending rows and a per-client pending-row cap. For revocation, add `jti` + a small revocation table, or at minimum check an `OAuthClient.revoked` flag and a per-user token-epoch.

#### 2.2.7 Public metadata trusts unauthenticated `X-Forwarded-*` headers

`_public_base_url` trusts `X-Forwarded-Proto` / `X-Forwarded-Host` with no allow-list. This determines issuer, endpoints, SSO callback URL, and deny redirects.

*Files:* `app/api/oauth.py`.

**Recommendation:** Add Starlette `TrustedHostMiddleware` or an explicit allow-list in `_public_base_url`. Derive security-sensitive URLs from a configured canonical origin rather than request headers.

---

## 3. Concurrency & Transactions

### 3.1 What is strong

- **Invite-claim serialization** uses `with_for_update`.
- **Usage counter** uses dialect-dispatched `INSERT ... ON CONFLICT DO UPDATE ... RETURNING`.
- **First-sign-in / solo-household creation** has explicit `IntegrityError` recovery.
- **Commit ownership** is consistent: `get_session` never commits; routes commit explicitly.

### 3.2 Concerns

#### 3.2.1 Subscription upsert is non-atomic

`upsert_subscription_from_transaction` in `app/services/subscriptions.py` does SELECT-by-original-transaction-id, SELECT-by-user-id, then INSERT or mutate-in-place, with no `with_for_update` and no `IntegrityError` recovery. The table has two unique constraints (`user_id` PK, `apple_original_transaction_id` unique). Concurrent verify requests can both SELECT None and both INSERT, producing an unhandled 500 on the purchase-confirmation path.

*Files:* `app/services/subscriptions.py:182-237`, `app/api/subscriptions.py:70-100`, `app/models/billing.py:12-27`.

**Recommendation:** Wrap in `try/except IntegrityError` and re-read the surviving row, or convert to `INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING` as the usage counter does. Add a concurrent-verify regression test.

#### 3.2.2 `create_solo_household` rollback can revert caller work

`create_solo_household` recovers from `IntegrityError` with a bare `session.rollback()`, which rolls back the **entire** transaction. `remove_member` first deletes+flushes the member row, then calls `create_solo_household`. If the solo insert races, the inner rollback discards the outer deletion, and the route returns 204 without removing the member.

*Files:* `app/services/households.py:131-140`, `app/services/households.py:472-503`, `app/api/household.py:286`.

**Recommendation:** Use a savepoint (`session.begin_nested()`) around the solo-household insert so only that insert unwinds. Add a concurrency test for remove-member + concurrent sign-in.

#### 3.2.3 MCP wraps REST handlers that self-commit

MCP tools open `session_scope()` (auto-commit) and then invoke route handlers that call `session.commit()` internally. The outer rollback guarantee is therefore illusory for MCP calls, and some handlers open their own nested `session_scope()` (e.g., events re-fetch), creating a nested-scope hazard.

*Files:* `app/mcp/weeks.py`, `app/mcp/recipes.py`, `app/mcp/ingredients.py`, `app/mcp/profile.py`, `app/api/events.py:141-151`.

**Recommendation:** Document and enforce one rule: handlers reused by MCP must be flush-only, or MCP must not re-wrap handlers that self-commit. Split truly-shared logic into flush-only service functions.

#### 3.2.4 Entitlement gate is check-then-act

`ensure_action_allowed` reads the counter before the AI call; `increment_usage` increments after. The window between them is wide because the AI call sits inside it. Concurrent gated requests can all read `used < limit` and all proceed.

*Files:* `app/services/entitlements.py:165-189`, `app/services/entitlements.py:192-248`, `app/api/weeks.py:164+207`, `app/services/assistant_tools.py:862+901`.

**Recommendation:** Accept as documented unless abuse is observed. If closing it, use `ON CONFLICT DO UPDATE ... WHERE count < :limit` before the expensive work, or serialize gated endpoints per user.

---

## 4. AI / LLM Integration

### 4.1 What is strong

- **Provider abstraction.** Direct providers plus MCP, with per-turn `ProviderAdapter` (OpenAI + Anthropic) and a clean normalized stream event model.
- **Streaming tool loop.** Handles client disconnect abort, partial-text persistence, heartbeat keepalives, and provider-error wrapping.
- **Draft-first flow.** Mutating tools route through validated Pydantic payloads; AI-generated content is not silently persisted.
- **Tool rollback.** `run_tool` rolls back on failure so a tool crash does not leave the week partially mutated.

### 4.2 Concerns

#### 4.2.1 Output truncation is never detected

The streaming adapters only check `finish_reason == "stop"` or `stop_reason == "end_turn"`. Truncation signals (`length`, `max_tokens`) fall into the non-terminal branch and are treated as completed answers. Non-streaming paths (week planner, recipe search, event AI) parse JSON without inspecting stop reason at all.

*Files:* `app/services/assistant_ai.py`, `app/services/week_planner.py`, `app/services/recipe_search_ai.py`, `app/services/event_ai.py`.

**Risk:** Users silently receive half-finished plans or sentences, persisted as `status=completed`.

**Recommendation:** Thread the terminal *reason* through `NormalizedStreamEvent.turn_done`. On truncation with no pending tool calls, either auto-continue or surface an explicit truncated state. For non-streaming providers, inspect stop reason before parsing and raise a distinct retryable error.

#### 4.2.2 Conversational assistant has no entitlement gating or token metering

`respond_route` does not call `ensure_action_allowed`. Read tools have no `gated_action`, so a free-tier user can run unlimited conversational turns — including mutating week tools — without incrementing any counter. No module captures token usage; `AIRun` has no input/output token or cost columns.

*Files:* `app/api/assistant.py`, `app/services/assistant_ai.py`, `app/services/assistant_tools.py`, `app/models/ai.py`.

**Risk:** Unbounded paid LLM spend per free-tier user; no cost attribution.

**Recommendation:** Add a turn-level gated action (`ACTION_ASSISTANT_TURN`) checked in `respond_route`. Add `input_tokens`/`output_tokens` (and optionally estimated cost) columns to `AIRun` and populate them from provider `usage` objects.

#### 4.2.3 Prompt injection surface

User text, conversation history, profile settings, preference signals, recipe names/notes, guest allergies, and attached recipe JSON are interpolated directly into prompts with no delimiting or instruction-hierarchy hardening. The model has mutating tools with `tool_choice=auto`.

*Files:* `app/services/assistant_ai.py`, `app/services/week_planner.py`, `app/services/event_ai.py`, `app/services/substitution_ai.py`, `app/api/assistant.py`.

**Risk:** A crafted stored value can steer the model to call mutating tools unintended by the user. Damage is self-scoped (tools resolve via `CurrentUser.household_id`), but within a shared household one member's data can manipulate another's planning turn.

**Recommendation:** Wrap untrusted content in explicit data fences with a standing instruction that fenced content is data, never commands. Keep allergy/avoid enforcement defense-in-depth server-side. Consider explicit client confirmation for destructive tools (`generate_week_plan`, `remove_meal`, `set_dietary_goal`).

#### 4.2.4 Divergent JSON extractors and duplicated parse boilerplate

`extract_json_object` (used by ~8 modules) does first-`{`-to-last-`}` substring extraction, breaking on two JSON objects and ignoring markdown fences. `week_planner._extract_json` strips fences but does not do brace extraction. The same `json.loads` → `model_validate` → `RuntimeError` block is copy-pasted into ~9 modules.

*Files:* `app/services/assistant_ai.py`, `app/services/week_planner.py`, `app/services/recipe_search_ai.py`, `app/services/event_ai.py`, `app/services/substitution_ai.py`, `app/services/vision_ai.py`, `app/services/recipe_difficulty_ai.py`, `app/services/pairing_ai.py`, `app/services/seasonal_ai.py`, `app/services/recipe_drafting.py`.

**Recommendation:** Consolidate to one hardened parse helper — strip fences, find the first balanced top-level JSON object, then `json.loads` + `model_validate` — and have every AI module call it. Fold `recipe_drafting`'s retry-on-failure into the shared helper.

#### 4.2.5 MCP and incremental generate bypass the abort/streaming contract

The MCP branch calls `asyncio.run(run_codex_mcp(...))` synchronously in the worker thread, ignoring `abort_event`. The incremental `generate_week_plan` emits `week.updated` events for placeholder meals before `apply_ai_draft` succeeds; if the latter fails, the client has already rendered partial state.

*Files:* `app/services/assistant_ai.py`, `app/services/mcp_client.py`, `app/services/assistant_tools.py`, `app/api/assistant.py`.

**Recommendation:** Tie MCP execution to `abort_event`. For incremental generate, either emit a distinct provisional `week.generating` event or defer `week.updated` until after `apply_ai_draft` commits.

---

## 5. API Contract Consistency

### 5.1 Strengths

- All datetimes are timezone-aware UTC.
- No response uses `exclude_none`, so the iOS decoder always sees explicit nulls.
- Dict-returning presenters + `response_model` provide output validation.

### 5.2 Concerns

#### 5.2.1 Same AI failure class maps to both 422 and 502

`RuntimeError` from AI services maps to 422 in `weeks.py` (generate/rebalance) and 502 in `recipes.py` / `events.py` for the same semantic failure.

*Files:* `app/api/weeks.py:181,386,482`, `app/api/recipes.py:439,614,712`, `app/api/events.py:390,425`.

**Recommendation:** Define typed exceptions (`AIProviderError`, `InvalidRequestError`) and a single mapping handler. Reserve 422 for caller-input problems; use 502/503 for provider/upstream failures.

#### 5.2.2 `source_meals` has two wire shapes

`GroceryItemOut.source_meals` is `str`; `EventGroceryItemOut.source_meals` is `list[str]`. The DB column is written as `'; '.join(...)`, `json.dumps(...)`, or the literal marker `'event:<name>'` depending on producer.

*Files:* `app/schemas/week.py:200`, `app/schemas/event.py:105`, `app/services/presenters.py`, `app/services/event_presenters.py`, `app/services/event_grocery.py`.

**Recommendation:** Normalize to `list[str]` at the presenter boundary for both surfaces, or store it structured (JSON column / separate join). Converge the two grocery-item schemas onto a shared base.

#### 5.2.3 State-machine fields are inconsistently typed

`resolution_status`, `export` status, `choice_mode`, and `submission_status` use `Literal`, but `week.status` and `event.status` are bare `str` on both request and response models. `EventUpdateRequest.status` accepts any arbitrary string.

*Files:* `app/schemas/week.py:303`, `app/schemas/event.py:127/138`.

**Recommendation:** Define each lifecycle enum once and use it on both input and output. Validate `EventUpdateRequest.status` against it.

#### 5.2.4 Core collection endpoints have no pagination

`/api/recipes`, `/api/assistant/threads`, and `/api/events` return unbounded arrays. The recipe list eagerly loads deep graphs and runs nutrition computation per recipe on every call.

*Files:* `app/api/recipes.py:171`, `app/api/assistant.py:102`, `app/api/events.py`.

**Recommendation:** Introduce a standard paginated envelope and apply it to unbounded lists now, even if only with generous defaults. This avoids a later breaking response-shape change.

#### 5.2.5 POSTs return 200 instead of 201

Only OAuth `/register` returns 201. Resource-creating POSTs return 200. `generate_side_recipe_route` returns a bare dict with no `response_model`.

*Files:* `app/api/weeks.py:118,267,576,605`, `app/api/recipes.py:231`, `app/api/assistant.py:110`, `app/api/oauth.py:128`, `app/api/weeks.py:355`.

**Recommendation:** Adopt 201 consistently for resource creation. Add `response_model=RecipePayload` (or the appropriate draft model) to the side-recipe draft route.

---

## 6. Error Handling & Observability

### 6.1 Recent improvements

The 2026-06-13 session added `configure_logging()`, global exception handlers for `OperationalError` (503 + Retry-After) and unhandled exceptions, a deep `/api/health/ready`, and `AIProviderError` wrapping. This closed the most acute gap.

*Files:* `app/main.py`, `app/config.py`.

### 6.2 Remaining gaps

#### 6.2.1 Logging is basic and not structured

Logs are plain text to stdout. There is no correlation ID, no JSON formatting, and no error-rate sink. The request log middleware uses `print()` by design.

**Recommendation:** Move to structured JSON logging with a per-request correlation ID propagated to iOS. Add an error sink (e.g., Sentry-compatible endpoint or Fly error aggregation) and include the correlation ID in every exception log.

#### 6.2.2 Raw exception strings still leak into responses

~30 route sites use `HTTPException(detail=str(exc))`. Provider `RuntimeError` messages embed upstream URLs and truncated bodies, which flow into iOS-visible `assistant.error` SSE detail and persisted assistant messages.

*Files:* `app/api/assistant.py:508,518-519,545`, `app/services/recipe_image_ai.py:203/205/242`, `app/services/recipe_search_ai.py:203`, `app/services/assistant_ai.py:966`.

**Recommendation:** Use standardized user-facing messages; log full exceptions server-side only. Never place `str(exc)` in client-facing detail or SSE error payloads.

#### 6.2.3 No metrics

There are no request latency, AI provider, or cost metrics. The admin portal has cost estimates but no runtime instrumentation.

**Recommendation:** Add lightweight Prometheus/OpenTelemetry-style metrics: request count/latency/status per route, AI provider call count/latency/error/truncation, token usage, and image-gen cost.

---

## 7. iOS / SwiftUI Architecture

### 7.1 What is strong

- **Modern foundation.** Single `@MainActor @Observable final class AppState` with feature extensions (`AppState+Weeks.swift`, `AppState+Assistant.swift`, etc.).
- **Token storage.** Keychain-backed, device-only/when-unlocked, with explicit iCloud-sync exclusion.
- **Custom SSE delegate.** Avoids `URLSession` HTTP/2 buffering and handles streaming events correctly.
- **Optimistic-update rollback.** Grocery check toggle rolls back on failure.

### 7.2 Concerns

#### 7.2.1 No centralized 401 / expired-token handling

`SimmerSmithAPIError.unauthorized` is produced for HTTP 401 but no caller distinguishes it. Token expiry degrades to a recurring red banner instead of routing to sign-in.

*Files:* `SimmerSmithKit/API/SimmerSmithAPIClient.swift`, `SimmerSmith/SimmerSmith/App/AppState.swift`.

**Recommendation:** Add a single `handleAuthFailure()` chokepoint that clears the token and drops the user to the sign-in screen whenever a 401 surfaces anywhere (REST, SSE, background refresh).

#### 7.2.2 `syncPhase` and `lastErrorMessage` are globally shared with no in-flight guard

Multiple refresh paths and leaf mutations all write the same `syncPhase` and `lastErrorMessage`. A failing background refresh can stamp `.failed` over a successful user-initiated save.

*Files:* `SimmerSmith/SimmerSmith/App/AppState.swift`, `SimmerSmith/SimmerSmith/App/AppState+Weeks.swift`, `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift`, `SimmerSmith/SimmerSmith/App/SimmerSmithApp.swift`.

**Recommendation:** Make `syncPhase` owned by a single refresh task. Add `private var refreshTask: Task?` that `refreshAll`/`refreshWeek` reuse-or-coalesce. Stop having leaf mutations set `syncPhase = .synced`. Scope errors per-domain (as the assistant already does with `assistantErrorByThreadID`).

#### 7.2.3 Displayed-week slot model is split across View @State and AppState

`WeekView` uses local `@State displayedWeekStart` plus `appState.browsedWeek`; `displayedWeek` falls back to `appState.currentWeek` when `browsedWeek` is nil. Mutations manually re-route into `browsedWeek` at ~12 sites.

*Files:* `SimmerSmith/SimmerSmith/Features/Week/WeekView.swift`, `SimmerSmith/SimmerSmith/App/AppState.swift`.

**Risk:** Between setting `displayedWeekStart` and the async fetch completing (or failing), the UI renders the wrong week and mutations target `currentWeek.id`.

**Recommendation:** Hoist `displayedWeekStart` into AppState alongside `browsedWeek` and expose a single `displayedWeek` accessor + `applyWeekUpdate(_:)` that routes by `weekId`. Remove the 12 hand-rolled reassignments.

#### 7.2.4 Full-tab Assistant send has no cancellable task

`AIAssistantCoordinator` retains `sendTask` and cancels on sheet disappear, but `AssistantThreadView` fires sends as bare `Task { await sendMessage() }` with no retention or `onDisappear` cancellation.

*Files:* `SimmerSmith/SimmerSmith/Features/Assistant/AssistantView.swift`, `SimmerSmith/SimmerSmith/Features/AIAssistant/AIAssistantCoordinator.swift`.

**Recommendation:** Retain the full-tab send task and cancel it on `.onDisappear`, or route both surfaces through the coordinator's retained-task pattern.

#### 7.2.5 SwiftData/CloudKit coexistence is unproven at app-target scale

The CloudKit migration plans to run `NSPersistentCloudKitContainer` for plain CRUD and a custom `CKSyncEngine` stack for the household zone in the same container. Phase 0.5 proved coexistence in a debug harness, but the app target has not yet integrated both stores alongside the existing local SwiftData cache (`SimmerSmithCacheStore`).

*Files:* `SimmerSmithKit/Sources/SimmerSmithKit/Persistence/PrivatePlaneContainer.swift`, `SimmerSmithKit/Sources/SimmerSmithKit/Persistence/SimmerSmithCacheStore.swift`, `SimmerSmithCloudKit/Sources/CoexistenceSpike/CoexistenceSpike.swift`.

**Recommendation:** Before provisioning the production container, integrate the private-plane store into the app target behind a feature flag and run a multi-day simulator dogfood. The risk is not the individual pieces but the interaction between three stores (local cache, private CloudKit plane, household CKSyncEngine zone).

---

## 8. CloudKit Migration Strategy

### 8.1 What is strong

- **Spike-first approach.** Spike 1 validated the grocery-merge algorithm deterministically; Spike 2 built the quality-rubric harness. Phase 0–5 of SP-A have been built and verified live on simulator.
- **Clear sync boundary.** Sticky-merge data rides `CKSyncEngine` + custom `RecordMerger`; plain CRUD rides `NSPersistentCloudKitContainer`.
- **Typed record manifest.** `HouseholdRecordType` in `SimmerSmithCloudKit/Sources/HouseholdRecords/` is the single source of truth for record names, field types, and the cascade graph, driving both the CKRecord codec and the CKDSL generator.
- **Field-merge resolver.** `GroceryMerge/FieldMergeResolver.swift` + `ConflictRepair.swift` port the server logic faithfully and have been adversarially reviewed.
- **Cross-account CKShare validated.** Owner on one iCloud account, participant on another, reading shared data successfully.

### 8.2 Concerns

#### 8.2.1 Ownership transfer has no CloudKit primitive

The spec acknowledges that zone owners are immutable and that "transfer" means recreating the zone under a new owner + re-sharing + re-migrating, or pinning hosting to the original owner forever.

*File:* `.docs/ai/phases/cloudkit-sp-a-spec.md` §2.2 / §11.

**Recommendation:** Decide this before Phase 2 ships. If transfer is required, design the migration receipt and re-share UX now; if not, document the limitation explicitly and remove the transfer-owner REST endpoints from the CloudKit-era surface.

#### 8.2.2 Zone-creation race on owner's second device

The spec calls for a "deterministic discover-then-claim" with a deterministic zone name, but this is a non-trivial contract. Two devices launching before the first zone propagates can mint separate households.

*File:* `.docs/ai/phases/cloudkit-sp-a-spec.md` §2.2.

**Recommendation:** Implement and test the zone-creation race explicitly. Use `CKFetchRecordZonesOperation` to discover existing zones before creating, and use a well-known zone name derived from stable identity (e.g., a migrated household UUID stored in keychain, or a fixed per-account name). Add a simulator test that launches two sims against the same iCloud account and asserts convergence.

#### 8.2.3 `NSPCKC` auto-generated `CD_*` schema vs. hand-authored CKDSL

The private plane uses `NSPersistentCloudKitContainer`, which generates its own `CD_*` record types. The shared household zone uses hand-authored CKDSL types. Both coexist additively, but the Phase 7 migration target must map between them.

*Files:* `.docs/ai/phases/cloudkit-sp-a-phase1-spec.md`, `SimmerSmithKit/Sources/SimmerSmithKit/Persistence/PrivatePlaneModels.swift`.

**Recommendation:** Maintain an explicit one-to-one field mapping document for Phase 7 now, while the models are fresh. Do not let the mapping become an afterthought.

#### 8.2.4 Public catalog curator is unspecified

SP-A Phase 6 (public catalog read) and SP-E (curator infra) are mostly unspecified. The global approved-tier catalog must be seedable and updatable without an app release.

*Files:* `.docs/ai/phases/cloudkit-sp-a-spec.md` §6, §8.

**Recommendation:** Decide whether the curator is a CLI, a web admin tool, or an app-side privileged user. Build the smallest version that can update the PUBLIC db before Phase 6 lands.

#### 8.2.5 AI seam is stubbed

`AIProviderKit` has real backends stubbed for SP-B. The actual provider routing (on-device AFM 3 vs. BYO-key cloud vs. credits gateway) is not yet implemented.

*Files:* `SimmerSmithCloudKit/Sources/AIProviderKit/`.

**Recommendation:** Finalize the provider-selection policy and the key-storage contract (`KeyStore.swift`) before iOS 27 GA. The spike harness already exists; the main risk is integration with SwiftUI and CloudKit privacy guarantees.

---

## 9. Testing

### 9.1 What is strong

- **Large regression suite.** ~600 pytest cases, including dedicated IDOR, household-scoping, catalog-scoping, OAuth, MCP, push, event-grocery, and error-handling test modules.
- **Adversarial workflows.** Recent bug-bash fixes were validated by multi-model head-to-head tests.
- **Swift package tests.** `SimmerSmithCloudKit` has headless tests for merge resolver, record codec, sync engine seams, and audit retention.

### 9.2 Concerns

#### 9.2.1 SQLite tests do not enforce the same constraints as production Postgres

As noted in §1.2.5, deferred unique checks and partial unique indexes behave differently in SQLite. The meal-swap bug that motivated migration 0042 cannot be reproduced in CI.

**Recommendation:** Add a dockerized-Postgres test job for constraint-divergent paths.

#### 9.2.2 CloudKit integration is mostly manual

Cross-account CKShare and two-device convergence are validated manually on simulators. These cannot be automated with XCTest because iCloud sign-in cannot be scripted.

**Recommendation:** Maintain a manual test playbook in `.docs/ai/phases/cloudkit-manual-test-playbook.md` with exact steps, expected outcomes, and screenshots. Treat each Phase 2/2c/4 verification as a required release gate.

#### 9.2.3 iOS UI testing is minimal

The iOS verification today is simulator launch + screenshot checks. There is no XCUITest harness for repeatable end-to-end flows.

**Recommendation:** Add a small XCUITest suite covering sign-in, week display, assistant send, and grocery check. This is especially important as the CloudKit migration changes data persistence.

---

## 10. Operations & Deployment

### 10.1 Current state

- Fly.io deployment with `shared-cpu-1x`, 512 MB RAM, single-instance preferred (`min_machines_running = 1`).
- Docker image builds from `python:3.12-slim`.
- Health checks: shallow `/api/health` and deep `/api/health/ready`.

### 10.2 Concerns

#### 10.2.1 512 MB RAM may be tight for AI workloads

A `gpt-5.5` week-generation call holds the response in memory and streams it. Concurrent AI turns plus image generation could pressure 512 MB.

*File:* `fly.toml`.

**Recommendation:** Monitor memory under load. If peak RSS approaches the limit, bump to `shared-cpu-2x` or add swap-aware limits. Consider offloading image generation to a background worker or queue.

#### 10.2.2 Single-instance assumptions

The push scheduler deduplicates via an in-memory `_sent_today` dict, documented as safe only for single-instance deployment. `auto_start_machines = true` allows scale-out.

*File:* `app/services/push_scheduler.py`.

**Recommendation:** If scaling past one machine, move push deduplication to Postgres (unique on `(kind, user_id, date_key)`) or a Postgres advisory lock.

#### 10.2.3 Build pipeline does not regenerate `.xcodeproj`

`project.yml` is the source of truth, but `release-ios.sh` regenerates `.xcodeproj/project.pbxproj` at archive time. A mismatch between committed `project.pbxproj` and `project.yml` can cause confusion.

*Files:* `SimmerSmith/project.yml`, `scripts/release-ios.sh`.

**Recommendation:** Either commit the regenerated `project.pbxproj` immediately after each `project.yml` bump, or add a CI check that fails if `xcodegen generate` produces a diff.

---

## 11. Prioritized Recommendations

### P0 — Do before the CloudKit migration hardens

1. **Add `household_id -> households.id` FKs** on all content tables (`RESTRICT` minimum). This is much easier while the household model is still young.
2. **Adopt a SQLAlchemy `naming_convention`** and `render_as_batch=True` to stop the dual-dialect migration drift.
3. **Fix `resolve_ingredient` household visibility** and audit all internal callers for missing `household_id`.
4. **Decide and document CloudKit ownership-transfer policy** before Phase 2 ships.
5. **Implement deterministic zone-creation race handling** and test it with two simulators.

### P1 — Do before flipping `trial_mode_enabled` off / App Store launch

6. **Detect LLM truncation** across streaming and non-streaming AI paths.
7. **Gate assistant turns** with `ACTION_ASSISTANT_TURN` and capture token usage in `AIRun`.
8. **Fix subscription upsert** atomicity and `create_solo_household` savepoint issue.
9. **Enforce MCP scopes** or remove the scope plumbing.
10. **Unify JSON extraction** into one hardened helper used by all AI modules.
11. **Add real 401 handling on iOS** that routes to sign-in.
12. **Centralize the displayed-week slot model** in AppState.

### P2 — Post-launch hardening

13. Add structured JSON logging with correlation IDs and an error sink.
14. Add request/AI/cost metrics.
15. Add pagination to recipes, assistant threads, and events.
16. Reconcile `source_meals` wire shape and event/week grocery schemas.
17. Standardize PATCH clearing conventions and `extra='forbid'` policy.
18. Move push deduplication off in-memory state if scaling out.
19. Add XCUITest coverage for critical iOS flows.
20. Build the public-catalog curator tool.

---

## 12. Conclusion

SimmerSmith's architecture is solid and its team is clearly capable of rigorous engineering — the CloudKit spikes, the adversarial bug bash, and the careful migration history all demonstrate that. The current risk is not that any one subsystem is badly built; it is that the project is transitioning from a server-centric Postgres app to an Apple-native CloudKit app while still shipping features. That transition creates a window where structural debt (FKs, naming conventions, scoping backstops) and AI-era concerns (truncation, metering, prompt injection) can harden into expensive legacy.

The recommendations above are aimed at closing the highest-leverage gaps **before** the CloudKit container is promoted to Production and before the paywall is activated. The P0 items are foundational; the P1 items are user-visible and monetization-critical; the P2 items are polish and scale. Tackle them in that order.
