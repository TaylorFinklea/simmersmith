# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-19

Shipped M6 end-to-end: the Week-page sparkle button is now a conversational
AI agent that can read and modify the week in real time. Per-day "Ask AI",
active-chat chip, 11 tools, and day-by-day `generate_week_plan` application
all landed in this session.

**What was done:**

### Backend (commit `b288b80`)
- New Alembic migration `20260419_0017` — adds `assistant_threads.linked_week_id`,
  `assistant_threads.thread_kind`, and `assistant_messages.tool_calls_json`.
- New `app/services/assistant_tools.py` — registry of 10 tools (get_current_week,
  get_dietary_goal, generate_week_plan, add_meal, swap_meal, remove_meal,
  set_meal_approved, rebalance_day, fetch_pricing, set_dietary_goal) with
  JSON Schemas and gating via `ensure_action_allowed` / `increment_usage`.
- `app/services/assistant_ai.py` gains `_run_openai_tool_loop` — native OpenAI
  tool-calling with streamed `assistant.tool_call`, `assistant.tool_result`, and
  `week.updated` SSE events, max 6 iterations.
- `app/api/assistant.py` — streams the new events for planning threads; accepts
  `thread_kind` + `linked_week_id` on thread create; persists tool-call
  transcript on the assistant message.
- Tests: `tests/test_assistant_tools.py` — registry shape, per-tool behavior,
  planning-thread SSE round-trip (6 new tests; 130 total pass).

### iOS
- `SimmerSmithKit` models gain `threadKind` + `linkedWeekId` on thread summary
  and thread; `AssistantMessage` gains `toolCalls: [AssistantToolCall]`; new
  `SimmerSmithJSONValue` type for heterogeneous tool arguments. Custom
  Decodable keeps old test fixtures working.
- `apiClient.createAssistantThread` now forwards `threadKind` + `linkedWeekID`.
- `AppState+Assistant` handles the three new SSE events; `week.updated` writes
  directly to `appState.currentWeek` so the Week page reflects the AI's edits
  live.
- New `Features/Assistant/AssistantToolCallCard.swift` renders per-tool status
  cards inline with message bubbles (running / done / failed).
- `WeekView.swift` sparkle button now opens a planning-linked Assistant thread
  pre-seeded with "Plan my week…" (or "refine this week" when meals exist)
  instead of the old one-shot sheet. Dead modal + state variables removed.
- Swift tests: 26/26 pass. iOS build: green on `generic/platform=iOS Simulator`.

## Production

- **URL**: https://simmersmith.fly.dev
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **TestFlight**: v1.0.0 build 3 uploaded (untested)

## Build Status

- Backend: ruff clean, pytest 130/130 pass
- Swift tests: 26/26 pass
- iOS build: green (`generic/platform=iOS Simulator`)
- TestFlight: UPLOADED (build 3, M6 changes not yet built to a new TestFlight build)
- Production: not yet deployed with M6 changes

## Blockers

- **OpenAI API key required**: the tool-calling loop only fires when the thread
  resolves to a `direct` OpenAI provider. MCP / Anthropic threads fall back to
  the existing envelope-JSON (one-shot) behavior.
- **No live end-to-end test yet**: all M6 testing so far uses a mocked
  `run_assistant_turn`. The first real OpenAI-backed run of the planning
  sparkle will be the shakedown.

## Files Changed

- `alembic/versions/20260419_0017_assistant_planning_tools.py` (new)
- `app/services/assistant_tools.py` (new)
- `app/services/assistant_ai.py`
- `app/services/assistant_threads.py`
- `app/services/presenters.py`
- `app/api/assistant.py`
- `app/models/ai.py`
- `app/schemas/assistant.py`
- `tests/test_assistant_tools.py` (new)
- `SimmerSmithKit/Sources/SimmerSmithKit/Models/SimmerSmithModels.swift`
- `SimmerSmithKit/Sources/SimmerSmithKit/API/SimmerSmithAPIClient.swift`
- `SimmerSmith/SimmerSmith/App/AppState.swift`
- `SimmerSmith/SimmerSmith/App/AppState+Assistant.swift`
- `SimmerSmith/SimmerSmith/Features/Week/WeekView.swift`
- `SimmerSmith/SimmerSmith/Features/Assistant/AssistantView.swift`
- `SimmerSmith/SimmerSmith/Features/Assistant/AssistantToolCallCard.swift` (new)
- `.docs/ai/roadmap.md`
