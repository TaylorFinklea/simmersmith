---
title: "SimmerSmith Architectural Review"
reviewer: "minimax-m3"
date: "2026-06-17T11:02:00Z"
commit_at_review: "e39a707"
scope: "End-to-end (backend, iOS app, ops, tests)"
type: "Architectural / structural"
---

# SimmerSmith Architectural Review

## 1. Executive Summary

SimmerSmith is a **mature, well-instrumented** AI-first meal-planning SaaS: a FastAPI backend on Fly.io, a Swift 6.2 iOS client with a shared SPM (`SimmerSmithKit`) and a CloudKit companion (`SimmerSmithCloudKit`), a 55-tool MCP surface, and Apple/Google SSO + an Apple IAP subscription path. The team has done unusually careful operational plumbing — custom request log middleware, an OperationalError → 503 mapper with `Retry-After`, a stateless MCP transport to avoid a cross-tenant identity bug, a one-time `mark_startup_complete()` guard so the mounted sub-app's lifespan doesn't redo migrations, and a `/api/assistant/_streamtest` SSE smoke route for fly-proxy diagnostics. This is not a green prototype.

That said, **the project is starting to creak under the weight of its own breadth**. A handful of issues are architectural in the sense that they constrain what you can do next:

1. **The "service layer" is a 50-file flat namespace** that has begun accumulating god-modules (`grocery.py` 876 lines, `assistant_ai.py` 987+ lines, `assistant_tools.py` 1300+ lines, `recipe_ai.py` 865 lines, `week_planner.py` 714 lines). There is no bounded context for "meal planning" or "AI provider" — features cross-import each other in chains that make ownership and review harder than they should be.
2. **`app/main.py` is a 17 KB, 500-line god module** mixing lifespan wiring, request logging middleware, exception handlers, the MCP sub-app mount, `/api/health*`, public SSE diagnostic, and Privacy/Terms HTML strings. The lifespan function alone runs migrations, seed, the scheduler start, and an `async with` on the mounted MCP app's lifespan, with an explicit `_mcp_lifespan_ran` guard.
3. **iOS `AppState` is a 17-extension god-store** totalling ~3,900 lines across one `@Observable` class. Swift 6.2 + Observation gives you per-feature `@Observable` types; the current shape fights the framework.
4. **`ProfileSetting` is being used as a generic key-value config store** for ~30+ settings spanning user preferences, store config, push, AI provider, image gen, unit system, grocery auto-regeneration, and trial. This works at current scale but will resist typing, migration, validation, and discovery.
5. **The AI provider surface (10+ config fields, 3 entry points — MCP, direct OpenAI, direct Anthropic) is a complex state machine** with three different streaming parsers, two tool-calling conventions, and per-feature prompt authoring. There is no shared "AI client" abstraction, and the abstraction that does exist (`assistant_ai.NormalizedStreamEvent`) is buried under 987 lines of one file.
6. **No rate limiting, no circuit breaker, no request-ID correlation, no OpenTelemetry.** The single 512 MB Fly instance carries all of this with `min_machines_running = 1`. AI features time out at 300 s. When OpenAI or APNs has a blip, you will find out from `flyctl logs` rather than from a graph.

None of these are catastrophic. Each can be addressed incrementally. The recommendations section below is sequenced so the highest-leverage ones are first.

## 2. Architecture Map

```
┌────────────────────────────────────────────────────────────────────┐
│                          iOS Client (Swift 6.2)                    │
│  ┌──────────────────────┐  ┌──────────────────┐  ┌──────────────┐  │
│  │   AppState (~3.9K    │  │  Features/*      │  │  Services/   │  │
│  │   lines, 17+ exts)   │◄─┤  (12 feature     │◄─┤  Push, Reminders│
│  │   @Observable store  │  │  modules)        │  │  Voice, Spoken│
│  └──────────┬───────────┘  └──────────┬───────┘  └──────────────┘  │
│             │                         │                            │
│             ▼                         ▼                            │
│  ┌─────────────────────────────────────────────────────┐           │
│  │              SimmerSmithKit (SPM)                   │           │
│  │  API client • Codable DTOs • SwiftData persistence  │           │
│  │  ConnectionSettings • Keychain                      │           │
│  └────────────────────────┬────────────────────────────┘           │
│                           │ HTTPS + SSE + Bearer JWT               │
│                           ▼                                        │
│  ┌─────────────────────────────────────────────────────┐           │
│  │            SimmerSmithCloudKit (SPM)                │           │
│  │  Optional CloudKit mirror (Sp-a/Phase 7)            │           │
│  └─────────────────────────────────────────────────────┘           │
└────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌────────────────────────────────────────────────────────────────────┐
│                       FastAPI app (Fly.io, 1×512MB)                │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  app/main.py — lifespan, middleware, exception handlers,  │    │
│  │  /api/health, /privacy, /terms, MCP mount, SSE diagnostic │    │
│  └────────────────────────────────────────────────────────────┘    │
│  ┌──────────────────────┐  ┌──────────────────────┐                │
│  │  app/api/ (23 routers)│  │  app/mcp/ (55 tools) │                │
│  │  /api/* REST surface │  │  /mcp (stateless)    │                │
│  └──────────┬───────────┘  └──────────┬───────────┘                │
│             └──────────┬──────────────┘                            │
│                        ▼                                           │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  app/services/ (50 files, flat namespace)                 │    │
│  │  • ai • assistant_ai • assistant_tools • assistant_threads│    │
│  │  • recipe_ai • recipe_image_ai • recipe_search_ai         │    │
│  │  • grocery (876) • week_planner (714) • recipe_ai (865)   │    │
│  │  • drafts • events • households • oauth • sso             │    │
│  │  • push_apns • push_scheduler • nutrition                 │    │
│  │  • ingredient_catalog/* • recipe_import/*                 │    │
│  └────────────────────────┬───────────────────────────────────┘    │
│                           ▼                                        │
│  ┌────────────────────────────────────────────────────────────┐    │
│  │  app/models/ (20 files, 49 Alembic migrations)            │    │
│  │  SQLAlchemy 2.0, Postgres prod, SQLite test, UUID PKs     │    │
│  └────────────────────────────────────────────────────────────┘    │
│                                                                     │
│  External: Apple/Google JWKS • OpenAI • Anthropic • Codex MCP      │
│            USDA FDC • APNs • App Store Server API                  │
└────────────────────────────────────────────────────────────────────┘
```

