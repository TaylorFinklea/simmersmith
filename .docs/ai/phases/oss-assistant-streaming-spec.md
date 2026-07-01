# Spec — Token streaming for the on-device assistant (bead `simmersmith-3sf`)

> AI v2 refinement. Make the CloudKit/on-device assistant token-stream its replies
> instead of chunk-on-complete. `AssistantEngine`'s header already calls this "a drop-in
> refinement later" — the iOS UI already renders incremental `assistant.delta` events.
> Author: Opus (Lead). Implementer: Sonnet 5 per phase.

## Current state (verified 2026-06-30)

- `SimmerSmithCloudKit/Sources/AIProviderKit/AssistantEngine.swift` — `AssistantEngine.run(...)`
  returns `AsyncThrowingStream<AssistantStreamEvent, Error>`; `drive(...)` runs the tool loop.
  On a terminal turn it emits the WHOLE reply as one `assistant.delta` then `assistant.completed`
  (see `finish(...)`, line ~299). Provider capability = `AssistantToolChat.chatWithTools(...) ->
  ToolUseTurn` — **non-streaming** (one POST + parse per iteration).
- `ToolUseTurn` (`BYOKeyProviderTools.swift:114`) = `{ text: String?, toolCalls: [ToolCall],
  finished: Bool, reasoning: ReasoningTrace? }`.
- Per-vendor non-streaming impls: `chatWithToolsOpenAI` / `chatWithToolsAnthropic` /
  `chatWithToolsOpenModels` (`BYOKeyProviderTools.swift`).
- Tests: `AssistantEngineTests.swift` injects a scripted `MockToolChat` (each `chatWithTools`
  dequeues the next `ToolUseTurn`) + a mock runner. Engine is headlessly unit-tested.
- The iOS UI already handles incremental `assistant.delta` (`applyAssistantStreamEvent`), so no
  UI change is needed for incremental rendering — only the engine + providers + the app bridge.

## Phases

### Phase 1 — Engine streaming seam (PACKAGE-ONLY, headless, backward-compatible) ← do first

Add a streaming capability to the provider contract and make `drive` forward incremental text
deltas, with the non-streaming path preserved byte-for-byte via a default implementation. No
vendor SSE yet, no app change, no live keys. Fully `swift test`-verifiable.

**Contract (spec-derived — implement exactly):**

1. New type in AIProviderKit (alongside `AssistantToolChat`):
   ```swift
   public enum ToolUseStreamEvent: Sendable, Equatable {
       /// An incremental chunk of assistant-visible text, forwarded live as `assistant.delta`.
       case textDelta(String)
       /// The fully-assembled turn (text + toolCalls + finished + reasoning). ALWAYS the LAST
       /// event of a turn's stream; the engine runs its tool-loop logic on it.
       case turn(ToolUseTurn)
   }
   ```
2. Add to `AssistantToolChat`:
   ```swift
   func streamWithTools(messages: [AIChatMessage], tools: [ToolSpec], systemPrompt: String?)
       -> AsyncThrowingStream<ToolUseStreamEvent, Error>
   ```
   with a **default protocol-extension implementation** that wraps the existing `chatWithTools`:
   open a stream, `await chatWithTools(...)`, yield exactly `.turn(turn)` (NO `.textDelta`s),
   `finish()`; on throw, `finish(throwing:)`; honor `Task` cancellation via `onTermination`.
   This keeps every existing provider + `MockToolChat` working unchanged.
