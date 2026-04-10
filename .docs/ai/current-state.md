# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-10

Stack pivot + Postgres deployment blocker fixed. The app now runs on Postgres.

**What was done:**
- Reverted the earlier multi-user isolation Phase 0-2 work (Supabase Auth, dual-database, two-tier catalog) — replaced with a simpler stack
- Pivoted to Fly.io + Postgres + Apple/Google Sign-In (`pyjwt[crypto]` + PyJWKClient)
- Added `users` table, `app/auth.py` rewrite (Apple/Google JWKS verification + session JWT + legacy bearer), auth routes (`POST /api/auth/apple`, `/api/auth/google`, `GET /api/auth/me`)
- Added `user_id` to 8 user-owned root tables (weeks, recipes, assistant_threads, ai_runs, profile_settings, staples, preference_signals, ingredient_preferences)
- Catalog tables (base_ingredients, etc.) left untouched — shared reference data
- Service-layer shims added to all write paths (`user_id=get_settings().local_user_id`)
- Added `fly.toml`, updated `Dockerfile` (removed sqlite3), updated `docker-compose.yml` (Postgres service)
- Added `psycopg2-binary` dependency
- Fixed migration 0007 (`INSERT OR IGNORE` + `randomblob` → portable SQL)
- Fixed migration 0014 (dialect detection: ALTER TABLE on Postgres, manual recreation on SQLite)
- **Postgres smoke test passed**: all 14 migrations + seed + health endpoint verified on local Postgres 16

## Build Status

- Backend linter: `.venv/bin/ruff check .` — **passed**
- Backend tests (SQLite): `.venv/bin/pytest -q` — **58/58 passed**
- Postgres smoke test: all migrations + seed + API endpoints — **passed**
- iOS: `xcodebuild ... build` — **BUILD SUCCEEDED** (last verified 2026-04-09)
- SimmerSmithKit: `swift test` — 26 tests passing (last verified 2026-04-09)

## Blockers

- **Fly.io deployment not yet done** — local Postgres smoke test passes, ready for `fly apps create` + Neon provisioning + `fly deploy`
- **Apple/Google Sign-In not yet tested with real identity tokens** — endpoints are built but need real iOS integration
- **Service-layer scoping not yet done** — all queries are still unscoped (return all rows). user_id columns exist but WHERE clauses not added yet. This is the next big task.
- TestFlight upload blocked on ASC credentials

## Recent Commits

```
63560ec fix: make migrations compatible with Postgres
dddbe46 deps: add psycopg2-binary for Postgres driver
ed5b61a docs: add Fly.io deployment config and document stack pivot
b98caa2 feat: pivot to Fly.io + Postgres + Apple/Google Auth
```
