# Bug Sweep + Architecture Review — 2026-05-30

Multi-agent sweep of the whole codebase (FastAPI backend, SwiftUI iOS,
MCP server, SvelteKit admin, cart-automation skill). Method: 20 parallel
subsystem reviewers → 101 raw findings → adversarial verification (3
independent lenses/finding, majority vote) → fixes for the contained,
confirmed critical/high items.

## Method note (why the numbers look the way they do)

- 20 domain/lens reviewers produced **101 findings** (6 critical, 23 high, 35 medium, 37 low).
- Verification ran 3 lenses (correctness / reachability / adversarial-refute) per critical/high finding.
- **0 findings were refuted.** 19 of the 29 critical/high reached a 3/3 "real" verdict; the other 10 timed out in the verifier queue (not debunked) and were confirmed by hand where acted on.
- One finder (`skills-cart`) hung and was dropped — the cart-automation skill was **not** reviewed. Re-run if it matters.

## Fixed this session (~26 findings, 13 commits)

First batch (below, 14 findings). A user-approved follow-up batch then fixed
both criticals + the delicate/IDOR/SSRF set — see "Follow-up batch" further down.

| ID | Sev | Area | Fix | Commit |
|----|-----|------|-----|--------|
| F6 | crit | household | `claim_invitation` deleted a joiner's *shared* household (cascading away co-members + their data). Guard merge behind a single-member invariant; 409 otherwise. | `21072f4` |
| F4 | high | events | event grocery used `user_id` for `staple_names` (needs `household_id`) → staples never filtered. | `972a5ef` |
| F5 | high | events | event grocery double-counted `event_quantity` on every refresh; unmerge before regenerate. | `972a5ef` |
| F7 | high | events | `update_event` tautology NULLed `event_date` on every partial PATCH; `_UNSET` sentinel. | `972a5ef` |
| F8 | high | admin | Worker also served the admin portal on `*.workers.dev`, bypassing Cloudflare Access; `workers_dev = false`. | `e98e869` |
| F1/F21 | high | oauth | Stored XSS: unauthenticated `client_name` rendered unescaped on the consent page; HTML-escape. | `97cd553` |
| F3 | high | oauth | `state`/`code` concatenated raw into redirects/href; route through `urlencode`. | `97cd553` |
| F2 | high | oauth | open DCR accepted `javascript:`/`data:`/non-loopback-http redirect URIs; scheme allowlist. | `97cd553` |
| F15/F12 | high | exports | export routes + MCP tools loaded `ExportRun` by id with no household check (IDOR read+write); scope via `get_week`. | `328b400` |
| F18 | high | recipes | `upsert_recipe` loaded recipe/base_recipe unscoped (overwrite/leak another household); household-scoped `get_recipe`. | `328b400` |
| F13/F14 | high | mcp | `ingredients_list`/`ingredients_create` always errored (no `current_user`). | `5e31ef7` |
| F25 | high | recipes | suggestion-draft passed `user_id` where `household_id` expected → empty recipe context. | `5e31ef7` |
| F19 | high | ai | Anthropic `max_tokens=1800` truncated event menus mid-JSON → 502; raised to 4096. | `5e31ef7` |

Each fix has a regression test where the behavior is unit-testable (household guard, event double-count, event_date preservation, OAuth escaping/redirect validation).

## Confirmed but NOT fixed — needs a decision or careful/dedicated work

### Critical

### Follow-up batch — ALSO FIXED this session (user-approved, after the report was first drafted)

- **F22 — Apple IAP receipts forgeable → FIXED (`2c17b0f`).** Replaced the hand-rolled "trust the leaf key in the token" verification with Apple's official `app-store-server-library` `SignedDataVerifier`, validating the full x5c chain against the bundled **Apple Root CA - G3** (`app/data/apple_roots/`). Configured-env-first-then-fallback so TestFlight Sandbox receipts still verify. Added `SIMMERSMITH_APPLE_IAP_APP_APPLE_ID` (required for Production). Forged-receipt regression test.
- **F11 — MCP per-request identity → FIXED (`6d9336e`).** Set `stateless_http=True`: the stateless transport starts the server task from within each request's task, so anyio copies the authenticated-user context in and the existing ContextVar scoping is correct + leak-free per request. **⚠️ Pre-deploy gate: smoke-test the Claude.ai connector** (couldn't be tested from the sandbox); one-line revert if it regresses.
- **F9 — SSE orphaned threads → FIXED (`dfa29bd`).** `asyncio.Queue` fed from the worker thread via `loop.call_soon_threadsafe`; consumer awaits `get()` directly so timeouts cancel cleanly (no leaked threads, no dropped events).
- **F10 — tool-runner partial commit → FIXED (`5c9ecfe`).** `session.rollback()` before returning `ok=False` so a post-delete crash can't commit a wiped week. Regression test added.
- **F26/F27 — ingredient cross-household IDOR → FIXED (`561a752`).** Route-layer guard rejecting mutation of *another household's private* row. **Scope decision made:** the global `approved` catalog stays collaboratively editable (the resolver falls through to it and an existing test codifies household merge/archive of it) — locking it to admins is a separate product call. Two-household regression tests.
- **F28 — recipe-import SSRF → FIXED (`e71195b`).** `_assert_public_url` resolves the host and rejects any private/loopback/link-local/reserved A/AAAA; redirects followed manually with per-hop revalidation. Regression tests.
- **More MCP `current_user` (medium) → FIXED (`ce5d449`).** `recipes_list` (passed `user_id` for `household_id`) + 5 metadata/nutrition tools that errored. Pyright surfaced `recipes_list` beyond the original findings. Tool-invocation regression tests.

