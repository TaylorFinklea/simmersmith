# Phase Spec: Conversational Planning (M6)

## Why this, why now

The AI is the marketed star of SimmerSmith, but the two surfaces where a user talks to it are both broken in opposite directions:

- **Week-page sparkle → "Plan My Week"** is *one-shot*. You type a prompt, wait 30–60 seconds, and get 21 meals. If one is wrong, your only levers are "swap this meal", "rebalance this day", or "regenerate the whole week." There is no dialogue. The AI has no idea you pushed back on Tuesday's lunch.

- **Assistant tab** is *isolated*. It has threads, it has tools, but it **cannot see the current week**, cannot add a meal to it, cannot fetch pricing, cannot set a goal, cannot rebalance. It's a general-purpose chatbot glued onto a meal planner. Users who want to "tell the AI what they want for the week" have to use the Week sparkle (one-shot) or go to Assistant and copy-paste the result back themselves.

M6 fixes both at once by giving the Assistant **tool access to the week** and turning the Week page into an execution view of what the Assistant built.

## Goal

One conversation drives a week. The user opens Assistant, types "plan me a higher-protein week but keep Tuesday light because we eat out," and the AI does it — live. Each meal appears in the Week page as it gets produced. If the user wants a change, they say so in chat and the Week updates. The Week page becomes the *receipt* of the conversation, not the *origin* of it.

Concretely:

- Assistant can **read** current week state (meals, macros, grocery, dietary goal, preferences, pricing) on demand
- Assistant can **write** to the week via tools: add/swap/remove meals, rebalance a day, regenerate the whole week, fetch Kroger prices, set the dietary goal, attach a recipe
- The Week page sparkle becomes "Plan with AI" → opens Assistant with a pre-seeded system message that knows the current week
- Each day's Today hero + day-card gets a tiny "Ask AI" affordance that opens Assistant with that day in context
- Incremental updates: the AI streams one meal at a time into the week rather than dumping 21 at the end
- The Assistant's "quick prompts" are now week-aware (e.g. "rebalance Wednesday's dinner for more protein")

This is M6 because it collapses M1 (preference-aware planning) + M4 (nutrition/rebalance) + the existing Assistant thread into one coherent experience. Nothing in M5 (paywall) blocks it — the tools are gated the same way the HTTP endpoints are.

## Scope

Backend + iOS. Substantial work on both. Expected as two or three shippable sub-phases so the user can test progress.

**In scope**:
- New backend tool registry with JSON schemas for each tool the Assistant can call against the week
- A structured tool-call loop in the assistant response endpoint (the model calls a tool → backend runs it → model sees the result → continues)
- Week snapshot injected into the Assistant's system prompt at thread start / message time
- iOS Assistant UI to render tool-call cards ("Generating 7 meals…", "Added Salmon Tacos to Tuesday dinner")
- Week page gets an "Ask AI" entrypoint + a live indicator when the AI is modifying the current week
- Streaming edits to `currentWeek` so the iOS UI can optimistically reflect pending changes

**Not in scope**:
- Cross-week planning (e.g. "plan next month"). One week per thread for now.
- Household / multi-user conversations. Single user only.
- Voice. Text only.
- Grocery-list editing via chat (covered by meal edits — the list is derived).
- Recipe authoring via chat beyond linking existing recipes. New-recipe creation already lives under `Create Recipe with AI`.
- Replacing the sparkle button. Sparkle stays as a fast path; Assistant is the rich path.

---

## Architecture

### 1. Tool registry

**New file**: `app/services/assistant_tools.py`

```python
class AssistantTool(Protocol):
    name: str
    description: str
    parameters_schema: dict  # JSON Schema
    def run(session, user_id, current_week, args) -> AssistantToolResult: ...
```

Ship with:

| Tool | Mutates week? | Gated action |
|------|---------------|--------------|
| `get_current_week` | no | — |
| `get_dietary_goal` | no | — |
| `get_preferences_summary` | no | — |
| `generate_week_plan` | yes (replaces) | `ai_generate` |
| `add_meal` | yes | — |
| `swap_meal` | yes | — |
| `remove_meal` | yes | — |
| `set_meal_approved` | yes | — |
| `rebalance_day` | yes (replaces day) | `rebalance_day` |
| `fetch_pricing` | yes (adds retailer_prices) | `pricing_fetch` |
| `set_dietary_goal` | no (profile) | — |

