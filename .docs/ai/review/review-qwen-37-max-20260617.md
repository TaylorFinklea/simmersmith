# SimmerSmith Architectural Review

**Reviewer:** pi (Claude Opus 4.6)
**Date:** 2026-06-17
**Scope:** Full-stack — FastAPI backend, SwiftUI iOS client, CloudKit migration layer, deployment infrastructure

---

## Executive Summary

SimmerSmith is a mature, feature-rich AI-first meal planning app with ~16,500 lines of Python backend, ~32,000 lines of Swift iOS code, 593 passing tests, and 48 Alembic migrations. The codebase has grown rapidly — 24 milestones shipped in ~3 months — and it shows: the breadth is impressive, but several structural patterns have accumulated technical debt that will slow the CloudKit migration and future feature work. This review identifies **7 high-impact** and **9 medium-impact** improvement areas.

---

## 1. Backend Architecture

### 1.1 Service Layer: God Modules (HIGH)

**Problem:** Several service files have grown into monoliths that are hard to test, review, and modify in isolation.

| File | Lines | Concern |
|------|-------|---------|
| `assistant_ai.py` | 1,066 | Streaming, provider dispatch, adapter pattern, tool loop all in one |
| `assistant_tools.py` | 909 | All 11 assistant tools as functions in a single file |
| `grocery.py` | 876 | Merge logic, aggregation, dedup, event bridging, smart-regen |
| `recipe_ai.py` | 865 | Recipe drafting, refinement, suggestion, JSON extraction |
| `week_planner.py` | 714 | Prompt building, AI calls, guardrails, scoring, rebalancing |

**Impact:** Each file mixes prompt engineering, HTTP transport, business rules, and DB queries. A change to one concern risks breaking another. The `_call_ai_provider` in `week_planner.py` creates a new `httpx.Client` per call (no connection pooling), while `assistant_ai.py` has its own separate HTTP path.

**Recommendation:**
- Extract a shared `AIClient` class (or use the `AIProviderKit` already in `SimmerSmithCloudKit/`) that handles connection pooling, retries, and provider dispatch. Both `week_planner` and `assistant_ai` should call into it rather than each building their own HTTP path.
- Split `grocery.py` into `grocery_merge.py` (merge/dedup/conflict resolution) and `grocery_queries.py` (CRUD/aggregation).
- Split `assistant_tools.py` into one file per tool domain (week tools, recipe tools, profile tools) with a shared registry.

### 1.2 Route Handlers: Business Logic in API Layer (HIGH)

**Problem:** The `app/api/` layer totals 6,506 lines, with individual route files reaching 800+ lines. Routes like `recipes.py` (840 lines) and `weeks.py` (800 lines) contain substantial business logic — query construction, conditional branching, response shaping — that should live in services.

```
app/api/recipes.py    840 lines
app/api/weeks.py      800 lines
app/api/assistant.py  703 lines
app/api/events.py     683 lines
app/api/oauth.py      679 lines
```

**Impact:** Route handlers are hard to unit test without the full FastAPI test client. Business logic duplicated across routes (e.g., household scoping checks) creates drift risk.

**Recommendation:** Route handlers should be thin — validate input, call a service function, shape the response. Move query construction and business rules into the corresponding service module. This is partially done (services exist) but inconsistently applied.

### 1.3 Synchronous Database Access in an Async Framework (HIGH)

**Problem:** FastAPI is an async framework, but the entire database layer uses synchronous SQLAlchemy (`create_engine`, `Session`, `session_scope`). Every route handler that touches the database blocks the event loop. The `get_session` dependency yields a synchronous `Session`.

```python
# app/db.py — synchronous engine + session
def get_session() -> Session:
    session = get_session_factory()()
    try:
        yield session
    finally:
        session.close()
```

Meanwhile, AI provider calls in `week_planner.py` also use synchronous `httpx.Client`:

```python
with httpx.Client(timeout=timeout) as client:
    response = client.post("https://api.openai.com/v1/chat/completions", ...)
```

