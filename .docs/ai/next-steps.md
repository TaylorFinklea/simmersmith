# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate

- [ ] Design multi-user data isolation strategy — this is the biggest M0 blocker. Options: (a) add `user_id` FK to every table and filter at service layer, (b) use Postgres row-level security (RLS) on Supabase, (c) hybrid. Read `.docs/ai/decisions.md` for prior direction.
- [ ] Set up Supabase project — Postgres instance, enable auth. Pull connection string into a local `.env.local` (don't commit).
- [ ] Smoke-test SQLAlchemy on Postgres — run `SIMMERSMITH_DATABASE_URL_OVERRIDE=postgresql://...` against an empty Supabase DB, verify migrations run, catalog seed works.

## Soon

- [ ] Apply `user_id` schema changes (Alembic migration + model updates + every service query site).
- [ ] Supabase Auth — JWT validation middleware in FastAPI, replace bearer-token dependency for cloud mode.
- [ ] iOS: Sign in with Apple flow wired to Supabase Auth.
- [ ] Unblock TestFlight upload — repair ASC credentials or switch to ASC API key flow.

## Deferred

- [ ] Decompose `IngredientsView.swift` (975 lines) — Sonnet backlog
- [ ] Decompose `AppState.swift` (1,119 lines) — Sonnet backlog (now has postClearRefreshTask etc., good time to split)
- [ ] Guided onboarding AI preference interview — M1
- [ ] AI-driven week planning wizard — M1
- [ ] Grocery pricing hybrid model — M2
