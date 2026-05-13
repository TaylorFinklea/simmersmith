# SimmerSmith Admin — Claude Code Instructions

## What this is

SvelteKit admin portal for SimmerSmith, deployed as a Cloudflare
Worker (with Static Assets) at `admin.simmersmith.app`. Separate
origin from the iOS API (`simmersmith.fly.dev`) so the consumer app
never has admin code on the wire. Behind Cloudflare Access
(email-allowlist) — only Taylor's address can reach the hostname.

The Worker is stateless. Every page fetches data from the FastAPI
backend on Fly using a bearer token loaded from a Worker secret. The
token never crosses to the browser; all data lookups happen in
`+page.server.ts` server-load functions.

## Scope

- `/` — Usage dashboard (totals + per-user breakdown for the current
  or chosen month, with an estimated-spend column).
- `/users` — User list with monthly usage + subscription status +
  estimated spend. Rows link to `/users/[id]`.
- `/users/[id]` — Per-user diagnostic page (build 95): profile,
  subscription detail, two-month usage breakdown with cost, recipe /
  week / push device counts. Operator actions: **grant Pro** (writes
  an admin-source `subscriptions` row with `apple_original_transaction_id=NULL`)
  and **revoke** (sets `status="revoked"`). Admin grants survive
  until an Apple webhook replaces them.
- `/settings` — Editable free-tier limits, default AI models, the
  trial-mode toggle, and per-action **usage cost rates** powering the
  spend estimates. Edits PATCH `/api/admin/settings`; values land in
  the `server_settings` Postgres table.

## Stack

| Layer | Technology |
|-------|-----------|
| Framework | SvelteKit 2 (Svelte 5 runes) |
| Adapter | `@sveltejs/adapter-cloudflare` → Cloudflare Workers (Static Assets) |
| Styling | Tailwind v4 (`@tailwindcss/vite`) |
| Auth (outer) | Cloudflare Access (email allowlist) |
| Auth (inner) | `Authorization: Bearer <SIMMERSMITH_ADMIN_TOKEN>` → matches `SIMMERSMITH_API_TOKEN` on Fly |
| Backend | FastAPI (`simmersmith.fly.dev`) `/api/admin/*` endpoints |

## Commands

```bash
npm install
npm run dev                # vite on :5273
npm run build              # → .svelte-kit/cloudflare
npm run check              # svelte-check
```

Deploys are Git-connected. Pushing to `main` triggers a Cloudflare
Workers build automatically. No `npm run deploy` — `git push` is the
deploy path.

## Env vars / secrets

```
SIMMERSMITH_API_BASE       = https://simmersmith.fly.dev   (Worker var, baked in)
SIMMERSMITH_ADMIN_TOKEN    = <same value as SIMMERSMITH_API_TOKEN on Fly>  (Worker secret)
```

Local dev: copy `.env.example` → `.env.local` and fill in the token.
The local dev server reads from `process.env` via the `platform`
shim wired by `@sveltejs/adapter-cloudflare`.

Production: secret is set once via `wrangler secret put
SIMMERSMITH_ADMIN_TOKEN`. The dashboard never shows the value back.

## Auth flow

1. User hits `https://admin.simmersmith.app/`.
2. Cloudflare Access challenges (one-time PIN to the user's email,
   or Google/Apple if configured).
3. Once authenticated against the Access policy, Cloudflare proxies
   the request to the Worker.
4. The SvelteKit server-side `load` function in `+page.server.ts`
   calls `simmersmith.fly.dev/api/admin/*` with the
   `SIMMERSMITH_ADMIN_TOKEN` bearer header.
5. FastAPI's `require_admin_bearer` dependency validates the token
   against `SIMMERSMITH_API_TOKEN` and returns data.
6. SvelteKit renders the page server-side, ships HTML to the
   browser. The admin token never leaves the Worker.

## Cloudflare Workers config (Git-connected)

Worker connected to the GitHub repo. Build configuration in the
dashboard:

- **Root directory:** `admin`
- **Build command:** `npm install && npm run build`
- **Deploy command:** `npx wrangler deploy`
- **Production branch:** `main`

`wrangler.toml` defines the Worker name, entry point, the Static
Assets binding, and the public `SIMMERSMITH_API_BASE` var. The
adapter writes the build to `.svelte-kit/cloudflare/`.

## One-time setup (click-ops)

These steps were performed manually in the Cloudflare dashboard.
Record them here so they can be re-applied if the Worker is rebuilt:

1. **Worker** → Create application → Connect to Git → select this
   repo → root dir `admin/`.
2. **Custom domain** → `admin.simmersmith.app` (assumes the apex
   `simmersmith.app` is in Cloudflare).
3. **Worker secrets** → `SIMMERSMITH_ADMIN_TOKEN` = (paste the value
   of `SIMMERSMITH_API_TOKEN` from `flyctl secrets list`).
4. **Cloudflare Access** → Applications → Add an application →
   Self-hosted →
   - Application name: SimmerSmith Admin
   - Subdomain: `admin.simmersmith.app`
   - Identity provider: One-Time PIN (or Google/Apple if you set
     them up for joji and want to reuse).
   - Policy → Allow → Include → Emails → `taylor.finklea@gmail.com`.
5. **Fly** → confirm `SIMMERSMITH_API_TOKEN` is set
   (`flyctl secrets list -a simmersmith`). If not:
   `flyctl secrets set SIMMERSMITH_API_TOKEN=<value> -a simmersmith`.

## Where the data comes from

- `/api/admin/usage` — month-aggregated `usage_counters` rows + the
  cost estimate (`usage_cost_usd × counter` per action).
- `/api/admin/users` — `users` table + the user's `usage_counters`
  total + cost estimate + subscription source (`apple` vs `admin`).
- `/api/admin/users/{user_id}` — single-user snapshot for the detail
  page: profile, subscription, two-month usage with costs, inventory
  counts.
- `/api/admin/users/{user_id}/subscription` — POST `{action,...}` to
  grant Pro or revoke. See `app/api/admin.py` for the body schema.
- `/api/admin/settings` — read/write the `server_settings` table
  including the editable per-action cost rates
  (`KEY_USAGE_COST_USD`).

Schema migrations: `server_settings` ships in
`alembic/versions/20260511_0039_server_settings.py`; the build 95
subscription columns (nullable Apple txn id + `admin_note`) ship in
`20260512_0040_subscriptions_admin_grant.py`. Defaults for tunable
values are hard-coded in `app/services/server_settings.py`; the
table only stores overrides.