**Impact:** On Fly.io's shared-cpu-1x, a single week-plan generation (30–300s) blocks the entire process. Concurrent requests from household members, push scheduler ticks, and MCP tool calls all queue behind it. The SSE heartbeat in `assistant.py` exists precisely because of this blocking behavior.

**Recommendation:**
- **Short term:** Wrap blocking DB calls in `asyncio.to_thread()` at the route level (FastAPI does this automatically for sync route handlers, but the AI provider calls in services are not route handlers).
- **Medium term:** Migrate to `asyncio`-native SQLAlchemy (`create_async_engine` + `AsyncSession`) and `httpx.AsyncClient` for AI calls. This is a significant refactor but would unlock true concurrency on the single Fly machine.
- **Immediate fix:** At minimum, the `_call_ai_provider` in `week_planner.py` should use `httpx.AsyncClient` and be awaited, so the event loop isn't blocked during the 30–300s AI call.

### 1.4 48 Migrations with No Consolidation (MEDIUM)

**Problem:** 48 Alembic migration files accumulated over 3 months. Many are small (single column adds) and some have naming inconsistencies. No consolidation or squashing has been done.

**Impact:** New developer onboarding runs 48 sequential migrations. Migration ordering bugs become harder to diagnose. The `alembic/versions/` directory is a timeline of every schema decision, including reversed ones.

**Recommendation:** Squash migrations into ~5–10 consolidated files at the next natural boundary (e.g., after CloudKit migration lands). Keep the originals in a `migrations-archive/` branch for reference.

### 1.5 Synchronous Migrations in Lifespan (MEDIUM)

**Problem:** `run_migrations()` executes Alembic migrations synchronously during the FastAPI lifespan startup. On Fly.io, this means the health check fails until all migrations complete, which can take several seconds on a cold start with a remote Postgres.

```python
@asynccontextmanager
async def lifespan(_: FastAPI):
    try:
        run_migrations()
    except BaseException as exc:
        _log_lifespan_failure("run_migrations", exc)
        raise
```

**Impact:** Cold starts are slow. If a migration fails, the entire app fails to start with no graceful degradation.

**Recommendation:** Run migrations as a separate `fly release_command` step (Fly.io supports this natively in `fly.toml`), not inside the app lifespan. This decouples schema evolution from app startup and gives Fly's release machinery a chance to abort a bad deploy before it reaches production traffic.

### 1.6 HTML Legal Pages Embedded in Python (LOW)

**Problem:** The privacy policy and terms of use are ~40-line HTML strings embedded directly in `app/main.py`. They're served from Python route handlers.

**Impact:** Content updates require a code change + deploy. The HTML is untested and unlinted.

**Recommendation:** Move to static files in a `static/` directory or a simple template, served by the SPA fallback or a CDN.

---

## 2. iOS Architecture

### 2.1 AppState: The Everything Store (HIGH)

**Problem:** `AppState` is a single `@Observable` class that holds the entire application state — profile, weeks, recipes, events, grocery, assistant threads, household, push, reminders, seasonal produce, CloudKit debug state, and more. It has 15+ extension files (`AppState+Weeks.swift`, `AppState+Grocery.swift`, etc.) totaling thousands of lines.

```swift
@MainActor
@Observable
final class AppState {
    var profile: ProfileSnapshot?
    var currentWeek: WeekSnapshot?
    var browsedWeek: WeekSnapshot?
    var recipes: [RecipeSummary] = []
    var recipeMetadata: RecipeMetadata?
    var recipeMemories: [String: [RecipeMemory]] = [:]
    var assistantThreads: [AssistantThreadSummary] = []
    var assistantThreadDetails: [String: AssistantThread] = [:]
    var ingredientPreferences: [IngredientPreference] = []
    var householdAliases: [HouseholdTermAlias] = []
    var pantryItems: [PantryItem] = []
    var guests: [Guest] = []
    var eventSummaries: [EventSummary] = []
    var eventDetails: [String: Event] = [:]
    var checkedGroceryItemIDs: Set<String> = []
    var seasonalProduce: [InSeasonItem] = []
    var currentHousehold: HouseholdSnapshot?
    // ... 30+ more properties
}
```