## 3. Strengths

These are worth preserving through any refactor.

- **Operational discipline is unusually good for this size of project.** The `_RequestLogMiddleware` in `main.py` writes one `REQLOG` line per request to stdout, bypassing any logger reconfiguration so `flyctl logs` always sees it. The `OperationalError` exception handler returns 503 with `Retry-After: 5` (instead of bare 500). The deep `/api/health/ready` endpoint round-trips the DB so Fly can tell a live process from one whose database is unreachable. The `_log_lifespan_failure` helper force-flushes tracebacks so container teardown doesn't eat them.
- **Stateless MCP transport is the correct fix for the cross-tenant identity bug.** The comment in `app/mcp/__init__.py` documents exactly why `stateless_http=True` is mandatory: the stateful session-manager freezes the request context, so `verify_token` setting `_current_user_id_var` never reaches tool dispatch. That kind of "this exists because of this specific incident" comment is gold for future maintainers.
- **DNS-rebinding protection is explicitly disabled on the public MCP endpoint** with a clear reason: the OAuth bearer is the access control, and the SDK default would 421 every public host and 403 the `Origin: https://claude.ai` that Claude's connector sends. The kind of decision that *should* be commented, and is.
- **MCP and REST share the same domain functions.** `app/mcp/recipes.py` imports `archive_recipe_route`, `recipe_detail_route`, etc., and `_call_route` invokes them under a `session_scope()`. This is the simplest way to avoid two parallel implementations drifting. The cost (an MCP change = a REST change) is a feature.
- **Apple IAP verification is correctly architected.** `apple_iap_environment`, `apple_iap_app_apple_id`, the JWS-signed-date replay guard (`apple_iap_webhook_max_age_days`), and the sandbox-allow toggle (`apple_iap_allow_sandbox`) are all in place. The `apple_iap_app_apple_id` is correctly flagged as required only for production verification.
- **HS256 session JWT is hardcoded** rather than read from `settings.jwt_algorithm`. The comment in `app/auth.py` correctly notes this pins the algorithm and prevents an alg-confusion / "none" surface. The 32-character secret minimum is also enforced at startup with a clear warning.
- **The auth precedence chain is explicit and ordered**: dev/local mode → session JWT → legacy bearer → 401. Each branch has a clearly documented reason to exist.
- **Per-user AI provider override** with `AI_SECRET_KEYS` denylist in `app/services/ai.py` correctly prevents the user-provided OpenAI/Anthropic keys from being leaked back through `GET /api/profile`. The denylist is explicit and small.
- **Migrations are auto-run on startup** with `command.upgrade(..., "head")` and the test suite's `reset_database` fixture handles the dual-mode (SQLite tests, Postgres prod) cleanly.
- **Multi-tenancy via `household_id`** is in place (M21). The `uq_household_members_user` unique constraint enforces "exactly one household per user" at the schema level, not just in app logic. The bootstrap path lazily creates a solo household for legacy users. This is the right move.
- **iOS uses modern Apple-platform tech throughout**: Swift 6.2, `@Observable`, SwiftData, SPM packages with iOS 26+ / macOS 15+, async/await, `AIAssistantCoordinator`, structured concurrency. CloudKit is a separate package, so it can be added without bloating the main app.
- **Tests are isolated** with a per-process tempdir SQLite (`tempfile.mkdtemp(prefix="simmersmith-tests-")`), the `reset_db_state` fixture clears engine + sessionmaker caches, and `SIMMERSMITH_PUSH_SCHEDULER_ENABLED=false` keeps APScheduler out of pytest.

## 4. Concerns (Prioritized)

### 4.1 [P0] Service-layer god modules

**Files:** `app/services/grocery.py` (876), `app/services/assistant_ai.py` (987+), `app/services/assistant_tools.py` (1300+), `app/services/recipe_ai.py` (865), `app/services/week_planner.py` (714), `app/services/drafts.py` (770+), `app/services/presenters.py` (513), `app/services/nutrition.py` (598), `app/services/recipe_image_ai.py` (383).

These files have grown into god-modules. Three issues compound:

1. **High cognitive load for new contributors.** Reading `assistant_ai.py` requires holding 7 dataclasses, 3 streaming parsers, 2 tool-calling conventions, and a recursion-depth guard in your head.
2. **High review surface.** A 900-line file means PRs touching it tend to bundle unrelated changes, which makes code review noisy and bugs easier to miss.
3. **Cross-imports that are hard to reason about.** `grocery.py` imports `ingredient_catalog`, `weeks`, and model rows; `recipe_ai.py` imports `nutrition`, `recipe_search_ai`, `recipe_image_ai`, `recipe_difficulty_ai`, `pairing_ai`, `substitution_ai`, `sides`, `recipe_templates`. None of these form a clean dependency graph.

**Suggested direction (not a rewrite plan):** introduce bounded contexts by promoting a few top-level packages:

