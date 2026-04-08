# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-07

- Completed backend code quality audit (services + API routes) — found 30 issues
- Fixed 4 critical bugs: Postgres connect_args, database_url override, grocery quantity_text, presenter None crash
- Fixed 3 security issues: SSRF on recipe import, assistant error leakage, health endpoint AI config exposure
- Added startup warning when API token is empty
- Fixed recipe ID slug collision (slugify → UUID)
- Resolved all 7 pre-existing ruff failures — repo-wide lint is now green
- Split mcp_server.py (862 lines) into app/mcp/ package (7 modules)
- Recipe import split completed by another agent in parallel

## Build Status

- Backend: `.venv/bin/ruff check .` — all checks passed
- Backend: `.venv/bin/pytest -q` — 58 tests passing
- iOS: not re-verified this session (no iOS changes)
- Docker: `docker compose config -q` — passing

## Blockers

- Grocery full-table scans still load ALL recipes/ingredients globally (needs scoped queries before multi-user)
- TestFlight upload still blocked on ASC credentials
- Supabase project not yet created
- Zero multi-user isolation across every service and route (deepest M0 blocker)
