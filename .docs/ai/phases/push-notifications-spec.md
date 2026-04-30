# M18: Push Notifications (APNs) — Spec

## Product Overview

Today the app talks to the user only when the app is open. The user opens
SimmerSmith because a habit reminded them, not because the app prompted
them. M18 adds backend → device push notifications so the planner can
nudge the user when there is something to act on. v1 ships exactly two
notification kinds chosen from the next-steps brief:

1. **Tonight's meal** — once per day at the user's chosen time
   (default 17:00 local), shows the recipe name picked for that day's
   primary dinner slot and deep-links to the Week tab.
2. **Saturday plan reminder** — once per week on Friday at the user's
   chosen time (default 18:00 local), fires only when the upcoming
   week is still in `draft` status (no approved plan yet) and links
   to the Assistant tab with a "plan my week" intent.

Per-user opt-in: device registration + Settings toggle for each kind.
Defaults: both **on**. On first launch after sign-in, AppState fires the
APNs permission prompt automatically; if the user grants, the device
registers and the scheduler will deliver per the default times. If the
user denies, the server-side toggles still read enabled but APNs simply
has no token to deliver to — re-prompting is a system-level setting the
user can flip later in iOS Settings. The user can also disable either
notification at any time via the in-app Settings toggles. This pares
scope vs. cook-mode timer pushes / AI-finished pushes — those are
listed in `## Out of Scope`.

## Current State

- `SimmerSmith/SimmerSmith/SimmerSmith.entitlements:9-10` — `aps-environment` already set to `development`. Production needs flip to `production` in release builds (handled by `scripts/release-ios.sh` — confirm).
- `SimmerSmith/SimmerSmith/Info.plist` — has no `UIBackgroundModes` entry; v1 does not need silent push, so leave alone.
- `SimmerSmith/SimmerSmith/App/AppState.swift:114-125` — `init` is the right hook to register `UIApplication`'s remote-notification delegate.
- `SimmerSmith/SimmerSmith/App/AppState+Profile.swift:9-29` — pattern for "Settings toggle → PUT /api/profile → mirror locally". Mirror this for two new toggles (`push_tonights_meal`, `push_saturday_plan`).
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift:141-176` — Recipe-images section is the closest sibling. Drop a new `Section("Notifications")` between Recipe images and Templates.
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift:399-412` — `updateProfile(settings:)` is the existing route used for these toggles.
- `app/main.py:38-49` — lifespan owns startup. APScheduler boot goes here behind a setting flag so tests + dev can disable it.
- `app/services/bootstrap.py:17-47` — `DEFAULT_PROFILE_SETTINGS` already has `"timezone": "America/Chicago"`. Add `"push_tonights_meal": "1"`, `"push_saturday_plan": "1"`, `"push_tonights_meal_time": "17:00"`, `"push_saturday_plan_time": "18:00"` so new users land on-by-default at sign-in time. Existing users without rows fall through to the iOS-side defaults (also `true`) and a server-side fallback in the scheduler tick. The scheduler reads `timezone` per user; no new tz primitive needed.
- `app/api/profile.py:21-29` — `PUT /api/profile` upserts arbitrary `profile_settings` rows. Reused for the two toggles + the per-user time strings.
- `app/services/recipes.py` + `app/services/weeks.py` — used by the scheduler to find "tonight's meal" + "is upcoming week still draft".
- `app/services/ai.py:75-80` — `visible_profile_settings` strips secrets. Add `"apns_device_token"` to `AI_SECRET_KEYS` so device tokens don't leak through `GET /api/profile`.
- `pyproject.toml:11-21` — no APNs lib yet. Add `aioapns>=3.2`.
- `app/config.py:9-93` — env-var-driven settings. Adds APNs config rows below.

## Implementation Plan

### Phase 1 — Backend: device registration + APNs sender

1. Add `aioapns>=3.2` to `pyproject.toml` `[project] dependencies`. Run `.venv/bin/pip install -e '.[dev]'` after.
2. New Alembic migration `20260430_0025_push_devices.py`. Create `push_devices`:
   ```
   id          string(36) PK
   user_id     string(36) NOT NULL, INDEX
   device_token string(200) NOT NULL  -- 64 hex chars typical
   platform    string(16) NOT NULL DEFAULT 'ios'
   apns_environment string(16) NOT NULL DEFAULT 'sandbox'  -- 'sandbox' | 'production'
   bundle_id   string(120) NOT NULL DEFAULT ''
   last_seen_at datetime(tz) NOT NULL
   disabled_at datetime(tz) NULL  -- set when APNs returns 410 Unregistered
   created_at  datetime(tz) NOT NULL
   updated_at  datetime(tz) NOT NULL
   UNIQUE (user_id, device_token)
   ```
   Mirror `app/models/recipe_image.py` style. Add `PushDevice` to `app/models/__init__.py`.