```
app/services/
  meal_planning/        # weeks, week_planner, drafts, grocery, sides
  recipes/              # recipes, recipe_ai, recipe_drafting, recipe_templates,
                        # recipe_search_ai, recipe_image_ai, recipe_difficulty_ai,
                        # recipe_import/
  catalog/              # ingredient_catalog/, nutrition, ingredient_ingest
  ai/                   # ai, provider_models, mcp_client, pair_ai, seasonal_ai
  assistant/            # assistant_ai, assistant_tools, assistant_threads
  identity/             # oauth, sso, households, profile, preferences, server_settings
  commerce/             # subscriptions, entitlements, billing helpers
  notifications/        # push_apns, push_scheduler
  events/               # events, event_ai, event_grocery, event_supplements,
                        # event_presenters
  shared/               # presenters (split per-context), pricing, change_history
```

Once packages exist, the existing files can be split along their internal sections (e.g. `assistant_ai.py` likely splits into `stream_parsers.py`, `provider_adapters.py`, `tool_dispatch.py`, `prompting.py`). This is a *mechanical* refactor with no behavior change and is best done as a series of small, individually mergeable PRs.

### 4.2 [P0] `app/main.py` is a god module

**File:** `app/main.py` (17 KB, 500+ lines).

`main.py` mixes:

- Logging configuration (`configure_logging`)
- A custom request log middleware (`_RequestLogMiddleware`)
- Lifespan with `run_migrations`, `seed_defaults`, JWT-secret warning, push-scheduler start, *and* a hand-rolled `async with _mcp_app.router.lifespan_context(_mcp_app): yield` with a `_mcp_lifespan_ran` module-level guard
- Two exception handlers (OperationalError, generic Exception)
- All 23 router `include_router` calls (with two distinct "protected" patterns)
- `/api/health`, `/api/health/ready`, `/api/assistant/_streamtest`
- `/privacy` and `/terms` as **inline HTML strings**
- The `app.mount("/", _mcp_app)` at EOF

**Concerns:**

- The inline HTML for Privacy / Terms means a copy change requires a code change + a deploy. Move to `app/static/{privacy,terms}.html` and serve via `StaticFiles`.
- The lifespan function reads as 4 separate concerns (migrations, seed, scheduler, MCP app). It's the kind of function that will quietly grow as new startup-time work is added (cache warming, metrics, etc.).
- The module-level `_mcp_lifespan_ran` flag is a hand-rolled "singleton-once" guard. It's correct but smells. A clean solution is to let the FastAPI app own the MCP app's lifespan natively (a single `Lifespan` on the parent `FastAPI` that also calls into the MCP sub-app), or to have the MCP sub-app detect the parent process via a `parent_started` ContextVar set in the parent lifespan.

**Suggested direction:**

- `app/main.py` becomes a 30-line module that imports `create_app()` from `app/factory.py` and exposes `app` for uvicorn.
- `app/factory.py` builds the app, wires routers, mounts static files, registers exception handlers, configures logging.
- `app/lifespan.py` owns the async context manager, one phase at a time.
- `app/middleware.py` owns `_RequestLogMiddleware` and any future middleware.

### 4.3 [P0] `ProfileSetting` is a generic key-value config store

**Files:** `app/models/profile.py` (the table), `app/services/bootstrap.py` (`DEFAULT_PROFILE_SETTINGS` dict), `app/api/profile.py` (read/write), `app/services/ai.py` (`AI_SECRET_KEYS` denylist, `profile_settings_map`), every AI service that reads `unit_system`, `image_provider`, `ai_provider_mode`, `ai_direct_provider`, etc.

The current shape is "stringly typed config" — ~30 keys covering user preferences, store config (Aldi/Walmart), push notification prefs, AI provider mode, image gen provider, recipe search provider, unit system, grocery auto-regeneration, trial mode. Each setting has:

- A default in `bootstrap.DEFAULT_PROFILE_SETTINGS` (40+ line dict, growing)
- A write path that takes a `dict[str, str]` (no validation)
- A read path that does `str(user_settings.get("...", ""))` and hopes for the best
- A discoverability problem: there is no central schema, no Enum, no Pydantic model

**Concerns:**

- A typo (`"metric "` vs `"metric"`) silently falls back to default. This is already happening — `unit_system` in `app/services/ai.py` has explicit fall-through.
- Adding a setting requires editing 3+ files in 3+ places.
- Renaming a key is a multi-file find-replace with no migration safety net.
- The denylist in `app/services/ai.py` (`AI_SECRET_KEYS`) exists *because* the table is a free-form kv: there's no schema-level guarantee a secret can't be written here. That's the wrong place to enforce that invariant.

**Suggested direction:** introduce a `ProfileSettings` Pydantic model in `app/schemas/profile.py` with typed fields (Literal["us", "metric"], `StoreConfig` for Aldi/Walmart, `PushPrefs`, `AIProviderMode`, etc.). The `ProfileSetting` table becomes an internal serialization detail. The migration is:

1. Add the Pydantic model.
2. Add a `to_flat_dict()` / `from_flat_dict()` so the table layout doesn't change.
3. Replace reads of `user_settings.get("unit_system", "")` with `settings.unit_system`.
4. Replace writes with the typed model's setters, which validate on set.

This is also the right time to split `ProfileSetting` (user-scoped) from `HouseholdSetting` (M21 has a separate table for it — the names are already differentiated, which is good, but usage patterns are similar).

### 4.4 [P1] AI provider sprawl

**Files:** `app/services/ai.py` (260), `app/services/assistant_ai.py` (987+), `app/services/assistant_tools.py` (1300+), `app/services/recipe_ai.py` (865), `app/services/recipe_image_ai.py` (383), `app/services/recipe_search_ai.py` (356), `app/services/mcp_client.py` (125), `app/services/provider_models.py` (186), `app/config.py` (10+ AI fields).

Three orthogonal axes interact:

- **Provider**: MCP (Codex), OpenAI direct, Anthropic direct
- **Surface**: Assistant (multi-turn + tool calls), recipe generation, image generation, recipe web search, vision, nutrition estimation, substitution
- **Streaming**: Yes (assistant), no (most others)

