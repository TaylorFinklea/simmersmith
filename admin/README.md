# SimmerSmith Admin

SvelteKit admin portal for SimmerSmith. Deploys to Cloudflare
Workers behind Cloudflare Access at `admin.simmersmith.app`.

See [`CLAUDE.md`](./CLAUDE.md) for architecture, commands, and the
one-time Cloudflare click-ops checklist.

## Quick start

```bash
npm install
cp .env.example .env.local   # paste the bearer token from `flyctl secrets list`
npm run dev                  # http://localhost:5273
```

## Pages (v1)

- `/` — Usage dashboard (totals + per-user breakdown for the
  current or chosen month).
- `/users` — User list with this-month total + subscription status.
- `/settings` — Editable free-tier limits, default AI models,
  trial-mode toggle.

## Deploy

`git push origin main` → Cloudflare Workers build automatically.