**Impact:**
- Every view observes the entire AppState, so any state change can trigger re-renders across unrelated views. Swift's `@Observable` macro tracks per-property access, which helps, but the cognitive overhead of understanding what any given view depends on is high.
- `refreshAll()` is a waterfall of sequential network calls. Any single failure puts the app into `.failed` state.
- `clearLocalCache()` must manually nil/reset 30+ properties — a missed one leaks data across accounts (this has already been a bug, per the F16/F17/F29 fix).

**Recommendation:**
- Decompose into domain-specific stores: `WeekStore`, `RecipeStore`, `HouseholdStore`, `AssistantStore`, etc. Each owns its own state, refresh logic, and cache invalidation. `AppState` becomes a coordinator that holds references to the stores and manages cross-store concerns (auth, navigation).
- Replace the waterfall `refreshAll()` with parallel `async let` fetches per store, with independent error states.

### 2.2 Large View Files (MEDIUM)

**Problem:** Several SwiftUI views are very large:

| View | Lines |
|------|-------|
| `WeekView.swift` | 1,909 |
| `SettingsView.swift` | 1,543 |
| `RecipeDetailView.swift` | 1,392 |
| `RecipesView.swift` | 1,198 |
| `RecipeEditorView.swift` | 848 |
| `CloudKitDebugView.swift` | 831 |

**Impact:** Large views are hard to preview, test, and modify. SwiftUI's diffing performance degrades with deeply nested view bodies. `WeekView` at 1,909 lines likely contains dozens of sub-views inlined rather than extracted.

**Recommendation:** Extract sub-views aggressively. A 1,909-line view should be 10–15 extracted components of 100–200 lines each. Use `@ViewBuilder` helper functions for conditional sections.

### 2.3 No Swift Tests (MEDIUM)

**Problem:** The iOS test suite consists of a single `SimmerSmithTests.swift` file (effectively a placeholder) and `SimmerSmithUITests.swift`. There are no unit tests for the AppState logic, API client, caching layer, or any of the 15+ service extension files.

Meanwhile, `SimmerSmithKit` has tests (`PrivatePlaneStoreTests.swift`, `SimmerSmithKitTests.swift`) and `SimmerSmithCloudKit` has 68 tests — the infrastructure is there, but the app target has none.

**Impact:** The iOS bug-bash findings (16 bugs) and the recurring cache-clear/account-switching bugs are symptoms of untested client logic. Every AppState change is a faith-based deployment.

**Recommendation:** Start with the highest-risk paths: `refreshAll()` error handling, `clearLocalCache()` completeness, and the SSE event decoder. Even 20 focused tests would catch the class of bugs that keep recurring.

### 2.4 Hardcoded Production URL (MEDIUM)

**Problem:** `AppState.swift` contains a hardcoded production URL:

```swift
static let productionServerURL = "https://simmersmith.fly.dev"
```

Sign-in methods force this URL regardless of what the user configured:

```swift
func signInWithApple(identityToken: String) async {
    settingsStore.save(serverURLString: Self.productionServerURL, authToken: "")
    serverURLDraft = Self.productionServerURL
    // ...
}
```

**Impact:** Testing against staging or local environments requires code changes. There's no environment-based configuration.

**Recommendation:** Use a build-configuration-based server URL (Debug = localhost, Release = production) or at minimum respect the user's configured URL for sign-in.

---

## 3. Cross-Cutting Concerns

### 3.1 AI Provider Abstraction: Duplicated Across Layers (HIGH)

**Problem:** AI provider dispatch logic exists in at least four separate places:

1. `app/services/ai.py` — `resolve_ai_execution_target()`, provider resolution for the REST API
2. `app/services/week_planner.py` — `_call_ai_provider()` with its own `httpx.Client`
3. `app/services/assistant_ai.py` — `_run_provider_tool_loop()` with `ProviderAdapter` ABC + `OpenAIAdapter` + `AnthropicAdapter`
4. `SimmerSmithCloudKit/Sources/AIProviderKit/` — `ProviderRouter` + `KeyStore` + `AIClient` (built for CloudKit Phase 8, backends stubbed)