3. New `app/models/push.py` — `PushDevice` SQLAlchemy model.
4. New `app/services/push_apns.py`:
   - `class APNsSender` wraps `aioapns.APNs`, lazily constructed per environment ("sandbox" or "production"). Token-based auth from `settings.apns_team_id`, `settings.apns_key_id`, `settings.apns_private_key_pem`.
   - `async def send_push(session, *, user_id, title, body, payload, collapse_id) -> int` — finds non-disabled `PushDevice` rows for `user_id`, sends one APNs request each, marks `disabled_at = utcnow()` on `410 Unregistered`. Returns count of devices delivered.
   - `def is_apns_configured(settings) -> bool` — true when the three apns secrets are non-empty.
5. New `app/api/push.py`:
   - `POST /api/push/devices` — body `{device_token, environment, bundle_id}`. Upserts a row keyed by `(user_id, device_token)`, sets `last_seen_at = utcnow()`, clears `disabled_at`. Returns `{registered: bool}`.
   - `DELETE /api/push/devices/{device_token}` — soft-disable (set `disabled_at`).
   - `POST /api/push/test` — admin-only (legacy `SIMMERSMITH_API_TOKEN` check); body `{user_id, title, body}`. Sends a synchronous test push so we can validate APNs creds end-to-end.
   Register in `app/main.py` under `protected_dependencies` (except the test route — keep public-but-bearer-gated like `subscriptions.apple-webhook`).
6. New `app/config.py` rows:
   ```
   apns_team_id: str = ""
   apns_key_id: str = ""
   apns_private_key_pem: str = ""   # multi-line .p8 contents, set via fly secrets
   apns_topic: str = ""             # bundle_id; defaults to apple_bundle_id when empty
   apns_default_environment: str = "sandbox"  # iOS sends per-device; this is the fallback
   push_scheduler_enabled: bool = True
   push_scheduler_tick_seconds: int = 300  # 5 min — fine resolution for hourly users
   ```
