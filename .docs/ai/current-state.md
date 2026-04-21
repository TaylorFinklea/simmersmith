# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-20 (evening)

Shipped Phases 1–4 of the M7 "Assistant Polish" milestone. M5 freemium
work was explicitly postponed at the user's request — M7 is the active
focus until the overlay + streaming flow is production-solid. Ready for
a TestFlight cut.

### What landed this session

**Phase 1 — Stop the pull-to-refresh cancel cascade (commit `5fdde1a`)**

- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift` now owns a
  dedicated `streamingSession: URLSession` for SSE streaming, separate
  from `URLSession.shared` used for regular requests.
- `streamAssistantResponse` uses the new session. Pull-to-refresh on
  Week can no longer kill the in-flight assistant stream.
- Config: 300s request timeout, 600s resource timeout,
  `waitsForConnectivity: true`.

**Phase 2 — Persist streamed deltas mid-turn (commit `f9b4990`)**

- `app/services/assistant_threads.py` — new `persist_streaming_content`
  helper writes only `content_markdown`, leaving status / tool_calls /
  completed_at for the final `update_assistant_message` call.
- `app/api/assistant.py` — SSE endpoint accumulates text from
  `assistant.delta` events and flushes to the DB every 500ms (tunable
  via `STREAM_PERSIST_INTERVAL_SECONDS`). Final flush before the
  completion write.
- Regression test asserts partial persists land when the throttle is
  patched to 0.

**Phase 3 — Cancel server turn on client disconnect (commit `1fd8017`)**

- `app/services/assistant_ai.py` — new `abort_event: threading.Event`
  parameter threaded from `run_assistant_turn` into
  `_run_openai_tool_loop`. Checked before each iteration, between OpenAI
  chunks, and before each tool invocation.
- `AssistantTurnResult` gains `cancelled: bool = False`. On cancel the
  envelope preserves whatever arrived before the abort.
- `app/api/assistant.py` — spawns a `_watch_disconnect` coroutine that
  polls `request.is_disconnected()` on a 1s cadence and fires the
  abort_event. Cancelled turns persist with `status="cancelled"`, log
  `AIRun.status="cancelled"` + `cancelled=true` in the request payload,
  and emit an `assistant.cancelled` SSE frame.
- iOS `AIAssistantCoordinator` retains the streaming `Task` and exposes
  `cancelInFlightTurn()`. `AIAssistantSheetView.onDisappear` calls it so
  closing the sheet stops the server turn via TCP close → Starlette
  disconnect detection.
- `AssistantMessageInlineBubble` renders a muted "Cancelled" capsule on
  messages with `status == "cancelled"`.
- Regression test stubs `httpx.Client` to emit deltas and asserts
  abort_event short-circuits the loop while preserving pre-abort text.

**Phase 4 — Hallucination guardrail (commit `0fb46b8`)**

- `AssistantMessageInlineBubble` detects "I swapped / added / removed /
  rebalanced / updated …" prose on completed assistant messages with an
  empty `toolCalls` list and renders an amber affordance:
  "Nothing changed in your plan" + "Run it now" button that sends
  "Yes, actually do that." as a follow-up turn.
- Kept iOS-only — pattern list is inline, deliberately permissive
  (false positives over false negatives). If we want the warning to
  survive app restarts we can promote detection to the backend and
  persist a flag, but that'd mean a migration.

### Production state

- **URL**: https://simmersmith.fly.dev (healthy; last deploy was the M6
  rollout — these phase-1–4 changes have NOT been deployed yet)
- **Model**: `gpt-5.4-mini` (default in config; no fly override)
- **Secret**: `SIMMERSMITH_AI_OPENAI_API_KEY` set on fly
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **TestFlight**: v1.0.0 build 3 (stale — does not include M6 or any M7
  work)

### Build status

- Backend: ruff clean, pytest 133/133 pass (added 2 new M7 tests)
- Swift tests: 26/26 pass
- iOS build: green on `generic/platform=iOS Simulator`
- Fly production: healthy but stale (pre-M7)
- TestFlight: stale (pre-M6)

### Deferred (M7 Phases 5 + 6)

Still in M7 but deferred because Phases 1–4 are shippable as a
standalone TestFlight cut:

- **Phase 5 — Anthropic tool-use support**: refactor `_run_openai_tool_loop`
  into a provider-agnostic `_run_tool_loop(adapter, ...)` with an
  `AnthropicToolStreamAdapter`. `anthropic_tools_schema()` already
  exists at `assistant_ai.py:758–766` but is never called.
- **Phase 6 — True per-day `generate_week_plan`**: one AI call per day
  with prior days in context. 7× the tokens on a full week. Worth
  flagging before shipping given freemium gating is postponed.

### Open issues (M7 follow-ups)

All resolved in this session except the two deferred phases above.

## Files Changed (this session)

Backend:
- `app/services/assistant_ai.py` — abort_event plumbing, cancelled flag
- `app/services/assistant_threads.py` — `persist_streaming_content` helper
- `app/api/assistant.py` — disconnect watcher, throttled persist, cancelled handling
- `tests/test_assistant_tools.py` — 2 new regression tests

iOS:
- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift` — dedicated streamingSession
- `SimmerSmith/.../Features/AIAssistant/AIAssistantCoordinator.swift` — retained sendTask, cancelInFlightTurn
- `SimmerSmith/.../Features/AIAssistant/AIAssistantSheetView.swift` — onDisappear cancel, cancelled pill, hallucination affordance
