# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-11

Built R1.1 (Sign in with Apple), R1.2 (AI week planner), verified R1.3 (grocery generation).

**What was done:**
- Sign in with Apple: new `SignInView`, `AuthTokenResponse` model, `signInWithApple` API + AppState methods, entitlements file, project.yml updated
- AI week planner: new `app/services/week_planner.py` (prompt construction + AI provider call + JSON parsing), new `POST /api/weeks/{id}/generate` endpoint, iOS `generateWeekPlan` API method, `generateWeekFromAI` AppState method, WeekView rewritten with AI planner sheet + empty state
- Set `SIMMERSMITH_APPLE_BUNDLE_ID=app.simmersmith.ios` on Fly
- Changed default OpenAI model to `gpt-5.4-mini`
- Fresh roadmap in `.docs/ai/roadmap.md` with R1-R3 milestone structure
- Deployed all changes to Fly.io

## Production

- **URL**: https://simmersmith.fly.dev
- **API Token**: `299dab5eca45445da9270e8d1f101d1b`
- **Apple Bundle ID**: set
- **AI Provider**: needs `SIMMERSMITH_AI_OPENAI_API_KEY` set via `fly secrets set`

## Build Status

- Backend: ruff ✅, pytest 65/65 ✅
- iOS: BUILD SUCCEEDED ✅
- Swift tests: 26/26 ✅
- Production: deployed and healthy ✅

## Blockers

- **AI provider key not yet set** — run `fly secrets set SIMMERSMITH_AI_OPENAI_API_KEY="sk-..." --app simmersmith`
- **Recipe import returning 500** — needs investigation (likely network/fetch issue on Fly)
- **Sign in with Apple untested on real device** — needs device build + Apple Developer config

## R1 Progress

- [x] R1.1 — Sign in with Apple (built + deployed)
- [x] R1.2 — AI week planning (built + deployed, needs API key)
- [x] R1.3 — Grocery generation (built, auto-generates from AI draft)
- [ ] R1.4 — Recipe UX polish (recipe import 500 needs fixing, detail view needs editorial treatment)
