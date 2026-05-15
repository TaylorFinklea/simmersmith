# SimmerSmith — Agent Instructions

Project-specific guidance for any AI coding agent (Claude Code, Codex, Copilot, Gemini CLI, etc.). Shared agent behavior (shell discipline, commit/push defaults, OPENAI_API_KEY conventions) lives in `~/AGENTS.md`.

## Session Workflow

### Starting a session

Read these files before doing any work:
1. `.docs/ai/roadmap.md` — durable goals, milestones, Now/Next/Later
2. `.docs/ai/current-state.md` — last session summary, changed files, blockers, validation status

These docs are the source of truth for project state, not chat history.

Then inspect the repo state:
- `git status --short`
- `git log --oneline -5`
- the relevant code paths for the next task

### Ending a session

Before finishing, update:
1. `.docs/ai/current-state.md` — what you did, files changed, blockers, validation status
2. `.docs/ai/roadmap.md` — check off completed Now/Next items and add the exact next actions
3. `.docs/ai/decisions.md` — append an ADR entry if a non-obvious decision or workflow change was made

See `.docs/ai/handoff-template.md` for the format.

## Project Overview

SimmerSmith is an AI-first meal planning app targeting the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. iOS is the primary client, FastAPI is the canonical backend, deployed on Fly.io with Postgres.

## Stack

| Layer | Technology |
|-------|-----------|
| Backend | Python 3.12+ / FastAPI / SQLAlchemy 2.0 |
| Database | Postgres (Neon free tier or Fly Postgres) |
| Migrations | Alembic (auto-run on startup) |
| iOS app | Swift 6.2 / SwiftUI / iOS 26+ / macOS 15+ |
| iOS package | SimmerSmithKit (SPM) |
| Hosting | Fly.io (Docker, shared-cpu-1x) |
| Auth | Apple Sign-In + Google Sign-In (OIDC) / legacy bearer for dev |
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
  auth.py              # Apple/Google auth + session JWT + legacy bearer
  api/                 # Route handlers (auth, profile, recipes, weeks, preferences, ingredients, exports, ai, assistant)
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
- **Postgres-only**: Neon free tier or Fly Postgres for production. SQLite used only in the test suite.
- **Auth**: Apple/Google Sign-In (OIDC identity tokens verified server-side via JWKS). Server issues session JWTs. Legacy bearer token kept for dev/MCP.
- **AI provider routing**: Auto-detects MCP (Codex server) → falls back to direct OpenAI/Anthropic APIs. Configurable timeout (default 120s).
- **Export boundary**: App queues export runs; host-side CLI reads queue and writes to macOS Reminders via Playwright/AppleScript.
- **Ingredient catalog**: 42KB+ in-memory cache with USDA FDC ingestion pipeline.
- **MCP surface**: 55 tools across `app/mcp/{assistant,weeks,recipes,ingredients,profile}.py` exposing all app domains for external AI agents. Hosted at `simmersmith.fly.dev/mcp` behind OAuth 2.1 + PKCE (build 97, M24); also accessible via stdio for internal Codex routing. Launch differentiator.

## Environment Variables

```
SIMMERSMITH_DATABASE_URL=postgresql://simmersmith:simmersmith@localhost:5432/simmersmith
SIMMERSMITH_JWT_SECRET=<random-256-bit-key>
SIMMERSMITH_APPLE_BUNDLE_ID=<ios-bundle-id>
SIMMERSMITH_GOOGLE_CLIENT_ID=<google-oauth-client-id>
SIMMERSMITH_API_TOKEN=<legacy-bearer-or-empty>
SIMMERSMITH_AI_MCP_ENABLED=true
SIMMERSMITH_AI_OPENAI_API_KEY=<optional>
SIMMERSMITH_AI_ANTHROPIC_API_KEY=<optional>
```

Production secrets are set via `fly secrets set`. Local dev uses `.env` or docker-compose defaults.

## Repository Guidance

- The web frontend is being removed. Do not add web frontend code.
- Use small, reviewable commits by default.
- Validate the changed slice before committing and record the result in `.docs/ai/current-state.md`.
- Preserve roadmap continuity: do not reorder the roadmap casually. Update the shared docs first if the plan changes.
