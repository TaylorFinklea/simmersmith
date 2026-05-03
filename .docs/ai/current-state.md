# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-05-03 (continued, second hotfix)

**M22.5 + diagnostics hotfix** addresses build-35 dogfood:

- **M22.5 — sync feedback now actually surfaces**: the
  `reminderListIdentifier`, `lastReminderSyncAt`,
  `lastReminderSyncSummary` were UserDefaults-backed computed
  properties on `AppState`. `@Observable` only tracks stored
  properties, so SwiftUI never re-rendered when those changed —
  Settings → Grocery looked frozen after every Sync now tap. Moved
  to true stored properties on `AppState`, hydrated in
  `loadCachedData()` via new `loadReminderState()`, and persist
  to UserDefaults as a side effect.
- **API error context**: when the server returns 4xx/5xx, the iOS
  error now appends `[404 /api/path]` so a generic `"Not Found"`
  banner tells us which endpoint actually 404'd. (Build 35 surfaced
  a bare `"Not Found"` with no path; impossible to debug.)
- **Stale-error clear on Sync now**: tapping the manual sync button
  clears `lastErrorMessage` so a previous unrelated error doesn't
  masquerade as a sync failure.
- **Build 35 → 36**, TestFlight upload follows.

### Earlier same day (build 35)

**M22.3 + M22.4 + M23 hotfix** addresses dogfood feedback:

- **M22.3 — Reminders sync visibility**:
  - Each reminder now commits individually (`commit: true` per save).
    The previous batched `commit: false` + final `eventStore.commit()`
    pattern silently lost writes on iOS 26 in dogfood (sync said
    success, list stayed empty).
  - `upsertReminders` returns `(created, updated)` counts.
  - `syncGroceryToReminders` logs a human-readable summary via
    `lastReminderSyncSummary` ("Synced 12 items (12 created, 0
    updated).") and surfaces failures via `lastErrorMessage`.
  - Settings → Grocery now shows the summary plus a manual "Sync now"
    button so the user can retry without flipping the toggle.
- **M22.4 — auto-merge toggle hoisted**:
  - The toggle was inside `grocerySection` which only rendered when
    the event already had grocery items. Moved into a standalone
    `autoMergeRow` that's always visible on event detail (between
    attendees and Generate menu).
- **M23 hotfix — uv-native skill, no `.venv` ceremony**:
  - SKILL.md + README.md updated to use
    `uv run --project ~/.claude/skills/simmersmith-shopping ...`. uv
    reads `pyproject.toml` and manages the env transparently; no
    activation, no `.venv/bin/python`.
  - `cli.py` auto-installs Playwright Chromium on first browser-
    driving call so users don't need to remember `playwright install`.
  - `setup.sh` is now optional (just pre-warms cache + symlinks).
  - PyXA optional dep dropped — its PyPI release is stale; osascript
    fallback works on every Mac without extras.
- **Build 34 → 35**, deploy + TestFlight follows.

### Earlier same day (M22.1 + M22.2 + M23 ship — build 34)

**M22.1 + M22.2 limitation fixes + M23 skill scaffolding** shipped:

- **M22.1 — background Reminders sync**: new
  `SimmerSmith/Services/BackgroundSyncService.swift` registers a
  `BGAppRefreshTaskRequest` (identifier `app.simmersmith.ios.grocerySync`).
  iOS now wakes the app periodically to pull Reminders deltas back to
  the server even while it's backgrounded. `Info.plist` gains
  `BGTaskSchedulerPermittedIdentifiers` and `fetch` + `processing`
  background modes.
- **M22.2 — track event_quantity separately**: new
  `grocery_items.event_quantity` column +
  `alembic/versions/20260503_0029_grocery_event_quantity.py`.
  `merge_event_into_week` now writes the event delta into
  `event_quantity` instead of bumping `total_quantity`. Smart-merge
  regen can refresh `total_quantity` (week-meal portion) without
  disturbing the event contribution. iOS's `effectiveQuantity` sums
  the two for display. `_match_keys` now indexes by both base-id and
  normalized-name so a catalog-resolved week row still matches a
  name-only event row. New backend test
  `test_event_merge_uses_event_quantity_column`. 272 backend tests pass.
