# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-06

- Split `app/services/ingredient_catalog.py` into an `ingredient_catalog/` package with extracted `search.py`, `product_rewrite.py`, and `variation.py` modules while keeping the existing import surface at `app.services.ingredient_catalog`
- Split `app/services/recipe_import.py` into a `recipe_import/` package with extracted `parser.py` and `ingredient_normalizer.py` modules while keeping the existing import surface at `app.services.recipe_import`
- Kept recipe import backward compatibility for tests and callers by re-exporting `urllib_request` from the package entrypoint
- Marked both Sonnet backlog items complete in `.docs/ai/roadmap.md`

## Build Status

- Backend: `.venv/bin/pytest -v` — 57 tests passing
- Backend slice: `.venv/bin/pytest -v tests/test_ingredient_ingest.py tests/test_grocery.py tests/test_api.py` — 48 tests passing
- Lint (changed slice): `.venv/bin/ruff check app/services/ingredient_catalog app/api/ingredients.py app/services/ingredient_ingest.py app/services/drafts.py app/services/grocery.py tests/test_ingredient_ingest.py tests/test_grocery.py tests/test_api.py` — passing
- Lint (recipe import slice): `.venv/bin/ruff check app/services/recipe_import app/api/recipes.py tests/test_recipe_import.py tests/test_api.py` — passing
- Backend slice: `.venv/bin/pytest -v tests/test_recipe_import.py tests/test_api.py` — 46 tests passing
- Repo-wide lint: `.venv/bin/ruff check .` — still failing on pre-existing unrelated issues in `app/api/assistant.py`, `app/mcp_server.py`, `app/services/nutrition.py`, and `scripts/rewrite_product_like_catalog.py`
- Docker: `docker compose config -q` — passing

## Blockers

- Repo-wide lint is not green because of pre-existing unrelated issues in assistant, MCP server, nutrition, and the product-like rewrite script
- TestFlight upload blocked on local App Store Connect credentials
- Product-like catalog rewrite script exists but not yet reviewed/applied against live DB
- Supabase project not yet created