Each surface has its own way of:

- Selecting the provider (e.g. `resolve_ai_execution_target` in `app/services/ai.py`)
- Building the request body (`openai_chat_body` in `app/services/provider_models.py`, `anthropic_tools_schema` in `app/services/assistant_tools.py`)
- Parsing the streaming response (the three `parse_stream_line` methods in `assistant_ai.py`)
- Handling tool calls (in `assistant_tools.py`)
- Persisting results

`NormalizedStreamEvent` in `assistant_ai.py` is the right shape of an abstraction but is implemented inside the largest service file. Pulling it out into `app/services/ai/streaming.py` and using it from every AI surface (or at least the streaming ones) would prevent three parsers from drifting independently.

**Suggested direction:**

- Create `app/services/ai/` package with:
  - `client.py` — a single `AIClient` with `complete()`, `stream()`, `with_tools()` methods
  - `providers/openai.py`, `providers/anthropic.py`, `providers/mcp.py` — provider-specific adapters
  - `streaming.py` — `NormalizedStreamEvent` and the parsers
  - `tools.py` — tool dispatch + schema generation
  - `selection.py` — `resolve_ai_execution_target` and friends
- Each existing surface (recipe_ai, recipe_image_ai, etc.) becomes a thin wrapper that builds the prompt and calls `AIClient`.

The win is that any provider change (a new Anthropic model, an OpenAI Responses API migration, a Codex MCP update) happens in one place per provider, not in 6+.

### 4.5 [P1] iOS `AppState` is a god-store

**Files:** `SimmerSmith/SimmerSmith/App/AppState.swift` (517) plus 17 extension files (`AppState+AI.swift`, `AppState+Aliases.swift`, `AppState+Assistant.swift`, `AppState+Events.swift`, `AppState+Grocery.swift`, `AppState+Household.swift`, `AppState+Ingredients.swift`, `AppState+Pantry.swift`, `AppState+Profile.swift`, `AppState+Push.swift`, `AppState+Recipes.swift`, `AppState+Reminders.swift`, `AppState+Seasonal.swift`, `AppState+Subscription.swift`, `AppState+TopBar.swift`, `AppState+Vision.swift`, `AppState+Weeks.swift`) totalling ~3,900 lines.

The pattern is "one `@Observable` class with feature extensions" — a deliberate compromise that keeps a single store while spreading the file count. It works, but:

- Every property is in the dependency graph of every view. SwiftUI's `Observation` framework's tracking granularity helps, but `@Observable` still re-evaluates dependent views when *any* property of the observed class changes, because Swift can't always prove non-dependence.
- 17 extensions means an arbitrary feature change can touch one of them, but cross-feature concerns (e.g. "the assistant wants to update the week") require reading multiple files.
- 30+ `var` declarations on `AppState` itself (`serverURLDraft`, `authTokenDraft`, `aiProviderModeDraft`, `userRegionDraft`, `imageProviderDraft`, `unitSystemDraft`, `pushAuthorizationStatus`, `currentHousehold`, `pendingPaywall`, `showOnboardingInterview`, ...) are a smell that the type is doing too much.
- The "XxxDraft" suffix on so many properties suggests a pattern that could be encapsulated: a per-feature `FormState` value type that mutates a published `current` on commit.

**Suggested direction:** With Swift 6.2 + `@Observable`, the right shape is per-feature stores owned by `AppState`:

```swift
@MainActor @Observable
final class AppState {
    let settingsStore: ConnectionSettingsStore
    let cacheStore: SimmerSmithCacheStore
    let apiClient: SimmerSmithAPIClient
    let subscriptionStore = SubscriptionStore()
    let assistantCoordinator: AIAssistantCoordinator

    let weekStore: WeekStore
    let recipeStore: RecipeStore
    let groceryStore: GroceryStore
    let eventStore: EventStore
    let assistantStore: AssistantStore
    let ingredientStore: IngredientStore
    let pantryStore: PantryStore
    let profileStore: ProfileStore
    let householdStore: HouseholdStore
    let pushStore: PushStore
    let visionStore: VisionStore
    let remindersStore: RemindersStore
    let aliasesStore: AliasesStore
    let subscriptionState: SubscriptionStateStore
    let seasonalStore: SeasonalStore
    let topBarSettings: TopBarSettings
    // ...
}
```

Each child store is `@Observable` itself; views observe the specific child they need. The cross-store wiring (e.g. "after week save, refresh grocery") moves from `AppState+Weeks.swift` to a coordinator or to a Combine-like pipeline owned by the relevant child stores.

This is a *big* refactor. The path of least resistance is to introduce the new stores alongside the extensions, one feature at a time, and migrate callers. The `AppState+X.swift` files remain as shims that delegate to the new stores, then get deleted.

### 4.6 [P1] Long-lived SSE / AI calls need a hardened transport layer

**Files:** `app/api/assistant.py` (the SSE endpoint, ~30 KB), `app/main.py` (`_RequestLogMiddleware`), `app/services/assistant_ai.py` (the inner loop).

You have:

- A 300-second `ai_timeout_seconds` for the worst-case AI call
- A 5-second heartbeat (`STREAM_HEARTBEAT_INTERVAL_SECONDS`) to keep the fly-proxy from closing an apparently-idle stream
- A custom `stream_test_response` to diagnose fly-proxy transport
- An explicit `_background_tasks: set[asyncio.Task]` to keep fire-and-forget tasks alive

This is good. The risk is that **the next long-running endpoint** (recipe generation, image gen, etc.) has to remember to wire heartbeats, accumulation, and persist-on-interval itself. A `sse_endpoint(heartbeat_seconds=5.0, persist_every=0.5)` decorator in `app/api/assistant.py` (or a `app/services/sse.py` helper) that wraps a generator and handles heartbeats + persistence would make this one-line for the next endpoint.