Each has its own model resolution, API key resolution, timeout handling, and error mapping.

**Impact:** Adding a new provider (e.g., Gemini for text, not just images) requires changes in 3–4 files. Error handling is inconsistent — `week_planner.py` wraps errors in `AIProviderError`, while `assistant_ai.py` has its own adapter-specific error paths.

**Recommendation:** Consolidate into a single `AIProvider` service that all callers use. The `AIProviderKit` in `SimmerSmithCloudKit/` is already designed for this — finish it and use it from the backend too (or at minimum, mirror its interface in Python). The `ProviderAdapter` pattern from `assistant_ai.py` is the closest to a clean abstraction; promote it to a shared module.

### 3.2 Error Handling: Inconsistent Patterns (MEDIUM)

**Problem:** The codebase has multiple error-handling strategies that don't compose well:

- Global `Exception` handler in `main.py` returns generic 500
- `OperationalError` handler returns 503
- `AIProviderError` mapped to 503 in week_planner but not consistently in other AI callers
- ~30 route sites still use `detail=str(exc)` (noted in the T7 follow-ups)
- SSE streaming errors are sanitized in the assistant but not in other streaming paths

**Impact:** Error responses are inconsistent — sometimes the client gets a clean message, sometimes an exception string, sometimes nothing. The `detail=str(exc)` pattern leaks internal state.

**Recommendation:** Define a small set of domain exceptions (`ServiceUnavailable`, `AIProviderError`, `AuthorizationError`, `ValidationError`) and map them to HTTP status codes in a single middleware or exception handler table. Eliminate all `detail=str(exc)` sites.

### 3.3 Household Scoping: Still Incomplete (MEDIUM)

**Problem:** The M21 household pivot (user_id → household_id) was the source of the largest bug cluster in the bug bash (T1: 9 bugs). While the core queries were fixed, the architecture report notes remaining STRUCTURAL findings:

- FKs on household_id not yet enforced at the DB level
- No RLS (Row-Level Security) as defense-in-depth
- Pagination not household-aware
- Some code paths still fall back to user_id when household_id isn't threaded through

**Impact:** Every new feature that touches shared data needs a household-scoping audit. The absence of DB-level enforcement means a missed `WHERE household_id = ?` clause is a silent data leak between households.

**Recommendation:**
- Add PostgreSQL Row-Level Security policies as a defense-in-depth layer. Even if the app code has a bug, the DB enforces isolation.
- Add a lint rule or test helper that verifies every query on household-scoped tables includes a household_id filter.

### 3.4 MCP Surface: 55 Tools with No Rate Limiting (MEDIUM)

**Problem:** The MCP surface exposes 55 tools at `simmersmith.fly.dev/mcp` behind OAuth 2.1, but there's no per-user rate limiting, no tool-call budget, and no cost tracking per MCP session.

**Impact:** An authorized MCP client (Claude.ai, Codex) can make unlimited tool calls, each potentially triggering AI generation or DB queries. The T5 freemium-not-enforced finding notes this: "uncapped assistant turns."

**Recommendation:** Implement per-user rate limiting at the MCP transport layer (token bucket per access token). Track tool-call counts per session for the freemium gate when M5 activates.

### 3.5 CloudKit Migration: Two Parallel Architectures (HIGH)

**Problem:** The codebase now contains two complete data architectures:

1. **Server-authoritative** (current production): FastAPI + Postgres, iOS as a thin client
2. **Client-authoritative** (in progress): CloudKit + CKSyncEngine + NSPersistentCloudKitContainer, with the server shrinking to AI-only

The `SimmerSmithCloudKit/` package (68 tests) and `SimmerSmithKit/Persistence/PrivatePlane*` are well-built, but they exist alongside the existing server-first architecture with no clear cutover plan in the code.

**Impact:** Every feature change now needs to be evaluated against both architectures. The CloudKit debug views (`CloudKitDebugView.swift`, 831 lines) are shipping in the app. The `AppState` carries both server-fetched and CloudKit-synced state with no clear boundary.

