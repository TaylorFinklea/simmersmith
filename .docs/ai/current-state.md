# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-09

M0 audit work remains complete, and the remaining Sonnet refactor backlog is now finished. The repo has shifted from cleanup/refactoring work to the remaining infrastructure-heavy M0 items.

**Backlog work finished this session:**
- Decomposed `SimmerSmith/SimmerSmith/Features/Ingredients/IngredientsView.swift` into focused subviews:
  - `IngredientCatalogList.swift`
  - `IngredientVariationManagementSection.swift`
  - `BaseIngredientMergeSheet.swift`
- Split `SimmerSmith/SimmerSmith/App/AppState.swift` into domain-focused modules:
  - `AppState+AI.swift`
  - `AppState+Assistant.swift`
  - `AppState+Ingredients.swift`
  - `AppState+Recipes.swift`
  - `AppState+Weeks.swift`
- Regenerated `SimmerSmith.xcodeproj` after both iOS refactors.

**Backlog status:**
- Haiku backlog: complete
- Sonnet backlog: complete
- Remaining roadmap work is now infrastructure/product design only (Supabase, multi-user isolation, auth, TestFlight, M1+ design work).

## Build Status

- Backend: last known earlier on 2026-04-09 — `.venv/bin/ruff check .` passed
- Backend: last known earlier on 2026-04-09 — `.venv/bin/pytest -q` passed (58 tests)
- iOS: `xcodebuild ... build` — **BUILD SUCCEEDED**
- SimmerSmithKit: `swift test` — 26 tests passing
- Docker: not re-verified this session (no infra changes)

## Blockers

- **Multi-user isolation is the biggest remaining M0 blocker**. Every service function and route query is unscoped. Adding `user_id` to all tables will require a migration + touching every query site.
- Supabase project not yet created (external config step).
- TestFlight upload blocked on ASC credentials.
- Database abstraction not yet validated on real Postgres (SQLAlchemy + config path is ready, but no smoke test run).

## M0 Progress

18 of 22 M0 items complete. Remaining:
- [ ] Database abstraction — validate SQLAlchemy on Postgres, dialect-aware migrations
- [ ] Supabase project setup — Postgres instance, auth configuration
- [ ] Multi-user data isolation — `user_id` on all tables + auth middleware
- [ ] Supabase Auth integration — JWT validation in FastAPI, iOS auth flow
- [ ] TestFlight pipeline — unblock upload

The remaining work is all **big-ticket infrastructure** that M0 was designed to set up. Audit, bug fixes, security hardening, and the shared refactor backlog are complete.