3. Refactor `AssistantEngine.drive` to consume `provider.streamWithTools(...)` instead of
   `chatWithTools` each iteration:
   - As `.textDelta(s)` arrive: emit `assistant.delta` **live** (via `deltaEvent`) AND append `s`
     to `accumulatedText`; set a per-`drive` flag `didStreamDelta = true`.
   - On `.turn(t)`: run the EXISTING loop logic on `t` (the current `turn` handling — tool calls,
     history append, `finished`, cap). The only change to text handling: when a turn contributes
     text but NO `.textDelta` was streamed for it (the default/non-streaming path), append `t.text`
     to `accumulatedText` as today.
   - `finish(text:)` gains the rule: **if `didStreamDelta` is true, the text was already streamed
     live → emit ONLY `assistant.completed` (content = accumulatedText), do NOT emit a final
     `assistant.delta`. If false (non-streaming/default path), emit the one final `assistant.delta`
     then `assistant.completed` — i.e. EXACTLY today's behavior.**
   - Cancellation (`Task.checkCancellation`) and the iteration cap stay as-is. The per-iteration
     stream must also honor cancellation (cancel the inner stream's task on outer cancel).

**Invariants / acceptance (test these in AssistantEngineTests):**

- BACKWARD-COMPAT: with the existing `MockToolChat` (uses the default `streamWithTools`), every
  current test still passes byte-for-byte — exactly one `assistant.delta` carrying the full reply,
  then `assistant.completed`; tool-call turns, `week.updated`, cap, cancellation all unchanged.
- STREAMING: a new `MockStreamingToolChat` that yields a scripted `[.textDelta("Hel"),
  .textDelta("lo"), .turn(terminalTurn(text:"Hello"))]` produces, IN ORDER: `assistant.delta "Hel"`,
  `assistant.delta "lo"`, then `assistant.completed` (content "Hello") — and NO extra final delta
  duplicating the text.
- STREAMING + TOOLS: deltas streamed on a tool-requesting turn are forwarded live, the tool loop
  still runs (`assistant.tool_call` → `assistant.tool_result` [+ `week.updated`]), and a later
  terminal turn's deltas stream too.
- CANCELLATION mid-stream finishes cleanly (no `completed`, no `error`) — same as today.

**Verify:** `swift test --package-path SimmerSmithCloudKit` exits 0, no `signal code 5`, all
existing AIProviderKit tests + the new streaming tests pass.

### Phase 2.0 — Shared SSE event reader (do FIRST; foundation for 2a/2b/2c) — loop-ready

A pure, synchronous, headless, fixture-testable Server-Sent-Events line parser in AIProviderKit that
the per-vendor `streamWithTools` overrides (2a/2b/2c) will drive to turn a streaming HTTP body into
discrete SSE events. NO networking here — it's a synchronous incremental parser fed one line at a
time, so it unit-tests with plain string fixtures (no async, no generics).

**New file:** `SimmerSmithCloudKit/Sources/AIProviderKit/SSEReader.swift`. Implement exactly:

```swift
/// One parsed Server-Sent Event. `data` is the event's `data:` field line(s) joined with "\n"
/// (per the SSE spec); `event` is the `event:` field if the event carried one.
public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String
    public init(event: String?, data: String) { self.event = event; self.data = data }
}

/// Incremental SSE line parser. Feed lines one at a time (e.g. from `URLSession.AsyncBytes.lines`);
/// `push` returns a completed event when a BLANK line dispatches the accumulated fields, else nil.
/// Call `finish()` at end-of-stream to flush a trailing event that had no closing blank line.
/// Pure + synchronous → trivially testable; the async byte reading lives in the vendor layer (2a+).
public struct SSEParser {
    public init() { }
    /// Framing (SSE spec): `field: value` or `field:value`; a leading single space after the colon
    /// is stripped. `data:` lines accumulate (multiple join with "\n"); `event:` sets the name; a
    /// line beginning with `:` is a comment (ignored); a BLANK line dispatches the event IF it
    /// accumulated any `data` (else resets with nothing emitted). Unknown fields are ignored.
    public mutating func push(_ line: String) -> SSEEvent?
    /// Flush a pending event (data accumulated but no trailing blank line seen). nil if nothing pending.
    public mutating func finish() -> SSEEvent?
}
```

The parser does NOT special-case the OpenAI `[DONE]` sentinel — it emits `SSEEvent(event: nil,
data: "[DONE]")` like any other event; the vendor layer (2a) decides to stop on it.

**Tests** (new `SimmerSmithCloudKit/Tests/AIProviderKitTests/SSEReaderTests.swift`; mirror the
existing `@Test` idiom). Drive the parser by pushing each fixture line and collecting non-nil
returns, then `finish()`. Assert:
1. Two events: push `data: hello` / `` (blank) / `data: world` / `` → `[SSEEvent(nil,"hello"), SSEEvent(nil,"world")]`.
2. Multi-line data joins with "\n": `data: a` / `data: b` / `` → `[SSEEvent(nil,"a\nb")]`.
3. `event:` name: `event: delta` / `data: x` / `` → `[SSEEvent("delta","x")]`.
4. Comment/heartbeat ignored: `: keep-alive` / `` / `data: x` / `` → `[SSEEvent(nil,"x")]`.
5. `[DONE]` sentinel is a normal event: `data: [DONE]` / `` → `[SSEEvent(nil,"[DONE]")]`.
6. Trailing event with NO final blank line: push `data: last`, then `finish()` → `SSEEvent(nil,"last")`.
7. Both `data:x` (no space) and `data: x` (one space) yield "x".

**Verify:** `swift test --package-path SimmerSmithCloudKit` — exit 0, no `signal code 5`, all existing
tests still pass + the new SSEReader tests pass.

**Scope guard:** NEW files only. Do NOT modify AssistantEngine, the providers, or any existing test.
Commit ONLY the new `SSEReader.swift` + `SSEReaderTests.swift` — do NOT stage the pre-existing
`SimmerSmith.xcodeproj/project.pbxproj` (an unrelated uncommitted change).

### Phase 2 — Per-vendor SSE streaming (provider impls; live-key device gate)

Override `streamWithTools` on `BYOKeyProvider` to do real SSE token streaming per vendor:
OpenAI Chat Completions `stream:true`, Anthropic Messages stream
(`content_block_delta`/`input_json_delta`), open-models (GLM/Kimi/MiniMax) SSE. Accumulate
tool-call argument deltas into `ToolCall`s; forward visible-text deltas as `.textDelta`; emit the
final `.turn(...)` with the assembled `ToolUseTurn` (preserving the reasoning-capture contract for
open-models). Unit-test each vendor's SSE parser with recorded fixtures. Real proof = device + live
keys (file a device-verify bead, like the other AI features).

### Phase 3 — App wiring + verification

Confirm `AppState+Assistant` / `AssistantRepository` forward the now-incremental `assistant.delta`
events into the unchanged `applyAssistantStreamEvent` with no buffering that defeats streaming
(the UI already renders incremental deltas). App build + on-device gate (tokens visibly stream from
a live model across OpenAI / Anthropic / each open model).

## Notes

- Phase 1 is the de-risking step: it isolates the intricate stream-aware loop refactor into a
  headless, backward-compatible, fully-tested change. Phases 2-3 are vendor SSE + the app bridge.
- Keep the engine a leaf module (no app-package import) — `ToolUseStreamEvent` lives in AIProviderKit.
- **Phase 1 separator nuance (Phase 2 awareness):** streamed `.textDelta`s are appended to
  `accumulatedText` verbatim (no synthetic separator), whereas the non-streamed fallback keeps the
  original `"\n"`-join between multiple text-bearing turns. So a model that emits text on >1 turn
  could differ slightly in `assistant.completed` content_markdown between the streaming and
  non-streaming paths. Harmless + uncommon (tool-call turns are usually text-empty; the terminal
  turn carries the answer), and the streamed text is the more faithful (exactly what the model
  emitted). Phase 2 vendor impls should emit the model's own newlines as deltas; revisit only if a
  real multi-text-turn case looks wrong on device.