### Still NOT fixed — remaining work

- **F23/F24 (IAP replay/dedup).** Now **low-risk** since F22 closes forgery (a real Apple-signed receipt is required). Proper fix needs: an iOS `appAccountToken` set at purchase + matched server-side (to stop receipt re-binding), and a `notificationUUID` dedup table + `signedDate` freshness for the webhook. iOS-dependent + a migration.
- **F20 — `household_id` NOT NULL migration.** Backfill + `alter_column`. *Deploy-sensitive* — left for a deliberate migration.
- **F16/F17/F29 — iOS** (below): can't verify without a build.

### High — iOS (can't verify here; need an iOS build/sim)

- **F16** — `clearLocalCache()`/`resetConnection()` leak `browsedWeek` + event/guest/pantry collections across sign-out.
- **F17** — `submitMealFeedback`/`submitGroceryFeedback` post against `currentWeek` even when viewing a browsed week.
- **F29** — push device token never unregistered on sign-out; stale `lastToken` blocks re-registration for the next account on a shared device.

## Notable medium findings (not yet verified individually; worth a pass)

Security: session JWT algorithm not pinned (`app/auth.py`); no `jwt_secret` strength/presence check (`app/config.py`); `verify_state` doesn't pin `aud`/`iss` and provider `email_verified` not checked (`app/services/sso.py`); free-tier gate bypassed if `SIMMERSMITH_API_TOKEN` is whitespace-only; **more MCP tools missing `current_user`** in `app/mcp/recipes.py` (same class as F13/F14 — the threading fix is incomplete across the surface); ingredient-detail GET IDOR read.

Concurrency: invitation-claim double-spend race; `increment_usage` read-modify-write race; concurrent first-sign-in user/household creation race.

Data-integrity: migrations + full seed run twice on startup (mounted MCP lifespan re-run); `Recipe.id` String(120) vs FK String(36) mismatch; assistant markdown drops earlier tool-loop text; `dedupe_week_grocery` can tombstone event-merged rows.

Perf: push scheduler holds one DB session across all users' blocking APNs calls; Kroger pricing = one blocking external call per grocery item; N+1 in ingredient list.

(Full machine-readable list of all 101 findings was extracted during the sweep; see commit history + this report for the actioned subset.)

## Architecture review (high level)

- **Multi-tenancy (`household_id`) is an application convention, not a schema guarantee (F20).** The most common bug class this sweep found was IDOR / wrong-id-scoping (F12/F15/F18/F25/F26/F27 + mediums): resources fetched by primary key without a household filter, or `user_id` passed where `household_id` is expected. Two systemic mitigations would prevent recurrence: (1) flip `household_id` to `NOT NULL` and add a scoped-lookup helper used everywhere; (2) the `CurrentUser(id, household_id)` split is error-prone — every "passed user_id instead of household_id" bug stems from it.
- **MCP surface re-uses REST route functions by calling them as plain Python**, which bypasses FastAPI DI — so each tool must remember to pass `current_user=_current_user(session)`. Several didn't and silently errored or ran unscoped (F13/F14 + 6 more in `recipes.py`, all now fixed). A thin scoped-context helper or a `with_current_user` decorator would make this uniform by construction and stop the class recurring.
- **Auth/OAuth/PKCE core is solid** (alg-pinned identity verification, S256 PKCE, single-use codes, exact redirect-uri match, aud-scoped MCP tokens). The OAuth *HTML/registration* surface was where the holes were (now fixed). The IAP verification is the one genuinely broken crypto path (F22).
- **Assistant streaming + tool-runner transaction handling (F9/F10)** is the most fragile subsystem: blocking primitives inside an async generator, and a swallow-all except that can commit partial mutations. Worth a focused hardening pass with the assistant flow exercised.
- **iOS `AppState` `currentWeek` vs `browsedWeek` duality** keeps producing "acted on the wrong week" bugs (F16/F17 + a medium on grocery mutations). Consider routing all week mutations through a single "displayed week" accessor.

## Feature suggestions (grounded in what was seen)

- Tenant-scope safety net: a single `require_owned(session, household_id, Model, id)` helper + `NOT NULL household_id` so IDOR can't recur.
- MCP: a `with_current_user` wrapper so every tool is scoped by construction.
- Assistant: persist the full streamed transcript (medium finding — earlier tool-loop text is dropped from the final message).
- Rate limiting on the unauthenticated OAuth `/register` + `/authorize` and on expensive AI endpoints (none today).
- Re-run the bug sweep over `skills/simmersmith-shopping/` (the one subsystem the hung finder never covered).

## Verification artifacts

- Workflow scripts used: `.docs/ai/_bugsweep_workflow.js`, `_verify_workflow.js`, `_verify_workflow2.js` (scratch; safe to delete).
- All fixes: `git log 21072f4^..5e31ef7`.