Each tool returns `{ok: bool, detail: str, week?: dict}` — when it mutates, include the fresh `week_payload` so the streaming transcript can emit a week-updated event.

### 2. Streaming tool loop

**File**: `app/services/assistant.py` (existing) + `app/services/assistant_tools.py` (new)

Replace the single AI call with:
```
loop:
  response = ai.send(system, history, tool_definitions)
  if response.is_final_text: break
  for tool_call in response.tool_calls:
    result = registry[tool_call.name].run(...)
    history.append(tool_call_message(tool_call, result))
  if iterations > 6: break  # safety
```

For providers that don't expose tool calling (older MCP servers), fall back to a structured JSON output the model produces (we already have this shape for week generation). Document both paths.

The existing SSE stream now carries three new event types in addition to `delta` / `error`:
- `tool_call` — `{name, args}` so the iOS client can render "Generating 7 meals…"
- `tool_result` — `{name, ok, detail}` so the iOS client can finish the card
- `week_updated` — `{week: WeekOut}` so every connected view refreshes without an explicit GET

### 3. Week context injection

**File**: `app/services/assistant.py`

Before each user message is dispatched, append a compact week snapshot to the system prompt: week_start, approved/draft status, per-day meals (slot + recipe_name + approved), dietary goal, drift flags, grocery count. The AI gets ~600 tokens of current state so it can answer "what's for Tuesday dinner?" without tool-calling.

### 4. Thread context policy

Assistant threads gain an optional `linked_week_id` column. When set, tool calls scope to that week; when null, the tools default to the user's current week (`get_current_week`). A thread started from the Week page's "Ask AI" entry point sets `linked_week_id` to the visible week.

**Alembic migration** to add the column, nullable, no default.

### 5. 402 gating through tools

The existing HTTP endpoints use `ensure_action_allowed` + `increment_usage`. The tool registry reuses the exact same calls, so gated tools either succeed (and bump the counter) or return `{ok: false, detail: "You've hit your free-tier limit…"}` which the AI sees and can mention to the user. Paywall still surfaces in the iOS UI via the usage summary on the next profile refresh.

### 6. iOS Assistant UI

**Files**:
- `SimmerSmith/SimmerSmith/Features/Assistant/AssistantView.swift` — extend to render tool-call cards inline with messages
- New `SimmerSmith/SimmerSmith/Features/Assistant/AssistantToolCallCard.swift` — icon + label + live progress
- `SimmerSmith/SimmerSmith/App/AppState+Assistant.swift` — new stream handlers for `tool_call` / `tool_result` / `week_updated`; `week_updated` reaches into `AppState.currentWeek` directly

Tool cards show:
- Icon (⚡ for generate, ♻️ for rebalance, 🛒 for pricing, etc.)
- One-line description
- Live "running…" state → final "Added 3 meals" / "Couldn't find Kroger store" state

### 7. Week page entry points

**File**: `SimmerSmith/SimmerSmith/Features/Week/WeekView.swift`

- **Sparkle (top right of hero)** — long-tap or secondary action → "Plan with AI in chat" → opens Assistant with `linked_week_id` set and an initial message "Plan this week for me — I have [preferences]."
- **Each day card** — an optional "Ask AI" icon next to the macro ring that deep-links into Assistant with day context.
- **Active-chat banner** — when an Assistant thread has a running tool call that's touching the current week, the Week page shows a tiny "AI is editing this week…" chip so the user knows where the changes are coming from.

### 8. Prompt engineering

**File**: `app/services/assistant_prompts.py` (new)

