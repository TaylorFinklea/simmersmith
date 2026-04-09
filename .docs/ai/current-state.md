# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-09

M0 audit phase is essentially complete. All code quality, security, and bug-fix work is done — only the big-ticket infrastructure items remain (Supabase, multi-user isolation, TestFlight).

**Audit work finished this session:**
- iOS + SimmerSmithKit code audit — 9 findings (2 critical, 6 high, 1 medium), all resolved
- 4 critical backend bugs fixed earlier in session (Postgres connect_args, DATABASE_URL override, grocery `quantity_text`, presenter None crash)
- 4 security issues fixed (SSRF on recipe import, assistant error leakage, health endpoint info disclosure, empty-token startup warning)
- Recipe ID slug collision replaced with UUID (`drafts.py:upsert_recipe`)
- Grocery full-table scans scoped to week's meal IDs

**iOS critical security fixes:**
- Removed plaintext token fallback in `UserDefaults` — was visible in device backups and crash reports. Legacy key is now actively scrubbed on store init.
- Added `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to Keychain base query — tokens no longer sync via iCloud Keychain.
- HTTP URL warning in `ConnectionSetupView` — orange label when user would send bearer token over plaintext.

**iOS concurrency fixes:**
- `clearLocalCache()` now tracks and cancels its post-clear refresh Task so `resetConnection()` can stop it cleanly.
- `streamAssistantResponse` wires `continuation.onTermination` to cancel the inner SSE reader when consumer terminates.
- `sendAssistantMessage` preserves a soft error warning when stream drops mid-response.

**iOS accessibility (App Store review):**
- Toolbar icon buttons in Week, Grocery, Assistant views now have explicit `accessibilityLabel`.
- Grocery check toggle announces item name + state for VoiceOver.

**Code quality / refactoring:**
- Split `app/models.py` (723 lines) → `app/models/` package (7 domain modules)
- Split `app/schemas.py` (734 lines) → `app/schemas/` package (8 domain modules)
- Split `app/mcp_server.py` (862 lines) → `app/mcp/` package (7 modules) — earlier in session
- `try!` NSRegularExpression crash risk replaced with `try?` + guard
- 5 Haiku backlog items cleaned up (`staple_count` rename, unarchive preservation, route `limit` bounds, `DraftFromAIRequest.model` constraint)
- All 7 pre-existing ruff failures resolved — repo-wide lint is green
- False-positive `exports.py:73 updated_at` dropped from backlog (ExportRun has no `updated_at` column)

## Build Status

- Backend: `.venv/bin/ruff check .` — all checks passed
- Backend: `.venv/bin/pytest -q` — 58 tests passing
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

The remaining work is all **big-ticket infrastructure** that M0 was designed to set up. Everything else — audit, bug fixes, security hardening, code quality — is finished.