**Recommendation:**
- Define the cutover criteria explicitly (which phase gates the flip, what happens to existing server data).
- Gate CloudKit debug views behind `#if DEBUG` (they may already be, but verify).
- Consider a feature flag that switches between server-first and CloudKit-first modes, so the migration can be gradual and reversible.

---

## 4. What's Working Well

It's important to acknowledge what's strong:

- **Test coverage (backend):** 593 tests covering auth, isolation, IDOR, household scoping, AI provider paths, and edge cases. The adversarial review workflow (implement → review → integrate) caught real bugs before they shipped.
- **Security posture:** Apple/Google OIDC verification, SSRF protection, IAP receipt validation against Apple Root CA, OAuth 2.1 + PKCE for MCP, JWT algorithm pinning, content-type allow-listing. The security sweep was thorough.
- **AI provider flexibility:** The adapter pattern in `assistant_ai.py` and the provider resolution in `ai.py` support OpenAI, Anthropic, and MCP with per-user overrides. The image-gen failover (OpenAI → Gemini) is a nice touch.
- **Grocery merge algorithm:** The `FieldMergeResolver` + `ConflictRepair` in `SimmerSmithCloudKit/` is genuinely sophisticated — deterministic, idempotent, with proper tombstone semantics. The Spike 1 simulation proving NSPersistentCloudKitContainer LWW is unsafe was excellent engineering.
- **MCP as a differentiator:** 55-tool surface with proper OAuth, stateless transport, and per-request user scoping. This is a real competitive advantage.
- **Migration discipline:** Every schema change goes through Alembic with proper up/down paths. The test suite runs migrations on SQLite, catching most issues.
- **Documentation:** The `.docs/ai/` handoff system (roadmap, current-state, decisions, phase specs) is the best cross-session continuity system I've seen in a solo/small-team project. It works.

---

## 5. Priority Matrix

| # | Issue | Impact | Effort | Priority |
|---|-------|--------|--------|----------|
| 1 | Async DB + HTTP in backend | HIGH | L | Do before CloudKit cutover |
| 2 | AppState decomposition (iOS) | HIGH | L | Do before CloudKit Phase 7 |
| 3 | AI provider consolidation | HIGH | M | Do now (blocks new providers) |
| 4 | Service layer god modules | HIGH | M | Incremental per-feature |
| 5 | Route handler thinning | HIGH | M | Incremental per-feature |
| 6 | Household RLS enforcement | MEDIUM | S | Do before multi-household scale |
| 7 | iOS test suite bootstrap | MEDIUM | M | Do now (recurring bug class) |
| 8 | Migration consolidation | MEDIUM | S | After CloudKit lands |
| 9 | Error handling unification | MEDIUM | M | Do incrementally |
| 10 | MCP rate limiting | MEDIUM | S | Before M5 activation |
| 11 | Migrations out of lifespan | MEDIUM | S | Do now (quick win) |
| 12 | Large SwiftUI view extraction | MEDIUM | M | Incremental |
| 13 | Hardcoded production URL | MEDIUM | S | Do now |
| 14 | HTML legal pages → static | LOW | S | Do whenever |

---

## 6. Recommended Next Steps

If I were picking the three highest-leverage changes to make this week:

1. **Move `run_migrations()` out of the lifespan** into a `fly.toml` `release_command`. 30-minute change, eliminates cold-start latency and migration-during-traffic risk.

2. **Make `_call_ai_provider` in `week_planner.py` async** using `httpx.AsyncClient`. This single change unblocks the event loop during the longest operation (week-plan generation) and is a proof-of-concept for the broader async migration.

3. **Bootstrap iOS tests** for the three highest-risk paths: `refreshAll()` error recovery, `clearLocalCache()` completeness (assert every @Observable property is nil'd), and SSE event decoding. Even 10 tests would break the cycle of recurring client-side bugs.

---

*This review was generated by reading ~40 source files, the full roadmap, current-state, and bug-bash reports. It reflects the architecture as of commit `main` on 2026-06-17.*