Dedicated system prompt templates that explain:
- The tools that are available this turn
- The current week's state (mini table of day × slot × recipe)
- The dietary goal + any drift flags
- Explicit instructions: prefer tool calls over describing actions ("when the user asks you to add something, call `add_meal`; don't just say you'll add it")
- The "stop when the user is happy" pattern (don't infinitely tool-call)

Ship an A/B'able version keyed on settings so we can tweak without a redeploy.

---

## Acceptance criteria

Backend:
- [ ] New `assistant_tools` registry with 11 tools; each has a JSON schema; each unit-tested
- [ ] Tool-call loop stops at 6 iterations max; logs every call + result; respects the M5 gate
- [ ] SSE stream emits `tool_call` / `tool_result` / `week_updated` events with the shapes above
- [ ] `generate_week_plan` tool produces meals incrementally (one day at a time) so the client can render progress
- [ ] 96 existing tests + new tests all pass; existing Assistant threads without linked_week still work
- [ ] `linked_week_id` migration applies cleanly on Postgres

iOS:
- [ ] Assistant thread shows tool-call cards inline with message bubbles
- [ ] Starting an Assistant thread from Week page's "Ask AI" creates a linked thread that auto-greets with the current week's context
- [ ] Asking "what's for Wednesday dinner?" in an empty thread works — no tool call needed; the AI answers from the injected week snapshot
- [ ] Asking "make Tuesday higher protein" triggers a `rebalance_day` tool call; the day updates on the Week page mid-sentence
- [ ] Week page shows a "AI is editing this week…" chip while a linked thread has a running tool call
- [ ] Tool failures (e.g. Kroger down) render as a red-accent card, and the AI narrates the fallback ("I couldn't fetch prices right now — do you want me to try again?")

End-to-end:
- [ ] From a fresh week, a single 5-message chat can plan + approve a week + fetch prices — no Week-page button taps required
- [ ] Same chat on a sandbox Pro account works; on free tier the 402-on-tool-call produces a paywall suggestion from the AI and the iOS `ensure_action_allowed` counter still bumps consistently

---

## Sequencing (recommended)

1. **M6.1 — Tool registry + gate reuse** (~1 session). Stand up `assistant_tools.py`, implement read-only tools (`get_current_week`, `get_dietary_goal`, `get_preferences_summary`), wire into the existing assistant response endpoint behind a feature flag. Ship.
2. **M6.2 — Mutation tools** (~2 sessions). `add_meal`, `swap_meal`, `remove_meal`, `set_meal_approved`, `set_dietary_goal`, `fetch_pricing`, `rebalance_day`. Each gated exactly like the HTTP endpoint equivalent. Tests.
3. **M6.3 — `generate_week_plan` incremental** (~1 session). Replace the one-shot week planner with a day-by-day streamer. Emit `week_updated` events after each day.
4. **M6.4 — System prompt rewrite + week context injection** (~1 session). Ship the new prompts; A/B flag gating.
5. **M6.5 — iOS tool-call card + SSE handlers** (~1-2 sessions). Render tool calls + results inline; reactively update `currentWeek` on `week_updated` events.
6. **M6.6 — Week → Assistant entrypoints** (~1 session). Long-tap sparkle, Ask-AI day button, active-chat chip. Cleanup pass.

Each step leaves the app in a working state. After M6.1 the user can talk to the Assistant and it *knows about their week*; after M6.2 it can *edit* the week; after M6.5 the UI reflects edits live.

---

## Risks

- **Model tool-calling variance**. OpenAI + Anthropic support native tool calls, but our MCP fallback may not. Ship structured-JSON fallback that follows the same schema, at the cost of occasional format slips. Instrument tool-call success rate in logs.
- **Race conditions on currentWeek**. If a chat mutates the week while the user is also tapping Week-page controls, the last-write-wins model can surprise users. Mitigation: `week_updated` events reach the iOS client first and the UI animates the change, making "something changed" obvious. Server reloads `week` on every tool call so no stale state is written.
- **Runaway tool loops**. A model that keeps calling tools forever burns tokens and time. Hard cap at 6 iterations; server logs + aborts.
- **Context window**. Injecting the full week into every system prompt is ~600 tokens; adding conversation history could push past model limits on long threads. Trim old messages past 20 turns; keep the week snapshot.
- **Paywall-in-chat UX**. If the AI hits the gate and narrates the paywall, the user might feel gamified. Keep the language short and factual: "Rebalancing is a Pro feature — want me to suggest it anyway?"
- **Regression on existing Assistant threads**. Feature-flag the new tool path so threads created before M6 keep their current behaviour until we migrate them.

---

## Out of scope (parked)

- Multi-week planning ("build out next month")
- Household / multi-user chat
- Voice / dictation
- Custom tool authoring (users can't add tools)
- AI actions on grocery list items (edit name, swap brand) — derive from meal edits
- Recipe authoring via chat beyond linking existing recipes
- Analytics dashboard for tool-call success rate
