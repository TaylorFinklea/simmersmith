# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Last Session Summary

**Date**: 2026-04-20

Shipped the full M6 conversational planning milestone, then reworked the
assistant UX into a Nebular-News-style global overlay with per-view context,
fixed two streaming-path bugs that surfaced during a live shakedown, and
deployed twice to fly.io. The sparkle/assistant flow is now working
end-to-end against `gpt-5.4-mini` on production.

### What landed this session

**Phase 1 — M6 conversational planning (commits `b288b80` → `13d7d3b`)**

- Alembic migration `20260419_0017` adds `assistant_threads.linked_week_id`,
  `thread_kind`, and `assistant_messages.tool_calls_json`.
- New `app/services/assistant_tools.py` registry with 11 tools: 3 read-only
  (`get_current_week`, `get_dietary_goal`, `get_preferences_summary`) and 8
  mutating (`generate_week_plan`, `add_meal`, `swap_meal`, `remove_meal`,
  `set_meal_approved`, `rebalance_day`, `fetch_pricing`, `set_dietary_goal`).
  Each has a JSON Schema and reuses `ensure_action_allowed` /
  `increment_usage` for the freemium gate.
- `app/services/assistant_ai.py` gains `_run_openai_tool_loop` — native
  OpenAI tool-calling, max 6 iterations, with `on_event` callbacks for
  `assistant.tool_call`, `assistant.tool_result`, and `week.updated`.
- `generate_week_plan` applies day-by-day with a `week.updated` event
  between each day so the iOS client renders progressive state.
- iOS: new `AssistantToolCallCard` renders tool cards inline with message
  bubbles. Per-day "Ask AI" sparkle button + active-chat chip on the Week
  page.

**Phase 2 — Nebular-style contextual overlay (commit `5ce2ede`)**

- New `SimmerSmith/.../Features/AIAssistant/` files:
  `AIPageContext.swift`, `AIAssistantCoordinator.swift` (@MainActor
  @Observable), `AIAssistantSheetView.swift`, `AIAssistantOverlay.swift`.
- Global floating sparkle on every tab, `.sheet` with detents 1/3, medium,
  large, background interaction enabled at 1/3. Context chip + contextual
  suggestions in the empty state.
- Each tab/view publishes an `AIPageContext` on `.onAppear` (Week, Recipe
  detail, Recipes list, Grocery). Backend accepts `page_context` per
  message and folds it into the planning system prompt.
- Tool loop now fires whenever a message carries a `week_id` (not just
  `thread_kind="planning"`), so the chat-kind thread + per-message context
  is the new default.
- Error SSE emission now surfaces the real exception detail (was:
  "Assistant request failed. Please try again.") so future failures are
  visible.

**Phase 3 — Shakedown bug fixes (commits `e6938f4`, `9e5f123`, `103d0aa`)**

- `fix(ios): tolerate legacy backends and show real FastAPI validation errors`
  — iOS `APIErrorResponse` now decodes all three FastAPI detail shapes
  (string, validation-error array, object with `message`). Coordinator sends
  `intent: "general"` so `page_context.weekId` is the only planning trigger,
  preventing a 422 against older backends.
- `feat(ai): true token-by-token streaming + fix decoder crash on tool calls`
  — backend uses OpenAI `stream: true`, forwards each `content` delta via
  `assistant.delta` as it arrives. Tool-call deltas accumulate per-index
  across incremental chunks. `AssistantToolCall` iOS decoder now tolerates
  missing `ok`/`detail` on running-state events (the bug that was breaking
  streams mid-turn and producing "Response may be incomplete").
- `fix(api): serialize date objects in tool-call replies to model` —
  `_run_openai_tool_loop` feeds each tool result back to the model; the
  week payload contains `date` objects which plain `json.dumps` rejects.
  Now routes through `jsonable_encoder` first. Regression test added.

### Production state

- **URL**: https://simmersmith.fly.dev (healthy, deploy
  `deployment-01KPNAD0KQQQMX9P1VF8S2SRAN`)
- **Model**: `gpt-5.4-mini` (default in config; no fly override)
- **Secret**: `SIMMERSMITH_AI_OPENAI_API_KEY` set on fly
- **Privacy Policy**: https://simmersmith.fly.dev/privacy
- **TestFlight**: v1.0.0 build 3 (stale — not rebuilt with M6 changes)

### Build status

- Backend: ruff clean, pytest 131/131 pass (6 new assistant tool tests)
- Swift tests: 26/26 pass
- iOS build: green on `generic/platform=iOS Simulator`
- Fly production: healthy, M6 live
- TestFlight: not yet cut with M6

### Open issues (tagged into M7 → "Assistant polish")

- `"cancelled"` error on pull-to-refresh after closing the sheet mid-stream
  (not reproduced yet)
- Model hallucinating tool-like actions without actually calling a tool
  (the "I swapped it" without a tool-call card case)
- Streamed deltas aren't persisted server-side until completion (mid-stream
  refresh shows nothing)
- No cancel path: dismissing the sheet leaves the server turn running
- Anthropic tool-use support (OpenAI-direct only today)
- True per-day AI generation (one call per day) for `generate_week_plan`

## Files Changed (since last session)

Backend:
- `alembic/versions/20260419_0017_assistant_planning_tools.py` (new)
- `app/services/assistant_tools.py` (new)
- `app/services/assistant_ai.py`
- `app/services/assistant_threads.py`
- `app/services/presenters.py`
- `app/api/assistant.py`
- `app/models/ai.py`
- `app/schemas/assistant.py`, `app/schemas/__init__.py`
- `tests/test_assistant_tools.py` (new)

iOS:
- `SimmerSmithKit/Sources/.../Models/SimmerSmithModels.swift`
- `SimmerSmithKit/Sources/.../API/SimmerSmithAPIClient.swift`
- `SimmerSmith/.../App/AppState.swift`, `App/AppState+Assistant.swift`
- `SimmerSmith/.../App/MainTabView.swift`
- `SimmerSmith/.../Features/AIAssistant/*.swift` (4 new files)
- `SimmerSmith/.../Features/Week/WeekView.swift`
- `SimmerSmith/.../Features/Assistant/AssistantView.swift`
- `SimmerSmith/.../Features/Assistant/AssistantToolCallCard.swift` (new)
- `SimmerSmith/.../Features/Recipes/RecipeDetailView.swift`,
  `Features/Recipes/RecipesView.swift`
- `SimmerSmith/.../Features/Grocery/GroceryView.swift`
- Xcode project regenerated (xcodegen)