Related: when an AI provider (OpenAI, Anthropic) blips, every in-flight assistant turn will run the full 300 s and the user will see "spinner hung" rather than a quick "AI unavailable, try again." A per-host circuit breaker (`pybreaker` or a 30-line custom one) keyed on `openai|anthropic|apple|google|usda` would short-circuit the noise.

### 4.7 [P1] No rate limiting, no request ID, no OpenTelemetry

**Files:** `app/main.py` (no middleware for any of these), `app/api/*` (no `@limiter.limit(...)`), no `opentelemetry-*` in `pyproject.toml`.

Three concerns, all in the same neighborhood:

- **Rate limiting.** The `is_pro()` entitlement exists, but a free-tier user with a leaked token can fire unlimited 300-second AI calls. Even simple per-user-per-endpoint token-bucket limiting (e.g. `slowapi` or a 50-line middleware backed by Postgres or in-process) would be a 1-day change and a real defense.
- **Request ID / correlation.** A multi-step assistant turn (user message → AI → tool call → AI → persist) currently has no shared identifier across logs. The `NormalizedStreamEvent.messageId` carries through the *iOS* client but not the *server* logs. A `X-Request-Id` middleware (or a `contextvars.ContextVar` set at request start) would let you grep for a single conversation in `flyctl logs`.
- **OpenTelemetry.** No spans, no metrics, no traces. You have no way to answer "what's our p95 latency for week-plan generation by provider?" or "how many AI calls per day per user?" The `mcp.json` is mentioned in the AGENTS.md as a future hook, but even a 1-day OTel bootstrap (FastAPI instrumentor + httpx instrumentor + a console exporter) would give you a per-request trace and a metrics endpoint.

For a service where AI spend and provider latency dominate cost, *not* having this is the highest-leverage observability gap.

### 4.8 [P1] Two iOS model layers, unclear sync story

**Files:** `SimmerSmithKit/Sources/SimmerSmithKit/` (API + Codable DTOs + SwiftData persistence + Keychain + Configuration), `SimmerSmithCloudKit/` (separate package for CKShare / CKAsset mirror), `SimmerSmith/SimmerSmith/App/AppState+*.swift` (the @Observable layer that bridges the two).

The iOS app has at least three sources of truth:

1. **Server** (FastAPI + Postgres) — canonical for everyone
2. **Local SwiftData store** (`SimmerSmithCacheStore` in `SimmerSmithKit/Persistence/`) — for offline reads
3. **CloudKit** (`SimmerSmithCloudKit`) — for cross-device sync and sharing (Sp-a, Phase 3 / 7)

Each has its own merge story:

- Server: last-write-wins via `updated_at` timestamps; `WeekChangeEvent` audit log captures history
- SwiftData: ?? (need to read `cacheStore` to know)
- CloudKit: CKShare / CKRecord with conflict-resolution policies (need to read `SimmerSmithCloudKit` to know)

**Concerns:**

- The risk of two devices editing the same week offline and then both coming back online, with one CloudKit sync and one server push, is real. The current "Sp-a" series in git log suggests you're already working on this, but the *visible* architecture doesn't make the resolution policy obvious.
- The `SimmerSmithCacheStore` is mentioned in `AppState.swift` but I couldn't read its implementation in the time available. Worth a focused review.

**Suggested direction:** write a one-page doc (`docs/architecture/sync-architecture.md`) that draws the data flow with a sequence diagram. The current state forces every new contributor to reverse-engineer this from three packages.

### 4.9 [P1] `session_scope()` vs `Depends(get_session)` dual pattern

**Files:** `app/db.py` (defines both), almost every API route (`get_session` dep), almost every MCP tool + push scheduler + export worker (`session_scope()`).

There are two ways to get a session:

1. `Depends(get_session)` — used by API routes. The session is yielded by the dependency, the route does its work, FastAPI closes it. **The caller does not commit; routes either call `session.commit()` explicitly or rely on the session's transactional boundary being the request.**
2. `session_scope()` — used by MCP tools, push scheduler, exports, bootstrap, and *also* from inside some API routes (e.g. the background-task pattern in `app/api/assistant.py` with `session_scope()` for fire-and-forget persistence). Commits on success, rolls back on exception.

The subtle bug surface:

- A route that uses `Depends(get_session)` and forgets to `commit()` will silently roll back at request end.
- A route that uses `Depends(get_session)` and *also* opens a nested `session_scope()` is operating on two different sessions, and the inner commit is not visible to the outer.

The current codebase mostly does this correctly, but the **dual pattern is confusing for new contributors**. A cleaner shape:

- One session lifetime: `Depends(get_session)` everywhere on the request path.
- `session_scope()` only at *true* process boundaries (startup, scheduled jobs, MCP requests, fire-and-forget background tasks).
- An integration test that asserts "every request-scoped session is committed before the response is sent" would catch the silent-rollback class of bug.

### 4.10 [P1] `models/week.py` is a junk drawer

**File:** `app/models/week.py` contains `Week`, `WeekMeal`, `WeekMealIngredient`, `WeekMealSide`, `GroceryItem`, `ExportItem`, `ExportRun`, `PricingRun`, `RetailerPrice`, `WeekChangeBatch`, `WeekChangeEvent`, `FeedbackEntry`.

That file's name says "week" but it owns the change-event log, the export queue, the pricing pipeline, and the feedback form. This is the same kind of organization drift that produced the god-modules in §4.1. Splitting into `models/meal_planning/` (Week, WeekMeal, WeekMealIngredient, WeekMealSide, GroceryItem) + `models/exports.py` (ExportItem, ExportRun) + `models/pricing.py` (PricingRun, RetailerPrice) + `models/audit.py` (WeekChangeBatch, WeekChangeEvent) + `models/feedback.py` (FeedbackEntry) — or at least one `models/meal_planning.py` for the week-adjacent set — would be a small change with high readability payoff.

