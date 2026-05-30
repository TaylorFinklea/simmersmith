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

## Fixed this session (14 findings, 6 commits, 462 tests green)

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

- **F22 — Apple IAP receipts are forgeable (`app/services/subscriptions.py`).**
  `verify_transaction_jws`/`decode_signed_payload` take the leaf public key from the *attacker-supplied* `x5c` header and verify against it, with **no validation that the chain roots in Apple Root CA - G3**. Any authed user can forge a JWS granting permanent Pro. **Latent today** because trial-mode grants Pro to everyone; **live the moment you monetize (M5).**
  - *Decision needed:* fix with Apple's official `app-store-server-library` (audited chain validation, adds a dependency) **or** hand-roll x5c chain validation against a bundled Apple Root CA - G3. Recommend the official library.
  - Pairs with **F23/F24** (no transaction-id replay/dedup, no `appAccountToken` binding, webhook has no freshness/replay protection) — do them together once the chain is validated.

- **F11 — MCP per-request identity doesn't reach tool dispatch (`app/mcp/auth.py`).**
  Stateful streamable-HTTP runs `app.run()` in a task whose context is frozen at session creation, so `_current_user_id_var` (set per request in `verify_token`) is not observed by tool dispatch — every tool resolves to the session's *first* user. Correct for one-user-per-connection (today), but a latent cross-tenant landmine if a session id is ever reused across tokens, and it falls through to `local_user_id` if unset.
  - *Fix (architectural):* read identity from the per-message MCP request context / ASGI `scope["user"]` instead of a module ContextVar; add an integration test that calls two tools with two bearer tokens on one connection. Touches all MCP tool modules.

### High — backend, contained but delicate or domain-specific

- **F9** — SSE loop spawns orphaned blocking `queue.Queue.get` threads (executor exhaustion + dropped events). Fix: `asyncio.Queue` + `call_soon_threadsafe`. *Delicate streaming path — exercise the assistant flow.*
- **F10** — tool runner swallows mid-mutation exceptions while `session_scope` commits partial state → wiped week. Fix: `session.rollback()` (or savepoint) before returning `ok=False`. *Delicate; verify against the planning flow.*
- **F26/F27** — base-ingredient + variation mutate/archive/merge routes lack household ownership checks (cross-household + global-catalog poisoning). *Needs the global-vs-household catalog governance model decided (who may edit `approved` rows — admin only?).*
- **F28** — recipe-import SSRF is incomplete: only IP-literal hostnames are blocked; DNS names + redirects to internal IPs/metadata still reachable (`follow_redirects=True`). Fix: resolve + validate every A/AAAA against private ranges, disable/revalidate redirects.
- **F20** — `household_id` was added `nullable=True` in migration 0027 and never flipped to `NOT NULL`, while the models declare `nullable=False`. Schema doesn't enforce tenant scoping. Fix: a backfill + `alter_column` migration. *Deploy-sensitive.*

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
- **MCP surface re-uses REST route functions by calling them as plain Python**, which bypasses FastAPI DI — so each tool must remember to pass `current_user=_current_user(session)`. Several didn't (F13/F14 fixed; more remain in `recipes.py`). A thin scoped-context helper or a decorator would make this uniform and stop the "always errors / runs unscoped" class.
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