7. Add `apns_device_token` to `AI_SECRET_KEYS` set in `app/services/ai.py:19` so `visible_profile_settings` strips it. (Defense in depth — device tokens land in `push_devices`, not `profile_settings`, but a future user-typed key shouldn't leak.)

### Phase 2 — Backend: scheduler

Decision: **APScheduler in-process** on the FastAPI app. Single Fly machine, single scheduler. Tradeoff acknowledged: if we scale to 2 machines, we must move to a leader-elected job (Fly Postgres advisory lock) or `fly machines run` cron. v1 single-machine is fine; the README + decisions.md should record this.

8. Add `apscheduler>=3.10` to `pyproject.toml`.
9. New `app/services/push_scheduler.py`:
   - `start_scheduler(settings) -> AsyncIOScheduler | None` — returns None when `push_scheduler_enabled` is False or APNs not configured. Adds two `IntervalTrigger`s at `push_scheduler_tick_seconds`: `_tick_tonights_meal`, `_tick_saturday_plan`.
   - Each tick opens a fresh `session_scope()`, finds users with at least one active `push_devices` row, and for each user resolves their effective toggle state: a `profile_settings` row with `value == '1'` is enabled, an explicit `'0'` is disabled, and **an absent row defaults to enabled** (matches `DEFAULT_PROFILE_SETTINGS`). For enabled users, asks "is now within ±tick_seconds/2 of the user's chosen local time?" using `ZoneInfo(profile_settings['timezone'] or 'America/Chicago')` and the per-user time string (defaults `'17:00'` / `'18:00'`). If yes:
     - Tonight's meal: load today's primary dinner via `services/weeks.get_current_week` → first meal with `slot=='dinner'` for `meal_date == today_local`. Skip if absent. Body = `f"Tonight's meal: {recipe_name}"`. `payload = {"deep_link": "simmersmith://week"}`. `collapse_id = f"tonight-{user_id}-{today_iso}"` so a re-tick won't double-deliver.
     - Saturday plan: only fire on Friday local. Load upcoming week (next Monday-start) via `services/weeks.get_or_create_week` *read-only* — if a row exists with `status != 'draft'` skip; if no row exists or status is `draft`, fire. Body = `"Plan your Saturday — your week is still open."`. `collapse_id = f"saturday-{user_id}-{week_start_iso}"`.
10. Wire scheduler into `app/main.py` lifespan:
    ```python
    scheduler = start_scheduler(settings) if settings.push_scheduler_enabled else None
    yield
    if scheduler is not None:
        scheduler.shutdown(wait=False)
    ```
11. Idempotency: APNs collapse-id is best-effort. As a server-side guard, write a `push_deliveries` row (new table — defer if we keep one machine; collapse-id alone is enough for v1). **Decision**: skip the table for v1; rely on collapse-id + 5-min tick + a per-user "last delivered timestamp" in-memory dict in the scheduler module. Document the limit: a server restart inside the same minute could double-fire. Acceptable.

### Phase 3 — iOS: registration + Settings toggles

12. New `SimmerSmith/SimmerSmith/Services/PushService.swift`:
    - `@MainActor final class PushService` with `static let shared`.
    - `requestAuthorizationAndRegister()` — calls `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])`, on success calls `UIApplication.shared.registerForRemoteNotifications()`.
    - `func handleDeviceToken(_ data: Data, environment: String, bundleID: String, apiClient: SimmerSmithAPIClient)` — hex-encodes, calls `apiClient.registerPushDevice(token:environment:bundleID:)`. Stores last token in `UserDefaults("simmersmith.push.lastToken")` to skip identical re-registrations.
    - `func handleRemoteNotification(userInfo: [AnyHashable: Any], appState: AppState)` — reads `aps.alert` + `deep_link`, switches `appState.selectedTab` accordingly.
13. New `SimmerSmith/SimmerSmith/App/SimmerSmithAppDelegate.swift` — small `UIApplicationDelegate` adopted via `@UIApplicationDelegateAdaptor` on the `App` struct (find it in `SimmerSmithApp.swift`). Implements:
    - `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` → forwards to `PushService.shared.handleDeviceToken(...)`. Reads environment from `Bundle.main.object(forInfoDictionaryKey: "APS_ENVIRONMENT")` (or `#if DEBUG` + `"sandbox"` else `"production"`).
    - `application(_:didFailToRegisterForRemoteNotificationsWithError:)` → log only; never block.
    - `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` → forwards to `PushService.shared`.
14. Extend `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift`:
    ```swift
    public func registerPushDevice(token: String, environment: String, bundleID: String) async throws -> EmptyResponse
    public func unregisterPushDevice(token: String) async throws -> EmptyResponse
    ```
    Match the existing `EmptyResponse` pattern (see `clearDietaryGoal`).
15. New `AppState+Push.swift` mirroring `AppState+Profile.swift`:
    - `savePushPreference(_ key: String, enabled: Bool)` — calls `apiClient.updateProfile(settings: [key: enabled ? "1" : "0"])`. When the user *enables* a toggle from a disabled state, calls `PushService.shared.requestAuthorizationAndRegister()`.
    - `func ensurePushBootstrap() async` — called once after `bootstrap()` finishes hydrating the profile. If either toggle reads enabled (default behavior on a fresh account, since the seeded `DEFAULT_PROFILE_SETTINGS` rows below are `"1"`) AND `UserDefaults("simmersmith.push.didPrompt") != true`, it: (a) sets the `didPrompt` flag, (b) calls `PushService.shared.requestAuthorizationAndRegister()`. If the user denies, the server-side toggles stay `"1"` but no device token is registered — re-prompting requires the user toggling off then on again, which calls `requestAuthorizationAndRegister()` directly. Document this in the Settings footer.
    - Drafts: `pushTonightsMealEnabled: Bool` (default `true`), `pushSaturdayPlanEnabled: Bool` (default `true`), `pushTonightsMealTime: String` (default `"17:00"`), `pushSaturdayPlanTime: String` (default `"18:00"`). Hydrated from `profile.settings` like `imageProviderDraft`; absent rows fall back to the defaults so an upgrading user gets the same on-by-default behavior.
    - Wire `ensurePushBootstrap()` into the existing `bootstrap()` flow (`AppState.swift:218`-ish) right after `syncImageProviderDraft(from:)`. Keep it best-effort: a permission-prompt failure must never crash bootstrap.
16. New `Section("Notifications")` in `SettingsView.swift` between Recipe images (line 176) and Templates (line 178):
    - Two Toggles bound to the drafts.
    - Two `DatePicker(displayedComponents: .hourAndMinute)`s — formatted to `HH:mm` strings on save.
    - Footer text: `"On by default — toggle off to silence. We send push only at the times you set. Quiet hours: never between 22:00–07:00 local. If you previously denied notifications, enable them in iOS Settings → Notifications → SimmerSmith."` Implement the quiet-hours guard server-side in the scheduler tick (skip if `local_now.hour < 7 or local_now.hour >= 22`). Spec it as a hard rule, not a per-user toggle, to keep v1 simple.

### Phase 4 — Tests + verification

17. Backend unit tests in `tests/test_push.py`:
    - Device register/unregister round-trip.
    - `send_push` honors `disabled_at` (skip), and flips `disabled_at` on simulated 410.
    - Scheduler tick fires for a user whose local time matches; skips outside the window; respects quiet hours; respects explicit toggle off (`value=='0'`).
    - **Default-on semantics**: a user with active devices but no `push_*` rows still receives pushes at the default times.
    - Saturday tick skips when the upcoming week is `confirmed`.
    Use `freezegun` (add to `[dev]` deps) or a `Settings(time_provider=...)` injection — pick the lighter path. **Decision**: inject a `now_local` callable into `_tick_*` so tests pass in a fixed datetime; no new dep.
18. iOS: no Swift tests for PushService (UIApplication-bound). Skipped for v1; covered by manual TestFlight test plan.
19. Manual e2e checklist (record in next-steps.md after impl):
    - Fresh install + sign-in → permission prompt fires automatically once the profile finishes hydrating (no toggle interaction required). Accept → `POST /api/push/devices` lands.
    - Settings → both toggles read enabled by default with default times `17:00` / `18:00`.
    - `POST /api/push/test` from local curl with the legacy bearer → notification appears on device.
    - Set "Tonight's meal time" to "now+1min", wait, confirm scheduler fires.
    - Toggle "Tonight's meal" off → no further pushes.
    - Sign out → `unregisterPushDevice` lands; future pushes don't appear.
    - Decline the permission prompt on first launch → toggles still read enabled but no push arrives; toggling off then on prompts iOS to redirect to system Settings (acceptable v1 behavior).

### Phase 5 — Production readiness

20. Generate APNs auth key in Apple Developer (`.p8`) — **user must do this before deploy**. Issue an `AskUserQuestion` if the key isn't provisioned at implementation time.
21. `fly secrets set SIMMERSMITH_APNS_TEAM_ID=K7CBQW6MPG SIMMERSMITH_APNS_KEY_ID=… SIMMERSMITH_APNS_PRIVATE_KEY_PEM="$(cat AuthKey_XXX.p8)" SIMMERSMITH_APNS_TOPIC=app.simmersmith.ios`.
22. Flip `aps-environment` to `production` for App Store / TestFlight builds. Verify `scripts/release-ios.sh` uses the production entitlement (it should, via build configuration); if not, parameterize.

## Interfaces and Data Flow

**New routes** (all under `/api`):
- `POST /push/devices` — register/refresh a device token. Body `{device_token: str, environment: "sandbox"|"production", bundle_id: str}`. Returns `{registered: true}`.
- `DELETE /push/devices/{device_token}` — soft-disable.
- `POST /push/test` — admin (legacy bearer). Body `{user_id, title, body}`. Returns `{delivered: int}`.

**New profile_settings rows** (per-user, key/value):
- `push_tonights_meal` — `"1"` / `"0"`.
- `push_saturday_plan` — `"1"` / `"0"`.
- `push_tonights_meal_time` — `"HH:mm"` (24h local).
- `push_saturday_plan_time` — `"HH:mm"` (24h local).
- `timezone` — already exists; reused.

**New env vars** (production via `fly secrets set`):
- `SIMMERSMITH_APNS_TEAM_ID`, `SIMMERSMITH_APNS_KEY_ID`, `SIMMERSMITH_APNS_PRIVATE_KEY_PEM`, `SIMMERSMITH_APNS_TOPIC`, `SIMMERSMITH_APNS_DEFAULT_ENVIRONMENT`, `SIMMERSMITH_PUSH_SCHEDULER_ENABLED`, `SIMMERSMITH_PUSH_SCHEDULER_TICK_SECONDS`.

**APNs payload shape**:
```json
{"aps": {"alert": {"title": "...", "body": "..."}, "sound": "default"},
 "deep_link": "simmersmith://week" }
```

## Edge Cases and Failure Modes

- User has no `timezone` row → fall back to `"America/Chicago"` (the seeded default).
- User's `push_*_time` is malformed → skip (warn-log) rather than crash the tick; never block other users.
- APNs returns 410 Unregistered → set `disabled_at` so we never retry that token. Re-register only happens when iOS hands a fresh token via `didRegisterForRemoteNotifications`.
- APNs key rotated → `aioapns` cached client must rebuild on key change. v1: just restart the app.
- Multiple devices per user → `send_push` iterates all non-disabled rows. Settings toggle is per-user, not per-device, by design.
- Daylight-saving transition → `ZoneInfo` handles it. The 5-min tick window is robust to ±1 hour shifts.
- Sandbox vs production token mismatch → iOS reports its environment per device; the sender constructs the matching `APNs` client. Mixing in one userset is fine.
- User signs out → call `unregisterPushDevice` on sign-out to avoid pushing to a stale account.
- Two-machine scaling (future) → leader election via Postgres advisory lock. Out of scope for v1; record in decisions.md.
- Test environment → `push_scheduler_enabled=false` in `tests/conftest.py` so pytest doesn't spawn an APScheduler; verify it's already off-by-default in test settings, otherwise add the override.

## Test Plan

```bash
.venv/bin/ruff check .
.venv/bin/pytest tests/test_push.py -v
.venv/bin/pytest -v   # full suite stays green
swift test --package-path SimmerSmithKit
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO
```

Acceptance:
- Fresh install on a real device → both toggles read enabled by default; permission prompt fires automatically once after first sign-in completes.
- Accept the prompt → `POST /api/push/devices` succeeds (visible in Fly logs). Settings shows both toggles on.
- `curl POST /api/push/test` with legacy bearer + the user_id → push appears within 5s.
- Set `push_tonights_meal_time` to current minute + 1 → push fires within `tick_seconds`. Recipe name in body matches today's dinner meal.
- Friday at user-local time → Saturday push fires only when upcoming week is `draft`.
- Disable toggle → no further pushes.
- Toggle back on after a deny → app calls `requestAuthorizationAndRegister()` again; iOS shows "previously denied" state (system Settings deep-link is acceptable v1 fallback).
- 22:00–07:00 local: pushes silently skipped even if time matches (verify in logs).
- Sign out → `DELETE /api/push/devices/{token}` lands; subsequent test push reports 0 delivered.

## Out of Scope (v1)

- Per-user quiet-hours customization (hard 22–07 in v1).
- Cook-mode timer-end pushes (cook mode handles timers locally; defer).
- AI-finished-thinking pushes (assistant streams while open; defer).
- Silent / background push (`UIBackgroundModes` not added).
- Notification grouping beyond `apns-collapse-id`.
- Per-device toggles. Per-user only.
- Web/macOS push.
- Cross-machine scheduler safety (single Fly machine assumed).

## Handoff

- **Tier**: medium (Sonnet via `/spec-implement`). Volume is real (10 files cross-stack) but every step is decision-complete and the patterns to copy are listed inline. The one judgment call — APScheduler in-process vs. fly cron — is decided in this spec.
- **Files likely touched**: `pyproject.toml`, `app/config.py`, `app/main.py`, `app/services/ai.py`, `app/services/bootstrap.py`, `app/services/push_apns.py` (new), `app/services/push_scheduler.py` (new), `app/api/push.py` (new), `app/models/push.py` (new), `app/models/__init__.py`, `alembic/versions/20260430_0025_push_devices.py` (new), `tests/test_push.py` (new), `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift`, `SimmerSmith/.../App/SimmerSmithApp.swift` (delegate adaptor), `SimmerSmith/.../App/SimmerSmithAppDelegate.swift` (new), `SimmerSmith/.../App/AppState.swift` (drafts), `SimmerSmith/.../App/AppState+Push.swift` (new), `SimmerSmith/.../Services/PushService.swift` (new), `SimmerSmith/.../Features/Settings/SettingsView.swift`, `SimmerSmith/.../SimmerSmith.entitlements` (only if release flips needed).
- **Constraints**: keep the scheduler off in tests (`push_scheduler_enabled=false`). Do not gate on M5 / freemium. Do not push without a real APNs key — the implementer must surface a blocker if `SIMMERSMITH_APNS_*` aren't provisioned.
- **Open user-side**: confirm an APNs `.p8` auth key exists or is willing to be created (Apple Developer → Keys → APNs). If yes, deploy works. If no, the implementer ships up through Phase 4 and stops at Phase 5 pending key.
