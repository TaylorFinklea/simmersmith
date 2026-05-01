# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-01

**M21 Household sharing** shipped end-to-end across 5 phases:
- Phase 1 (commit `edf9a0f`) — schema: `households`, `household_members`,
  `household_invitations`, `household_settings` tables. `household_id`
  column on Week / Recipe / Staple / Event / Guest, backfilled.
- Phase 2 (commit `eff6e8f`) — service rewrite + auth: `CurrentUser`
  carries `household_id` (lazy-create for legacy users); every shared-
  table query flips from `user_id` to `household_id`; writers populate
  `household_id` on construct; per-user data (DietaryGoal,
  IngredientPreference, PushDevice, etc.) intentionally stays user-scoped.
- Phase 3 (commit `c50c6ce`) — invitation API + tests: 5 routes (GET
  household, PUT name, POST/DELETE invitations, POST join). Auto-merge
  on join: joiner's solo content (recipes, weeks, staples, events,
  guests) is re-pointed to the target household; the empty solo is
  deleted. 12 new tests covering owner-only checks, expiry, single-use
  consume, cross-member visibility, per-user push isolation.
- Phase 4 (commit `0dbe4a4`) — iOS surfaces: `HouseholdSnapshot` model +
  5 API client methods + `AppState+Household.swift` + new
  `InvitationSheet` (display + ShareLink) + `JoinHouseholdSheet` +
  `HouseholdSection` in Settings (between Sync and AI). Owner sees
  editable name + member list + invite button + active codes with
  Revoke. Solo households see "Join a household".
- Phase 5 — build bump 31→32, push, deploy, TestFlight 32. (in flight)

**Test status**: backend `pytest -q` 260/260 (248 pre-M21 + 12 new
household-API tests). SimmerSmithKit `swift test` 26/26. iOS build
green on `generic/platform=iOS Simulator`.

### Previous session (2026-04-30)

Three milestones shipped end-to-end:

- **M17.1 Image-gen cost telemetry** — per-call `image_gen_usage` rows,
  30-day Settings rollup, admin `GET /api/admin/image-usage` behind the
  legacy bearer. Backend deployed to Fly v58. Commit `13e2a97`.
- **M18 Push Notifications** — APNs device registration + in-process
  APScheduler + iOS Settings toggles (default ON). User set the four
  `SIMMERSMITH_APNS_*` Fly secrets using the existing
  `AuthKey_46NXHV5UB8.p8` Apple Developer key (covers both APNs and Sign
  In with Apple). Backend deployed to Fly v58. TestFlight build 28
  uploaded; on-device validation pending. Commit `86f738c`.
- **M19 / M7 Phase 5 Anthropic tool-use** — Refactored
  `_run_openai_tool_loop` into a provider-agnostic
  `_run_provider_tool_loop` driven by a `ProviderAdapter` ABC with
  `OpenAIAdapter` and `AnthropicAdapter` implementations. Anthropic
  planning threads now run the same 11 tools the OpenAI path runs;
  `assistant.tool_call`, `assistant.tool_result`, and `week.updated`
  SSE events fire identically. 7 new tests (1 schema parity + 6
  Anthropic-loop). Uncommitted at session end.

### What landed this session (M18, Phases 1-4)

**Backend**
- `pyproject.toml` — added `aioapns>=3.2`, `apscheduler>=3.10`
- `app/config.py` — added 6 APNs/scheduler settings
- `app/models/push.py` (new) — `PushDevice` SQLAlchemy model
- `app/models/__init__.py` — exported `PushDevice`
- `alembic/versions/20260430_0025_push_devices.py` (new) — `push_devices` table
- `app/services/push_apns.py` (new) — `APNsSender`, `send_push`, `is_apns_configured`
- `app/services/push_scheduler.py` (new) — `start_scheduler`, `_tick_tonights_meal`,
  `_tick_saturday_plan` with injected `now_local` callable for tests
- `app/services/bootstrap.py` — added 4 push default rows to `DEFAULT_PROFILE_SETTINGS`
- `app/services/ai.py` — added `apns_device_token` to `AI_SECRET_KEYS`
- `app/api/push.py` (new) — `POST /push/devices`, `DELETE /push/devices/{token}`,
  `POST /push/test`
- `app/main.py` — wired push router + scheduler lifespan

**Tests** (`tests/test_push.py`, +18)
- Device register/upsert/unregister round-trips
- `send_push` honours `disabled_at`, marks 410 Unregistered
- Scheduler fires at matching time, skips outside window, respects quiet hours
- Toggle-off (`value=='0'`) suppresses push
- Default-on semantics (no rows = enabled)
- Saturday tick skips approved week, fires for draft/no-week

**iOS**
- `SimmerSmith/SimmerSmith/Services/PushService.swift` (new) — APNs registration + notification dispatch
- `SimmerSmith/SimmerSmith/App/SimmerSmithAppDelegate.swift` (new) — UIApplicationDelegate adapter
- `SimmerSmith/SimmerSmith/App/SimmerSmithApp.swift` — `@UIApplicationDelegateAdaptor`
- `SimmerSmith/SimmerSmith/App/AppState+Push.swift` (new) — push drafts + `savePushPreference` + `ensurePushBootstrap`
- `SimmerSmith/SimmerSmith/App/AppState.swift` — wired `ensurePushBootstrap()` after `syncImageProviderDraft`
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift` — `NotificationsSection` added
- `SimmerSmith/project.yml` — `CURRENT_PROJECT_VERSION` 27 → 28
- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift` — `registerPushDevice` + `unregisterPushDevice`

**Infra**
- `tests/conftest.py` — `SIMMERSMITH_PUSH_SCHEDULER_ENABLED=false` so APScheduler never spawns in pytest

### Production state (mid-session)

- **Fly secrets**: All four `SIMMERSMITH_APNS_*` vars set this session
  (`TEAM_ID=K7CBQW6MPG`, `KEY_ID=46NXHV5UB8`, `PRIVATE_KEY_PEM` from the
  existing `AuthKey_46NXHV5UB8.p8`, `TOPIC=app.simmersmith.ios`).
- **Backend image deployed**: Fly v58 carries M17 + M18 + M17.1. M19
  uncommitted, undeployed at session end.
- **TestFlight**: build 28 uploaded (M18 surface). On-device validation
  of M18 push toggles + auto-permission-prompt + `POST /api/push/test`
  is pending the user installing build 28.

### Build status

- Backend: pytest **242/242** pass (29 new this session: 18 push +
  20 telemetry + 1 schema parity + 6 Anthropic + minus 16 covered by
  existing tests' updates). Ruff clean on all touched files.
- Swift tests: 26/26 pass.
- iOS build: green on `generic/platform=iOS Simulator`.

### Previous session

M17 (Gemini-direct image-gen per-user toggle) shipped end-to-end in
commit `51d6120`. M16, M15 detail in earlier sessions.

## Blockers

Three loose ends, all user-driven:
1. **M19 uncommitted** — `app/services/assistant_ai.py`,
   `tests/test_assistant_anthropic_tools.py`,
   `tests/test_assistant_tools.py`, plus a few doc updates. Commit +
   `fly deploy` when ready (no migration, no iOS work).
2. **TestFlight 28 device validation** for M18 push notifications —
   install + sign in + accept the auto-fired permission prompt + run
   the `POST /api/push/test` curl smoke test.
3. **Anthropic dogfooding for M19** — Settings → AI provider toggle
   → switch to Anthropic → planning thread tool-use parity check.
