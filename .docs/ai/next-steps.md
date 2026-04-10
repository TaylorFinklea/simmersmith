# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate

- [ ] Fix Alembic revision `20260323_0007_recipe_taxonomy_and_scaling.py` so it runs on Postgres as well as SQLite. The current seed SQL uses `INSERT OR IGNORE` and `randomblob(...)`, which fails on Postgres during local startup.
- [ ] Re-run the local Postgres smoke test from a clean database: `docker compose up -d postgres`, start `uvicorn` with `SIMMERSMITH_DATABASE_URL=postgresql://...`, verify all 14 migrations apply, and confirm `GET /api/health` returns `{"status":"ok"}`.
- [ ] Only after the local Postgres smoke test passes, proceed with Fly.io app creation, Neon provisioning, Fly secrets, and `fly deploy`.
- [ ] Design multi-user data isolation strategy — this is the biggest M0 blocker. Options: (a) add `user_id` FK to every table and filter at service layer, (b) use Postgres row-level security (RLS) on Supabase, (c) hybrid. Read `.docs/ai/decisions.md` for prior direction.
- [ ] Set up Supabase project — Postgres instance, enable auth. Pull connection string into a local `.env.local` (don't commit).
- [ ] Smoke-test SQLAlchemy on Postgres — run `SIMMERSMITH_DATABASE_URL_OVERRIDE=postgresql://...` against an empty Supabase DB, verify migrations run, catalog seed works.

## Soon

- [ ] Apply `user_id` schema changes (Alembic migration + model updates + every service query site).
- [ ] Supabase Auth — JWT validation middleware in FastAPI, replace bearer-token dependency for cloud mode.
- [ ] iOS: Sign in with Apple flow wired to Supabase Auth.
- [ ] Unblock TestFlight upload — repair ASC credentials or switch to ASC API key flow.

## Deferred

- [ ] Guided onboarding AI preference interview — M1
- [ ] AI-driven week planning wizard — M1
- [ ] Grocery pricing hybrid model — M2
