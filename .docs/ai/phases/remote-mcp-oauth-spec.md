# Phase Spec: Remote OAuth MCP Server

## Why this, why now

`app/mcp/` already exposes the full SimmerSmith agent surface as
MCP tools across the assistant, weeks, recipes, ingredients, and
profile domains — 55 `@mcp.tool` registrations as of 2026-05-14
(AGENTS.md's "47 tools" line is a stale claim). Today the server
runs via `scripts/run_simmersmith_mcp.py` as a stdio process, gated
by `StaticBearerTokenVerifier` (one shared token), and scoped to a
single user via `_settings().local_user_id`. That
shape supports the internal Codex AI-provider routing path it was
built for, but it cannot be consumed by Claude.ai.

This milestone makes the MCP a real public surface: hosted at
`https://simmersmith.fly.dev/mcp`, gated by OAuth 2.1 + PKCE, and
scoped per-user so any Claude.ai user can sign in with Apple or
Google through SimmerSmith and drive *their own* household from a
Claude conversation. Done well, the MCP becomes a unique-in-category
capability — "use SimmerSmith from Claude" is the kind of feature
that doesn't fit into a screenshot on the App Store page but does
fit into a launch story.

## Goal

A new Claude.ai user can:

1. In Claude.ai Settings → Connectors, add a custom MCP server with
   URL `https://simmersmith.fly.dev/mcp`.
2. Hit "Connect" and get redirected to a SimmerSmith approval page.
   If not already signed in, sign in with Apple or Google through
   the existing flow.
3. Approve the connection. Claude.ai receives an access token and
   uses it on every MCP call.
4. From a Claude conversation, say "plan this week's dinners around
   chicken thighs and ground beef" and watch
   `generate_week_plan` execute against the right household — the
   iOS app reflects the new week on next refresh.
5. The same connection works from Claude Desktop and from a Claude
   Code session pointed at the same URL.

## Scope

In:
- OAuth 2.1 authorization-server endpoints mounted on the existing
  FastAPI app: `/.well-known/oauth-authorization-server` metadata,
  `/oauth/authorize` redirect, `/oauth/token` exchange, optional
  `/oauth/register` Dynamic Client Registration (RFC 7591).
- A SimmerSmith "Authorize Claude.ai" HTML page that reuses the
  existing Apple/Google sign-in endpoints to authenticate the user
  before issuing an authorization code.
- Per-request user scoping inside `app/mcp/*.py`: every
  `@mcp.tool` function that today reads `_settings().local_user_id`
  is rewritten to read `request.state.user_id` (set by the new
  token verifier).
- `POST /mcp` mounted on the existing FastAPI app using the MCP
  Streamable HTTP transport. `app/mcp/__init__.py` already
  constructs `FastMCP(... streamable_http_path=args.path)` for the
  Codex HTTP bridge case — the same configuration is the basis for
  the FastAPI mount. Exact mounting API resolved during
  implementation (likely either `FastMCP.streamable_http_app()` or
  composing the ASGI router directly).
- A new `JWTTokenVerifier(TokenVerifier)` replacing
  `StaticBearerTokenVerifier`. Validates JWTs signed by the
  existing `SIMMERSMITH_JWT_SECRET`, returns an `AccessToken` whose
  `client_id` carries the `user_id`.
- Documentation: a "Connect SimmerSmith to Claude" user-facing
  section + an "MCP auth flow" section in `app/mcp/CLAUDE.md` (or
  AGENTS.md) for future agents.

Out:
- Refresh-token rotation. Access tokens are 30-day JWTs; rotation
  is a hardening pass.
- Per-tool scope strings (`mcp:read` vs `mcp:mutate`). Every
  connected client gets the full tool surface for now.
- Client-credentials grant. This is an end-user-app flow; only
  authorization-code + PKCE is supported.
- Active rate limiting beyond existing FastAPI middleware. The
  underlying gates (M5 freemium machinery + admin cost rates)
  already cap the real cost of tool calls.
- A SimmerSmith Settings UI for "Connected Claude clients". UX
  nicety, not load-bearing for shipping.
- Token revocation API. Revocation is "rotate the JWT secret" — a
  sledgehammer that's acceptable at our scale.

## Architecture

```
                     Claude.ai user
                          │
       (1) Discover: GET /.well-known/oauth-authorization-server
                          │
                          ▼
                  +─────────────────────+
                  | FastAPI on Fly      |
                  |                     |
        +─────────| /oauth/* + /mcp     |─────────+
        │         +─────────────────────+
        │                          │
   (2) Apple/Google sign-in     (4) Tool calls with
   issues SimmerSmith              JWT bearer token
   session JWT                  →  resolved to user_id
        │                          │
        ▼                          ▼
   /api/auth/{apple,google}    app/mcp/<domain>.py
   (existing)                   @mcp.tool — now reads
                               user_id from auth_context
```

### Library choice

Use `authlib`'s `AuthorizationServer` for the OAuth 2.1 endpoints.
Well-maintained Python OAuth library; supports OAuth 2.1 +
authorization-code + PKCE + DCR. Alternatives considered:
`fastapi-oauth2` (too thin — no DCR), rolling custom (rejected
during planning). If `authlib` proves a poor fit for Claude.ai's
specific MCP-client flow on day one, fall back to a thin custom
implementation matching exactly what Claude.ai sends. The day-one
test (step 1 of Sequencing below) is designed to catch this.

### Endpoints

- `GET /.well-known/oauth-authorization-server` — standards
  metadata fetched by Claude.ai on first add-server attempt. Lists
  the four endpoints below, supported grant types
  (`authorization_code`), PKCE algorithms (S256).
- `POST /oauth/register` — Dynamic Client Registration. Returns a
  fresh `client_id`; SimmerSmith treats Claude.ai as a public
  client (no `client_secret`, PKCE required). Row persisted in
  `oauth_clients`.
- `GET /oauth/authorize` — renders the SimmerSmith-themed approval
  page. If the user lacks the existing SimmerSmith session
  cookie, redirect to `/oauth/sign-in?continue=<original-url>`,
  which renders Apple/Google buttons and POSTs to the existing
  `/api/auth/apple` / `/api/auth/google`. On consent, issue a
  one-time authorization code bound to (`client_id`, `user_id`,
  PKCE challenge, expiry).
- `POST /oauth/token` — exchanges the auth code for a 30-day
  JWT access token. `sub = user_id`, `aud = "mcp"`, signed with
  the existing `SIMMERSMITH_JWT_SECRET`.
- `POST /mcp` — the MCP Streamable HTTP transport entry point.
  Authentication runs in `JWTTokenVerifier`; the verifier sets
  `request.state.user_id`. Tool dispatch is unchanged.

### Data model

One new table:

```python
class OAuthClient(Base):
    client_id: str            # primary key (UUID)
    client_secret_hash: str | None  # null for public clients
    client_name: str          # "Claude.ai" or whatever DCR sent
    redirect_uris_json: str   # JSON array, validated on /authorize
    created_at: datetime
    last_used_at: datetime | None
```

Authorization codes are short-lived (60s) and stored in-memory
keyed by code. If a Fly machine restart loses one, the user retries
— not worth a DB write.

Access tokens are stateless JWTs; no `oauth_tokens` table.
Revocation is "rotate the JWT secret" (admin portal can expose this
as a button later).

### User-scoping refactor

Mechanical replacement across `app/mcp/*.py`. Five domain files
(`assistant.py`, `weeks.py`, `recipes.py`, `ingredients.py`,
`profile.py`) plus `_helpers.py`. Replace every
`_settings().local_user_id` with a new
`_current_user_id() -> str` helper that:

- Pulls from `request.state.user_id` when the MCP request comes in
  via HTTP (the OAuth path).
- Falls back to `_settings().local_user_id` when the request is
  stdio (the existing internal-Codex path).

This keeps the stdio path working untouched so the internal AI
provider routing layer doesn't regress mid-milestone.

### Sign-in bridge

The approval page (`/oauth/authorize`) needs the user authenticated
as a SimmerSmith user before issuing a code. If the request lacks
the SimmerSmith session cookie:

1. Redirect to `/oauth/sign-in?continue=<original>` — a server-
   rendered HTML page with Apple + Google buttons.
2. Buttons POST the identity token to the existing
   `/api/auth/apple` / `/api/auth/google` endpoints (no client
   changes needed there).
3. On success, set the existing SimmerSmith session cookie and
   redirect back to `/oauth/authorize` to render the approval
   prompt.

The approval page itself shows: "Claude.ai wants to access your
SimmerSmith household. It will be able to view and modify your
meal plans, recipes, and shopping lists." with Allow / Deny.

## Acceptance criteria

Backend:
- [ ] `GET /.well-known/oauth-authorization-server` returns a valid
      metadata document Claude.ai accepts.
- [ ] `POST /oauth/register` (DCR) issues a client_id; row
      persists in `oauth_clients`.
- [ ] Authorization-code flow with PKCE end-to-end: discover →
      register → authorize (with sign-in) → exchange code for
      token. Verifiable via `curl` + a manual browser step.
- [ ] JWT access tokens decode correctly; `JWTTokenVerifier`
      rejects expired tokens and wrong-`aud` tokens.
- [ ] Every `@mcp.tool` reads `user_id` from request context;
      unset `SIMMERSMITH_LOCAL_USER_ID` no longer breaks tool
      calls when an authed user is present.
- [ ] Existing 351-test pytest suite passes; ~10 new tests added
      covering each OAuth endpoint + the verifier + cross-user
      isolation.
- [ ] Stdio MCP via `scripts/run_simmersmith_mcp.py` still works
      unchanged so the existing internal Codex AI provider routing
      keeps functioning.

End-to-end:
- [ ] Adding `https://simmersmith.fly.dev/mcp` to Claude.ai
      triggers the OAuth flow, signs Taylor in, lands back in
      Claude.ai with the connection green.
- [ ] `assistant_list_threads` from Claude.ai returns Taylor's
      threads (not anyone else's).
- [ ] `generate_week_plan` from Claude.ai generates a week against
      Taylor's household; the iOS app shows the same week on next
      refresh.
- [ ] Adding the same MCP server from a different Apple ID returns
      that user's data, not Taylor's.
- [ ] Claude Desktop with the same config behaves identically to
      Claude.ai.

## Sequencing

Each step leaves the app in a working state. The stdio path stays
intact throughout.

1. **OAuth metadata + DCR scaffolding** (~1 session). Stand up
   `/.well-known/oauth-authorization-server` and `/oauth/register`.
   Verify Claude.ai discovers the server cleanly before any auth
   code is involved. This is the day-one library-fit test.
2. **Authorize page + sign-in bridge** (~1 session). Render the
   approval page; wire the Apple/Google sign-in detour; issue
   auth codes. Manual UAT in a browser.
3. **Token endpoint + JWT issuance** (~0.5 session). PKCE-verified
   code-to-token exchange.
4. **MCP Streamable HTTP mount + JWT verifier** (~1 session). Mount
   `/mcp` on the FastAPI app, swap the verifier, validate that
   stdio + HTTP paths coexist behind a small dispatch helper.
5. **User-scoping refactor in `app/mcp/*.py`** (~1 session). Five
   domain files, mechanical replacement. Add a cross-user isolation
   smoke test that drives each domain's tools as user A and user B
   and asserts no cross-pollination.
6. **End-to-end Claude.ai validation** (~1 session). Add the
   server to Claude.ai, drive each domain's tools, fix the rough
   edges that only show up with a real MCP client (payload size,
   timeouts, etc.).
7. **Documentation + ship** (~0.5 session). User-facing
   "Connect to Claude" guide + agent-facing `app/mcp/CLAUDE.md`
   update with the auth-flow diagram from this spec.

Total: ~5–6 sessions.

## Risks

- **Claude.ai conformance.** Their MCP-client OAuth flow has
  specific expectations that aren't fully documented. Step 1's
  day-one test (does Claude.ai accept the metadata doc?) is
  designed to surface this before deeper code lands.
- **PKCE-only public-client config.** Claude.ai is a public
  client; we cannot rely on a `client_secret`. `authlib` supports
  PKCE but it's easy to misconfigure. Explicit test in step 3.
- **User-scoping bugs.** The swap from "always the local user" to
  "user from token" is exactly the bug class where the *wrong*
  user's data leaks. The refactor is mechanical, but step 5's
  cross-user isolation test must be specific: a pytest fixture
  that creates two users, signs each in, calls each domain's
  tools as each user, and asserts no leakage.
- **Stateless tokens, no revocation.** If a Claude.ai access
  token leaks, "rotate the JWT secret" is the only response. The
  blast radius is bounded by the 30-day TTL.
- **Tool-call cost.** A Claude.ai user driving `generate_week_plan`
  / `rebalance_day` burns real OpenAI/Anthropic tokens against
  SimmerSmith's account. The M5 freemium gate (built but dark)
  contains this, but flipping it on becomes more urgent once this
  milestone ships. Worth coordinating with the M5 activation
  decision.

## Out of scope (parked)

- Per-tool scopes (`mcp:read`, `mcp:mutate`).
- Refresh-token rotation.
- Revocation API.
- A "Connected apps" Settings UI listing which Claude clients have
  access.
- Native iOS UI to launch the Claude-side flow.
- A static-token install path for power users — they can extract
  a token from the admin portal and point a Claude Code session
  at the same `/mcp` endpoint with a manual `Authorization`
  header. Not first-class UX, but workable.