- **M23 — cart-automation skill scaffolding**:
  `skills/simmersmith-shopping/`. Full Python package:
  - `SKILL.md` + `README.md` for Claude Code discovery + setup.
  - `setup.sh` creates `.venv`, installs deps, runs `playwright
    install`, symlinks into `~/.claude/skills/`.
  - `parser.py` — permissive `<qty> <unit> <name>` parser handling
    fractions ("1 1/2 cups") and multi-word units ("fl oz").
  - `reminders.py` — PyXA + osascript fallback for reading the
    SimmerSmith Reminders list.
  - `splitter.py` — greedy + 2-store-combination heuristic
    minimizing cost subject to per-store delivery minimums and a
    configurable max-stops cap.
  - `stores/aldi.py` + `stores/walmart.py` — concrete Playwright
    drivers with real selectors. `stores/sams_club.py` +
    `stores/instacart.py` — login-only stubs the user fills in
    after the first interactive login captures cookies.
  - `cli.py` — orchestrator with `login --store X` (interactive
    cookie capture), `--dry-run` (synthesize prices for splitter
    verification), and the full Reminders → split → cart-fill
    pipeline.
  - 8 smoke tests pass (parser + splitter, no Playwright deps).
- **Build 33 → 34**, deploy + TestFlight to follow.

### Earlier same day (M22 ship)

**M22 Grocery list polish + Apple Reminders sync** shipped end-to-end:
- Phase 1 — schema + smart-merge regen + 5 mutation routes + 11 new
  backend tests (271 total pass).
  - `grocery_items` extended with 8 mutability fields
    (`is_user_added`, `is_user_removed`, `quantity_override`,
    `unit_override`, `notes_override`, `is_checked`, `checked_at`,
    `checked_by_user_id`) and `events.auto_merge_grocery`.
  - Smart-merge regeneration replaces the old wipe-rebuild — user
    edits, household-shared check state, and event-merge attribution
    survive meal changes.
  - 5 new routes under `/api/weeks/{id}/grocery/...`:
    POST `/items`, PATCH `/items/{id}`, POST/DELETE `/items/{id}/check`,
    GET `/grocery?since=ISO8601` (delta endpoint for Reminders sync).
  - Per-event `auto_merge_grocery` toggle wired through
    `apply_auto_merge_policy` so events fold into the week
    automatically when the toggle is on.
- Phase 2 — iOS surfaces.
  - SimmerSmithKit: `GroceryItem` extended with mutability fields +
    `effectiveQuantity/Unit/Notes` accessors. New `GroceryListDelta`
    response model. `Event` carries `autoMergeGrocery`.
  - 6 new API client methods + Sendable patch-body builders.
  - `AppState+Grocery.swift` (add/edit/remove/restore + local
    mirror helpers) and `AppState+Reminders.swift` (push and pull
    direction sync).
  - `RemindersService.swift` + `GroceryReminderMapping.swift`
    (per-device JSON store of grocery_item_id ↔ EKReminder
    calendarItemIdentifier).
  - 5th tab wired (`AppState.MainTab.grocery` was scaffolded but
    unwired before M22). `GroceryTabView` + editable `GroceryView`
    (swipe to remove, tap to edit, "+" toolbar to add).
  - `AddGroceryItemSheet`, `GroceryItemEditSheet`,
    `ReminderListPickerSheet`.
  - Settings → Grocery section with two-way sync toggle + list
    picker. EventDetailView has the auto-merge toggle.
  - `Info.plist` adds `NSRemindersUsageDescription` +
    `NSRemindersFullAccessUsageDescription`. No new entitlement.
  - Sign-out clears the per-device Reminders mappings via
    `clearReminderMappings()` from `resetConnection`.
- Phase 3 — durable design notes for the future M23 cart-automation
  skill (Aldi / Walmart / Sam's Club / Instacart) appended to
  `.docs/ai/decisions.md`. Roadmap updated.
- Phase 4 — `CURRENT_PROJECT_VERSION` 32 → 33. Commit + Fly deploy +
  TestFlight build 33 to follow.

**Test status**: backend `pytest -q` 271/271 (260 pre-M22 + 11 new
grocery edits). SimmerSmithKit `swift test` 26/26. iOS build green
on `generic/platform=iOS Simulator`.

### Previous session (2026-05-01)

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
