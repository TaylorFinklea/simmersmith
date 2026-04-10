# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-10

Attempted the Fly.io + Neon deployment workflow, starting with the required local Postgres smoke test. The repo already had the Fly config and `psycopg2-binary` dependency in place, so no deployment code changes were needed.

**What was done this session:**
- Started a fresh local Postgres container with `docker compose up -d postgres`.
- Verified Postgres accepted connections on `localhost:5432`.
- Booted the API against local Postgres with `SIMMERSMITH_DATABASE_URL=postgresql://simmersmith:simmersmith@localhost:5432/simmersmith`.
- Confirmed the startup path reaches Alembic and begins applying migrations.
- Isolated the failure to Alembic revision `20260323_0007_recipe_taxonomy_and_scaling.py`, which uses SQLite-only SQL:
  - `INSERT OR IGNORE`
  - `lower(hex(randomblob(16)))`
- Confirmed the migration fails on Postgres before schema creation completes, leaving the database empty (`psql \dt` returned no relations).
- Stopped local Docker services with `docker compose down`.

**Deployment status:**
- Blocked locally before any Fly app creation, Fly secret changes, or Neon provisioning/usage.
- No remote infrastructure was modified this session.

## Build Status

- Backend: last known earlier on 2026-04-09 — `.venv/bin/ruff check .` passed
- Backend: last known earlier on 2026-04-09 — `.venv/bin/pytest -q` passed (58 tests)
- Backend Postgres smoke test on 2026-04-10 — **FAILED** during Alembic upgrade at revision `20260323_0007_recipe_taxonomy_and_scaling.py`
- iOS: `xcodebuild ... build` — **BUILD SUCCEEDED**
- SimmerSmithKit: `swift test` — 26 tests passing
- Docker: local Postgres container verified to start; compose stack shut down after investigation

## Blockers

- **Multi-user isolation is the biggest remaining M0 blocker**. Every service function and route query is unscoped. Adding `user_id` to all tables will require a migration + touching every query site.
- **Postgres deployment is currently blocked by Alembic revision `20260323_0007_recipe_taxonomy_and_scaling.py`.** The migration uses SQLite-specific SQL (`INSERT OR IGNORE`, `randomblob`) and rolls back on Postgres before any tables are created.
- Supabase project not yet created (external config step).
- TestFlight upload blocked on ASC credentials.
- Database abstraction not yet validated on real Postgres: the first local Postgres smoke test exposed the migration incompatibility above.

## M0 Progress

18 of 22 M0 items complete. Remaining:
- [ ] Database abstraction — validate SQLAlchemy on Postgres, dialect-aware migrations
- [ ] Supabase project setup — Postgres instance, auth configuration
- [ ] Multi-user data isolation — `user_id` on all tables + auth middleware
- [ ] Supabase Auth integration — JWT validation in FastAPI, iOS auth flow
- [ ] TestFlight pipeline — unblock upload

The remaining work is all **big-ticket infrastructure** that M0 was designed to set up. Audit, bug fixes, security hardening, and the shared refactor backlog are complete, but deployment cannot proceed until the Postgres-incompatible migration is fixed.
