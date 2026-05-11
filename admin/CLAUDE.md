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

## v1 scope

- `/` — Usage dashboard (totals + per-user breakdown for the current
  or chosen month).
- `/users` — User list with monthly usage + subscription status.
- `/settings` — Editable free-tier limits, default AI models, and
  trial-mode toggle. Edits PATCH `/api/admin/settings` on the
  backend; the values land in the `server_settings` Postgres table.

No write actions on the usage or users page yet — both are
read-only.

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

- `/api/admin/usage` — month-aggregated `usage_counters` rows.
- `/api/admin/users` — `users` table + the user's
  `usage_counters` total for the current month.
- `/api/admin/settings` — read/write the `server_settings` table.

The schema migration for `server_settings` is
`alembic/versions/20260511_0039_server_settings.py`. Defaults are
hard-coded in `app/services/server_settings.py`; the table only
holds overrides.
