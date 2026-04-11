# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-10

Major infrastructure sprint: stack pivot, deployment, multi-user scoping, and isolation tests — all in one session.

**What was done:**
- Reverted the earlier multi-user isolation Phase 0-2 work (Supabase/SQLite complexity)
- Pivoted to Fly.io + Postgres + Apple/Google Sign-In stack
- Built complete auth system: Apple/Google identity token verification (JWKS), session JWTs, legacy bearer fallback
- Added `users` table, auth API routes (POST /api/auth/apple, /api/auth/google, GET /api/auth/me)
- Added `user_id` to 8 user-owned root tables via Alembic migration (dialect-aware: Postgres + SQLite)
- Fixed migration 0007 (SQLite-only `INSERT OR IGNORE` + `randomblob` → portable SQL)
- Scoped entire service layer (~25 files): every user-owned query now filters by user_id
- API routes inject `CurrentUser` from JWT auth dependency
- MCP tools use `local_user_id` shim (separate scoping phase)
- Deployed to Fly.io (simmersmith.fly.dev) with Fly Postgres
- Fixed `postgres://` → `postgresql://` scheme translation for Fly/Heroku compat
- Added 7 cross-user isolation tests proving user A can't see user B's data
- Total test count: 65 (all passing)

## Production

- **URL**: https://simmersmith.fly.dev
- **Infrastructure**: Fly.io (DFW, shared-cpu-1x, 256MB, 2 machines, auto-stop) + Fly Postgres 17
- **API Token**: `299dab5eca45445da9270e8d1f101d1b` (legacy bearer for dev/MCP)

## Build Status

- Backend linter: `.venv/bin/ruff check .` — **passed**
- Backend tests (SQLite): `.venv/bin/pytest -q` — **65/65 passed** (58 existing + 7 isolation)
- Postgres smoke test: all 14 migrations + seed — **passed**
- Production deployment: https://simmersmith.fly.dev/api/health — **OK**
- iOS: `xcodebuild ... build` — **BUILD SUCCEEDED** (last verified 2026-04-09)
- SimmerSmithKit: `swift test` — 26 tests passing (last verified 2026-04-09)

## Blockers

- **iOS Sign in with Apple/Google not yet wired** — auth endpoints are built and deployed, but the iOS app needs to send identity tokens to them
- **MCP per-user scoping** — MCP tools use local_user_id shim, not real per-user tokens
- TestFlight upload blocked on ASC credentials

## Recent Commits

```
ea2ae8c test: add cross-user isolation tests
a8f1bb8 refactor: scope all service queries by user_id
1ac9a15 fix: handle DATABASE_URL scheme for Fly.io Postgres
63560ec fix: make migrations compatible with Postgres
dddbe46 deps: add psycopg2-binary for Postgres driver
ed5b61a docs: add Fly.io deployment config and document stack pivot
b98caa2 feat: pivot to Fly.io + Postgres + Apple/Google Auth
```
