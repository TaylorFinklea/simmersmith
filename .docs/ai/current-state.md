# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-25

Closed out M10.1 Event Polish v2 and uploaded **TestFlight build 14**.
Hands the dogfooding loop back to the user (his wife is the live tester
on the freshly-baked Easter / event-planning surface). No production
backend deploys are pending — the M10.1 grocery-exclusion fix landed
on Fly in commit `2ff4d9a`.

Since the last current-state snapshot (2026-04-20, M7 phases 1-4) the
following milestones shipped:

- **M6** rollout deployed to Fly
- **M7 phases 1-4** (streaming + cancel + hallucination guardrail) deployed
- **M8 Smart Substitutions** with replace-vs-variation choice
- **M9 Preference-Aware Planner** (avoid/allergy fed into planner prompt)
- **M10 Event Plans** (Events tab, AI menu, grocery merge, manual dishes,
  per-dish assignees, age-group-aware AI)
- **M10.1 Event Polish v2** — assignee dishes excluded from host's
  grocery, edit + delete from event detail, "Guests bringing" subsection

### What landed this session (M10.1)

**Phase 1 — Backend grocery fix (commit `2ff4d9a`, deployed)**

- `app/services/event_grocery.py:70` — `_aggregate_event_rows` now
  skips meals with `assigned_guest_id` so the host's grocery list
  excludes guest-brought dishes.
- `tests/test_events_api.py` — added
  `test_assigned_meals_excluded_from_event_grocery` (148/148 pytest).
- iOS `EventDetailView` gained a "Guests bringing" section listing
  assigned dishes by assignee name.

**Phases 2 + 3 — iOS edit + delete (commit `740bd59`)**

- New `EventEditSheet.swift` mirrors `EventCreateSheet` for
  name/date/occasion/attendeeCount/status/notes. Attendee curation
  stays in `AttendeePickerSheet` (passed through unchanged on save).
- `EventDetailView` toolbar gains an ellipsis menu with "Edit event
  info" and a destructive "Delete event" guarded by a
  `confirmationDialog`. On delete the detail view dismisses back to
  the Events list.

**TestFlight cut**

- `SimmerSmith/project.yml` `CURRENT_PROJECT_VERSION` 13 → 14
  (commit `e966cd4`).
- Archived + exported via `ExportOptions.plist`, uploaded to App
  Store Connect successfully. Build 14 is the current TestFlight.

### Production state

- **URL**: https://simmersmith.fly.dev (healthy; current = M10.1 Phase 1)
- **Model**: `gpt-5.4-mini`
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **TestFlight**: v1.0.0 build 14 (M10.1 + everything before)

### Build status

- Backend: ruff clean, pytest 148/148 pass
- Swift tests: 26/26 pass
- iOS build: green; archive + export uploaded
- Fly production: healthy, current

## Files Changed (this session)

Backend:
- `app/services/event_grocery.py` — assignee exclusion in
  `_aggregate_event_rows`
- `tests/test_events_api.py` — assignee-exclusion regression test

iOS:
- `SimmerSmith/.../Features/Events/EventDetailView.swift` — Guests
  bringing section, ellipsis menu, edit/delete flows, confirmation
  dialog
- `SimmerSmith/.../Features/Events/EventEditSheet.swift` — new
- `SimmerSmith/project.yml` — build 14 bump

Docs:
- `.docs/ai/roadmap.md` — M10 marked complete (prior session); this
  session adds M10.1 polish items
- `.docs/ai/current-state.md` — this file
- `.docs/ai/next-steps.md` — refreshed after stale M7 entries
