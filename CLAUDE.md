# SimmerSmith — Claude Code Instructions

## Session Workflow

### Starting a session

1. Read these files to understand the current project state:
   - `.docs/ai/roadmap.md` -- durable goals, milestones, constraints, non-goals
   - `.docs/ai/current-state.md` -- what happened last, blockers, changed files, validation status
   - `.docs/ai/next-steps.md` -- exact next actions
2. Check `git log --oneline -5` and `git status --short` to verify repo state matches the shared docs.
3. Only trust the codebase plus the shared `.docs/ai` files; do not use chat memory as project state.

## Ending a session

Before signing off, update these shared docs:
1. `.docs/ai/current-state.md` -- session summary, changed files, blockers, validation status
2. `.docs/ai/next-steps.md` -- remove completed items and add the exact next actions
3. `.docs/ai/decisions.md` -- append an ADR entry if any non-obvious architectural or workflow decision was made

See `.docs/ai/handoff-template.md` for the session-end format.

## Project Overview

SimmerSmith is an AI-first meal planning app targeting the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. iOS is the primary client, FastAPI + Supabase is the canonical backend, and self-hosting is a first-class option.

## Stack

| Layer | Technology |
|-------|-----------|
| Backend | Python 3.12+ / FastAPI / SQLAlchemy 2.0 |
| Database | Postgres (Supabase cloud) or SQLite (self-hosted) |
| Migrations | Alembic (auto-run on startup) |
| iOS app | Swift 6.2 / SwiftUI / iOS 26+ / macOS 15+ |
| iOS package | SimmerSmithKit (SPM) |
| Container | Docker Compose (Python 3.12-slim) |
| Auth | Supabase Auth (cloud) or bearer token (self-hosted) |
| AI | OpenAI / Anthropic / MCP (Codex server) — provider auto-detected |

## Build & Dev Commands

```bash
# Backend setup
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'

# Backend dev server
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8080 --reload

# iOS
xcodegen generate --spec SimmerSmith/project.yml
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO

# Docker (production-style)
docker compose up --build     # http://localhost:8080
```

## Verification

```bash
# Backend
.venv/bin/ruff check .
.venv/bin/pytest -v

# iOS
swift test --package-path SimmerSmithKit

# Docker
docker compose config -q
```

## Key Files

```
app/
  main.py              # FastAPI app, lifespan, SPA fallback routing
  config.py            # Pydantic Settings (.env support)
  db.py                # SQLAlchemy engine + session factory
  models.py            # ORM models (Profiles, Recipes, Weeks, Meals, Ingredients, etc.)
  schemas.py           # Pydantic request/response models
  auth.py              # Bearer token validation
  api/                 # Route handlers
    profile.py         # Profile settings & staples
    recipes.py         # Recipe CRUD & URL import
    weeks.py           # Week management, meals, approvals
    preferences.py     # Taste memory & meal scoring
    ingredients.py     # Ingredient catalog
    exports.py         # Apple Reminders export queue
    ai.py              # AI capabilities & provider negotiation
    assistant.py       # OpenAI Assistants thread management
  services/            # Business logic (drafts, grocery, pricing, AI, etc.)
SimmerSmith/
  project.yml          # xcodegen spec
  SimmerSmith/         # SwiftUI app source
SimmerSmithKit/
  Package.swift        # SPM definition
tests/
  conftest.py          # Pytest fixtures (TestClient, db isolation)
  test_api.py          # Integration tests (63KB)
```

## Architecture Patterns

- **AI-first**: AI is the primary interaction model. iOS is the primary client. FastAPI is canonical.
- **Dual database**: Postgres (Supabase cloud) for production, SQLite for self-hosted. SQLAlchemy abstracts the dialect.
- **Dual auth**: Supabase Auth (JWT) for cloud, bearer token for self-hosted. Middleware handles both.
- **AI provider routing**: Auto-detects MCP (Codex server) → falls back to direct OpenAI/Anthropic APIs. Configurable timeout (default 120s).
- **Export boundary**: App queues export runs; host-side CLI reads queue and writes to macOS Reminders via Playwright/AppleScript.
- **Ingredient catalog**: 42KB+ in-memory cache with USDA FDC ingestion pipeline.
- **MCP surface**: 47 tools exposing all app domains for external AI agents. Launch differentiator.

## Environment Variables

```
SIMMERSMITH_API_TOKEN=<bearer-token-or-empty>
SIMMERSMITH_DB_PATH=/path/to/meals.db
SIMMERSMITH_DATA_DIR=/path/to/data
SIMMERSMITH_AI_MCP_ENABLED=true
SIMMERSMITH_AI_OPENAI_API_KEY=<optional>
SIMMERSMITH_AI_ANTHROPIC_API_KEY=<optional>
```

Default DB location: `/Users/tfinklea/codex/meals/data/meals.db` (bind-mounted in Docker).

## Repository Guidance

- Keep the workflow aligned with `AGENTS.md`; assistant-specific behavior should not fork the shared repo state.
- Preserve roadmap continuity: do not reorder the roadmap casually. Update the shared docs first if the plan changes.
- Prefer concise implementation notes and explicit validation results.
- Do not push unless the user explicitly asks.
