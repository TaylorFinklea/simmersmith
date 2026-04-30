# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-30

Shipped **M18 Push Notifications (Phases 1-4)** — APNs device registration,
scheduler, iOS registration + Settings toggles, and 18 backend tests.
Both notification types **default ON**: AppState fires the APNs permission
prompt automatically once after first sign-in. Phase 5 unlocked mid-session
when the user confirmed the existing `SimmerSmith Prod` Apple Developer key
(`AuthKey_46NXHV5UB8.p8`, already in repo root, gitignored) covers APNs in
addition to Sign In with Apple. User ran `fly secrets set` for all four
`SIMMERSMITH_APNS_*` vars; `fly deploy` + TestFlight build 28 cut are the
only steps remaining.

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
  existing `AuthKey_46NXHV5UB8.p8`, `TOPIC=app.simmersmith.ios`). Fly
  redeployed the existing image; the new push routes activate after the
  next `fly deploy`.
- **Backend image deployed**: still M17 build (Fly version 56). M18 push
  routes are committed locally; deploy pending.
- **TestFlight**: build 27 (M17) is the live build. Build 28 cut pending.

### Build status

- Backend: pytest 215/215 pass (18 new). ruff clean on all new files.
- Swift tests: 26/26 pass.
- iOS build: green on `generic/platform=iOS Simulator`.

### Previous session

M17 (Gemini-direct image-gen per-user toggle) shipped end-to-end —
backend deployed + TestFlight 27 uploaded. Detail in commit `51d6120`
and the 2026-04-29 ADR in `decisions.md`.

## Blockers

Two operational steps remain before M18 is live on TestFlight:
1. `fly deploy` from this branch to push the M18 backend image.
2. `./scripts/release-ios.sh` to cut TestFlight build 28 (project.yml
   already bumped to `CURRENT_PROJECT_VERSION=28`).

Both are user-driven per repo policy.
