# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-06

- Split `app/services/ingredient_catalog.py` into an `ingredient_catalog/` package with extracted `search.py`, `product_rewrite.py`, and `variation.py` modules while keeping the existing import surface at `app.services.ingredient_catalog`
- Kept resolution/default backfill logic in the package entrypoint so callers and tests did not need import changes
- Marked the Sonnet backlog item complete in `.docs/ai/roadmap.md`

## Build Status

- Backend: `.venv/bin/pytest -v` — 57 tests passing
- Backend slice: `.venv/bin/pytest -v tests/test_ingredient_ingest.py tests/test_grocery.py tests/test_api.py` — 48 tests passing
- Lint (changed slice): `.venv/bin/ruff check app/services/ingredient_catalog app/api/ingredients.py app/services/ingredient_ingest.py app/services/drafts.py app/services/grocery.py tests/test_ingredient_ingest.py tests/test_grocery.py tests/test_api.py` — passing
- Repo-wide lint: `.venv/bin/ruff check .` — still failing on pre-existing unrelated issues in `app/api/assistant.py`, `app/mcp_server.py`, `app/services/nutrition.py`, and `scripts/rewrite_product_like_catalog.py`
- Docker: `docker compose config -q` — passing

## Blockers

- Repo-wide lint is not green because of pre-existing unrelated issues in assistant, MCP server, nutrition, and the product-like rewrite script
- TestFlight upload blocked on local App Store Connect credentials
- Product-like catalog rewrite script exists but not yet reviewed/applied against live DB
- Supabase project not yet created