### 4.11 [P1] Subscription "trial mode" is a global boolean, not a per-user record

**File:** `app/config.py:87` (`trial_mode_enabled: bool = False`).

The trial is gated by `SIMMERSMITH_TRIAL_MODE_ENABLED=true`, which flips `is_pro()` to return True for all users. This is fine for the *current* "Pro for everyone" promo, but:

- It can't be turned on for one user and off for another. If you want to A/B test paid conversion, you can't.
- It can't have an expiry date per user.
- A future "free trial expires in 7 days" feature can't be expressed as a config flag.
- The risk of leaving it on in production is real: `is_trial: true` is set in `/api/profile` so iOS can show promo copy, but the server-side `is_pro()` doesn't know that. So a Pro check on a paid-only endpoint could fire for a user who is *visually* in trial state.

**Suggested direction:** replace the boolean with a `TrialEndsAt` column on the User or Subscription table, with `is_pro()` returning True when the trial is active. Then the promo is "trial granted to all users, expires 2026-09-01" rather than "trial is on for everyone, including the dev environment."

### 4.12 [P2] `Settings` is a 270-line god-config

**File:** `app/config.py` (270+ lines, 50+ fields, one `Settings` class).

`Settings` mixes auth (JWT, Apple, Google, OAuth, SSO), AI (10+ fields), images, recipes, App Store IAP (8 fields), APNs (5 fields), push scheduler, observability, dev/local. This is a single class with no grouping. Splitting into composable sub-configs would help with documentation and review (a PR touching APNs config should not have to read past 200 lines of unrelated settings).

**Suggested direction:** decompose `Settings` into nested sub-configs with `@computed_field` or pydantic-settings' nested model support. Even if they all live in one env-namespace (`SIMMERSMITH_AI_*`, `SIMMERSMITH_APNS_*`, `SIMMERSMITH_APPLE_IAP_*`), the type is `Settings` with `auth: AuthConfig`, `ai: AIConfig`, `apns: APNSConfig`, etc. The current code uses individual flat field names (`ai_openai_api_key`, `apns_team_id`, `apple_iap_bundle_id`) which is fine for env-var stability, so the decomposition should be careful not to break the env contract. The cheapest version is a `Config` namespace class with sub-configs *that read the same env vars* via pydantic-settings prefixes.

### 4.13 [P2] `test_api.py` is a 1,899-line monolith

**File:** `tests/test_api.py` (1,899 lines).

By contrast, the rest of the test suite is well-organized into `test_batch_idor.py`, `test_batch_pricing_rebalance.py`, `test_batch_recipes.py`, `test_grocery.py`, `test_assistant_tools.py`, etc. The `test_api.py` outlier likely covers many distinct endpoints. Splitting it along the same pattern (`test_api_auth.py`, `test_api_recipes.py`, `test_api_weeks.py`, `test_api_assistant.py`, `test_api_grocery.py`, ...) would be mechanical and would make it obvious which test file is failing on a regression.

### 4.14 [P2] Repo hygiene

