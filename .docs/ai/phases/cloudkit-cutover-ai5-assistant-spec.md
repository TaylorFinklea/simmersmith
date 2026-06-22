# SP-C — AI track, slice AI-5: The Assistant (tool-calling chat)

> 2026-06-22. Final AI slice + final cutover piece. An on-device tool-calling assistant on the user's BYO
> key, storing conversations in the private plane, executing tools against the CloudKit repos. The UI
> (AssistantView/AssistantThreadView/the AIAssistantSheet + the AssistantStreamEnvelope handling) ALREADY
> exists Fly-backed — this slice replaces the Fly engine with an on-device one emitting the same envelopes.

## 0. Goal + scope
Bring the assistant off Fly: `refreshAssistantThreads`, `fetchAssistantThread`, `createAssistantThread`,
`deleteAssistantThread`, `sendAssistantMessage` (the streaming one). The assistant does things ("plan this
week", "add tacos to Tuesday", "make this vegetarian", "what can I make with chicken?") by calling tools
that execute against the CloudKit repos, on the user's BYO key.

**v1 scope (deliberate):**
- **Engine:** a tool-calling loop (BYO-key, OpenAI + Anthropic tool-use), max 6 iterations (port
  `MAX_TOOL_ITERATIONS`), NON-streaming per provider call for v1 (emit the AssistantStreamEnvelope events
  the UI handles — user_message.created, assistant.tool_call, assistant.tool_result, week.updated, one
  assistant.delta with the final text, assistant.completed/error). Token-by-token streaming is a later
  refinement (the UI already supports deltas, so it's drop-in later).
- **Toolset:** a CURATED ~12-tool v1 (not all 49): recipes_list, recipes_get, recipes_save,
  weeks_get_current, weeks_get, weeks_update_meals, weeks_apply_ai_draft (→ the AI-1 week-gen),
  weeks_regenerate_grocery, recipes_suggestion_draft (→AI-2), recipes_variation_draft (→AI-2),
  pantry_list, grocery_get (read the week's list). Read + the core writes. Each maps to a repo action.
- **Storage:** an `AssistantRepository` over `PrivatePlaneStore` (PrivateAssistantThread/Message — exist).
- **OUT/defer:** exports/pricing/feedback tools, web-search tool (AI-2-deferred), token streaming, the full
  49-tool set — flag as follow-ons.

## 1. Design decisions (Lead, from the map)
- **Provider tool-use, non-streaming per call.** Extend BYOKeyProvider with a tool-use call: OpenAI
  `chat/completions` with `tools:[{type:"function",function:{name,description,parameters}}]` → response with
  `tool_calls` or final text; Anthropic `messages` with `tools:[{name,description,input_schema}]` → content
  blocks (text + tool_use), `stop_reason` tool_use/end_turn. Port the message/tool-result shapes from
  `assistant_ai.py` (OpenAIAdapter/AnthropicAdapter). The loop calls this each iteration.
- **The loop** (port `_run_provider_tool_loop`): build messages (system + history + user) + the tool specs →
  provider call → if tool_calls: emit tool_call (running), run the tool-runner, emit tool_result (+
  week.updated if a week changed), append the assistant turn + tool results to messages, loop; if final
  text: emit it as one assistant.delta + completed. Max 6 iters. Honor a cancellation token.
- **Tools execute @MainActor against the repos.** A `ToolRegistry` — each tool: name + description +
  JSON input_schema + an async execute(args) → a JSON-encodable result (port the MCP tool I/O shapes). The
  runner dispatches by name. Writes go through the repos (saveWeekMeals/save/regenerateGrocery/the AI-1/AI-2
  paths) so CloudKit + grocery stay correct. Read tools return repo data as JSON.
- **System prompt** ported from `assistant_ai.py` (the assistant's role + household context + tool-use
  guidance). Keep it faithful.
- **Re-gate:** `assistantExecutionAvailable` → true iff a BYO key exists for the configured provider
  (KeychainKeyStore), replacing the aiCapabilities/hasSavedConnection Fly check. Un-gate the assistant UI
  (the .assistant tab + the sparkle launchers + RecipeDetailView "Ask Assistant") for CloudKit-only.

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| BYOKeyProvider tool-use | modify (AIProviderKit) | OpenAI + Anthropic tool-use call (messages + tool specs → text + tool_calls); the message/tool-result encoders; non-streaming. Inject transport; test the request bodies + the tool_call parse. |
| `AssistantEngine` | new (app or AIProviderKit) | the tool-calling loop (max 6); takes the provider + a tool-runner + a cancellation token; emits `AssistantStreamEnvelope` events as an AsyncThrowingStream (the UI's existing shape). |
| `ToolRegistry` + tools | new (app Data/) | the ~12 curated tools: name/description/input_schema + execute against the repos. A tool-runner `(name, argsJSON) async -> resultJSON`. |
| `AssistantRepository` | new (app Data/) | over PrivatePlaneStore: list threads, create/delete thread, fetch thread+messages, append message. Projects PrivateAssistant* ⇄ the iOS AssistantThread/Summary/Message domain types. |
| `AppState+Assistant` rewire | modify | refresh/fetch/create/delete → AssistantRepository; sendAssistantMessage → store the user msg + run AssistantEngine, forwarding its envelopes into the EXISTING `applyAssistantStreamEvent` handler. Persist the assistant message + tool calls. |
| re-gate + un-gate | modify | `assistantExecutionAvailable` → BYO-key check; un-gate the assistant UI for CloudKit-only. |

## 3. Reuse / do-not-rebuild
- The assistant UI (AssistantView/AssistantThreadView/AIAssistantSheet) + the `AssistantStreamEnvelope`
  model + `applyAssistantStreamEvent` — the engine emits into this; DON'T rebuild the UI.
- PrivatePlaneStore (upsertAssistantThread/Message, messages(forThreadID:)) — the storage primitives.
- AIService/BYOKeyProvider/KeychainKeyStore — the BYO-key seam (extend for tool-use).
- The repos (Recipe/Week/Grocery/Pantry) — the tools call them; AI-1 week-gen + AI-2 drafts for the AI tools.
- The iOS domain types AssistantThread/Summary/Message/StreamEnvelope — keep.

## 4. Verification
- **Headless:** the BYOKeyProvider tool-use request bodies (OpenAI + Anthropic, with tool specs) + parsing a
  tool_call from a sample response; the AssistantEngine loop over a MOCK provider (a scripted response that
  asks for a tool, then finishes) + a mock runner → asserts the envelope sequence (tool_call→tool_result→
  delta→completed) + max-iter cap + cancellation; a couple of tool executes (a read tool returns repo JSON).
- **On-device (TestFlight):** with a BYO key, open the assistant → "what recipes do I have?" (recipes_list)
  → it answers; "plan this week" (weeks_apply_ai_draft → week-gen) → the week fills + grocery regenerates;
  "add a vegetarian pasta to Tuesday" → a meal is added; the thread persists (private plane) + reappears on
  relaunch; no-key → the setup prompt, not a crash.

## 5. Risks
- **Tool-use loop correctness** — the #1 risk: the provider tool-use mechanics differ (OpenAI vs Anthropic);
  the message/tool-result threading must be right or the loop breaks. Port the adapters faithfully; test the
  loop over a mock.
- **Tool WRITES must go through the repos** (not bypass CloudKit/grocery) — a write tool that edits a week
  must call WeekRepository.saveWeekMeals (grocery regenerates). Don't let a tool corrupt state.
- **Runaway loops / cost** — cap at 6 iterations; each iteration is a BYO-key call (cost). The cancellation
  token (sheet dismiss) must stop the loop.
- **Curated toolset** — v1 is ~12 tools; flag the deferred ones (exports/pricing/web-search/full set) as
  follow-ons so it's not mistaken for full parity.
- **No new CloudKit types** (PrivateAssistant* exist; conversations are private-plane) → no schema deploy.