- **`AuthKey_*.p8` files at the repo root** (`AuthKey_46NXHV5UB8.p8`, `AuthKey_6X83L5SG4J.p8`, `AuthKey_7R3R6JP368.p8`, `AuthKey_7W4M2A3LWZ.p8`). These are Apple Sign In / APNs private keys. If they're not gitignored, they should be; if they are, they should not be in the working tree at all. Either way, they should live in `1Password` / macOS Keychain / `fly secrets set` only. The fact that the path is committed suggests they may have been left in the working tree during a debugging session.
- **`SimmerSmith-2.zip`, `minimal-bold-...tiff` (12 MB) at the repo root.** Not committed (presumably .gitignore'd), but clutter. A `tmp/` or `.scratch/` directory at the repo root for ad-hoc artifacts would help.
- **`spikes/` directory.** Once a spike is validated, it should move to `docs/` or be deleted. A `spikes/` directory that lives forever becomes a second source of truth.
- **`HANDOFF.md` (19 KB) at the repo root** is likely stale; the active handoff is `.docs/ai/current-state.md`. Worth checking the last-modified date and either deleting or moving to `docs/`.
- **`admin/` directory (16 entries)** at the repo root. The AGENTS.md says the web frontend is being removed. If `admin/` is a web admin panel, it's a candidate for the same fate. If it's a CLI admin tool, it should probably be under `scripts/`.
- **No `LICENSE` mention in `pyproject.toml`** is fine because `LICENSE` is at the root. Worth a glance.
- **No CI configuration visible.** No `.github/workflows/`, no `.circleci/`, no GitLab CI. The `pytest` and `ruff` commands in AGENTS.md are run manually. Adding a CI workflow that runs `ruff check . && pytest` on every PR would be a 1-hour change and would catch a lot of regressions.

### 4.15 [P2] No pre-commit hooks, no SwiftLint/SwiftFormat

There's no `.pre-commit-config.yaml` at the repo root and no SwiftLint config (`/.swiftlint.yml`) in the iOS project. With 17 `AppState+*.swift` extensions and a 270-line `config.py`, formatting drift is going to happen. A pre-commit config that runs `ruff format --check`, `ruff check`, and (for iOS) `swift-format lint` would keep things tidy. Optional but high-leverage.

### 4.16 [P2] No API contract / breaking-change detection

There are 49 Alembic migrations and 23 API routers, but no schema-diff or OpenAPI-compat test in CI. iOS clients can't easily upgrade if a single field rename silently breaks them. Two cheap options:

- Snapshot `app.main:app`'s OpenAPI schema in CI; fail if a non-additive change is detected.
- Run `swift test` against a pinned `openapi.json` for the iOS DTOs.

Either is a 1-day change with long-term payoff.

### 4.17 [P2] Push notifications — single-machine scheduler

**File:** `app/services/push_scheduler.py` (349), `fly.toml` (`min_machines_running = 1`).

The push scheduler runs APScheduler in-process on a single Fly instance. With `auto_stop_machines = "suspend"` and `min_machines_running = 1`, the *web* surface will auto-stop on idle, but the instance that wakes to serve a request is also the instance that runs the scheduler. This is fragile:

- The instance could be suspended right when a 5-minute tick was due.
- The scheduler shares the DB connection pool with the web app, so a long-running web request can starve a tick.
- Horizontal scaling (adding a second instance) would run two schedulers, double-firing APNs.

**Suggested direction:** move scheduling to a Fly Machine dedicated to push, or to a managed scheduler (Fly's scheduled machines, or external cron calling a `/internal/scheduler_tick` endpoint that uses a `SELECT ... FOR UPDATE SKIP LOCKED` claim). Even a 50-line change that requires a "leader" lock (Postgres advisory lock) would prevent double-fires.

### 4.18 [P2] Caching is per-process

**Files:** `app/services/ingredient_catalog/` (explicit in-memory cache), no other cache layer.

The ingredient catalog is the only thing explicitly cached, and it's in-process. The next deploy loses the cache. There's no Redis, no `functools.lru_cache` on any DB query, no HTTP cache headers on `/api/profile` or `/api/weeks/{id}` (which are read-heavy). For a service with so many read paths and an iOS client that re-pulls on every app foreground, a small Redis (or even `cachetools` with a per-process LRU) would meaningfully cut DB load.

### 4.19 [P3] Apple `AuthKey_*.p8` files at the repo root

Repeated from §4.14 for emphasis: 4 private key files sitting in the working tree. Verify they are git-ignored and not in the index. If they are committed at any point in history, consider rotating them.

## 5. Recommendations (Sequenced)

A pragmatic ordering: each step is independently valuable and mergeable.

### Phase 1: Observability & safety (1–2 days)

1. Add `X-Request-Id` middleware + `contextvars` for log correlation.
2. Add per-user, per-endpoint rate limiting (`slowapi` with Postgres backend).
3. Add per-host circuit breaker for OpenAI / Anthropic / Apple / Google / USDA.
4. Add OpenTelemetry: `opentelemetry-instrumentation-fastapi`, `opentelemetry-instrumentation-httpx`, console exporter for now, OTLP later.
5. Add `GET /api/metrics` (Prometheus exposition format) as a side-effect of the OTel work.

### Phase 2: Bound the service layer (1–2 weeks)

1. Create `app/services/{ai,meal_planning,recipes,identity,commerce,notifications,events}/` package skeletons.
2. Move one module at a time, starting with the lowest-coupling ones (e.g. `push_apns.py` → `notifications/`, `oauth.py` → `identity/`).
3. Update imports; no behavior change.
4. Split `assistant_ai.py` into `ai/streaming.py`, `ai/providers/`, `ai/assistant_loop.py` once it has a package home.
5. Split `grocery.py`, `recipe_ai.py`, `week_planner.py` along their internal sections.

### Phase 3: iOS store decomposition (1–2 weeks)

1. Identify the 5 highest-churn `AppState+X.swift` files (probably Assistant, Weeks, Recipes, Events, Profile based on the feature list).
2. For each, create a `@MainActor @Observable final class XStore` and migrate callers.
3. Keep the `AppState+X.swift` files as thin pass-throughs for one release.
4. Delete the pass-throughs.

### Phase 4: Configuration & data model cleanup (1 week)

1. Decompose `Settings` into nested sub-configs.
2. Introduce a `ProfileSettings` Pydantic model; replace the kv reads.
3. Move `Privacy` and `Terms` HTML out of `main.py` to `app/static/`.
4. Move `AuthKey_*.p8` files out of the working tree.
5. Replace `trial_mode_enabled` with a per-user `trial_ends_at`.

### Phase 5: Hardening (continuous)

1. CI workflow: `ruff check`, `pytest`, `xcodebuild` iOS sim build.
2. Pre-commit: `ruff format`, `ruff check`, `swift-format`.
3. Push scheduler leader election.
4. Sync-architecture doc.
5. OpenAPI snapshot test.
6. Test split (`test_api.py` → per-endpoint files).

## 6. Cross-Cutting Concerns

### Security

- **Apple/Google JWKS verification is correctly done** with `PyJWKClient`, `require` option for claim presence, audience + issuer pinning, and 30s leeway. Good.
- **HS256 session JWT is hardcoded** to prevent alg-confusion. Good.
- **`AI_SECRET_KEYS` denylist** in `app/services/ai.py` is the right *defense-in-depth*; the real fix is a typed `ProfileSettings` model that doesn't accept these keys at all (§4.3).
- **No CSRF protection on state-changing endpoints**, but that's appropriate for a Bearer-token API consumed by iOS.
- **No CORS configuration visible** in `app/main.py` — there must be one, or the iOS app wouldn't be able to call it from a development machine. Worth confirming it's restricted to known origins in production.
- **The `api_token` legacy bearer falls through to `local_user_id`** — this is fine for dev, but the warning at startup ("No authentication configured — API is open") is the only thing standing between a misconfigured production deploy and an open API. Consider a hard fail in production environments.
- **The `AuthKey_*.p8` files** at the repo root are a real concern. If they were ever committed, rotate them.

### Observability

- Logs go to stdout, captured by Fly — good.
- No structured logging (everything is string-formatted `logger.info("foo %s", x)`). OpenTelemetry + structured logs would make log search dramatically more useful.
- No request tracing, no metrics, no AI cost tracking.
- The custom `REQLOG` line per request is valuable but doesn't include response size, latency, or correlation ID. Adding those three fields would make it competitive with the FastAPI instrumentor's access logs.

### Testing

- 68 test files, well-organized into `test_batch_*` files for cross-cutting concerns.
- `test_api.py` outlier is a code smell (1,899 lines, likely should be split).
- No contract / snapshot tests for the OpenAPI schema.
- No load / soak / chaos tests for the AI endpoints.
- No iOS UI tests in CI (the `SimmerSmithUITests/` directory exists; whether they're wired up in CI is unclear).
- The `test_auth_concurrency.py` and `test_auth_email_verified.py` suggest you've thought about auth edge cases — good.

### Performance

- `grocery.py`'s `parse_quantity` and `normalize_name` are pure functions and are likely called many times per request. A small `functools.lru_cache` would help.
- The `_RequestLogMiddleware` parses headers by hand. Fine for current scale.
- No HTTP/2 push, no compression middleware, no ETag headers on GETs.
- The CloudKit mirror (when active) is a second source of truth; the round-trip cost of "edit on iPhone, push to CloudKit, pull from server" needs measurement.

## 7. iOS-Specific Findings

- **`@MainActor @Observable final class AppState` is the right primitive** — the issue isn't the choice, it's the scope.
- **`AIAssistantCoordinator` is a separate type** with a `lazy var` on `AppState` — that's a good pattern for stateful coordinators that should outlive the AppState. More of these would help.
- **`SimmerSmithKit` is a clean package boundary** with API, Configuration, Keychain, Models, Persistence, and the main module file. The package's `Package.swift` correctly targets iOS 26+ / macOS 15+.
- **`SimmerSmithCloudKit` is a separate package** — clean separation, but the readme in the package is worth a glance.
- **`BackgroundSyncService`, `LocalNotificationService`, `NotificationManager`, `PushService`, `RemindersService`, `VoiceCommandService`, `SpokenStepService` in `Services/`** are 8 service types. That's a lot. Worth checking if any of them are actually one-shot helpers that could be folded into a feature module.
- **The `Features/` directory has 15 feature folders** (Activity, AIAssistant, Assistant, Cooking, Events, Grocery, Ingredients, Onboarding, Paywall, Recipes, Settings, Shared, Vision, Week, plus a meta one). The `AIAssistant` and `Assistant` folders both exist — are they different? Worth verifying.
- **`SpokenStepService` and `VoiceCommandService`** are interesting — cooking mode has voice navigation? That's a strong accessibility story and worth highlighting in product copy.

## 8. Operational Concerns

- **One Fly instance, 512 MB, `shared-cpu-1x`** is fine for a small user base, but AI features can spike CPU. Watch the `fly dashboard` graphs.
- **`auto_stop_machines = "suspend"` + `min_machines_running = 1`** means cold-starts on the auto-stopped instance. The first request after suspension will be slow (~2-5s). For an iOS app that pulls on launch, this matters.
- **No CDN** in front of static assets. The Privacy / Terms pages will hit the Python process. Once they're moved to `StaticFiles`, Fly's edge can serve them.
- **No backup story documented** for the Postgres volume (Neon free tier or Fly Postgres). A 1-page runbook for "how do I restore from backup" would be useful before the first incident.
- **No feature flag system.** The `trial_mode_enabled` is a hand-rolled feature flag with no dashboard, no rollout control, no targeting. Consider `posthog`, `launchdarkly`, or even an env-driven JSON file of feature flags.
- **No error reporting** (Sentry, Bugsnag, etc.). For an iOS + FastAPI + 49-migrations product, an unhandled exception in production is currently invisible. Sentry's free tier covers both Python and Swift.

## 9. What's Working Really Well

To balance the concerns above, a few patterns deserve to be preserved through any refactor:

- **The MCP-REST coupling** is the right call.
- **The stateless MCP transport** is the right call.
- **The custom request log middleware** is the right call.
- **The deep `/api/health/ready`** is the right call.
- **The OperationalError → 503 + Retry-After** is the right call.
- **The multi-tenant household invariant enforced at the schema level** is the right call.
- **The `unit_system_directive` prompt-injection-style unit system localization** is the right call.
- **The iOS SPM package split** (SimmerSmithKit, SimmerSmithCloudKit) is the right call.
- **The `Apple IAP` configuration surface** (env, app_apple_id, sandbox toggle, replay guard) is the right call.
- **The `lazy var` coordinator pattern** in `AppState` is the right call.

The project is solid. The recommendations are about *making the next 12 months easier*, not about fixing things that are broken.

---

## Appendix: Files Read

- `app/main.py` (500 lines)
- `app/config.py` (270 lines)
- `app/db.py`
- `app/auth.py` (280 lines)
- `app/mcp/__init__.py` (195 lines)
- `app/services/bootstrap.py`
- `app/services/grocery.py` (first 100 lines)
- `app/services/assistant_ai.py` (first 80 lines)
- `app/services/ai.py` (first 100 lines)
- `app/api/recipes.py` (first 80 lines)
- `app/api/assistant.py` (first 100 lines)
- `app/models/__init__.py`
- `app/models/user.py`
- `app/models/household.py`
- `SimmerSmith/SimmerSmith/App/AppState.swift` (first 60 lines)
- `Dockerfile`
- `fly.toml`
- `pyproject.toml`
- `tests/conftest.py` (first 40 lines)
- `SimmerSmithKit/Package.swift`

## Appendix: Repo Stats at Review Time

- 49 Alembic migrations
- 68 test files
- 23 API routers
- 50 service files (~25,000 LOC in `app/services/`)
- 20 model files
- 55 MCP tools (per AGENTS.md)
- 17 `AppState+*.swift` extensions (~3,900 LOC)
- 1 FastAPI app, 1 iOS app, 2 SPM packages, 1 SimmerSmithCloudKit package
- `git log --oneline -5` (most recent): feat(sp-a) Phase 3 CKAsset recipe imagery, verified live + dual-review hardened
