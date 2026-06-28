# Open-Model AI Providers (GLM-5.2 / Kimi-K2.6 / MiniMax-M3) — Spec

**Status:** approved design, pre-plan. Authored 2026-06-28 (Opus) from an adversarially-verified research workflow (12 agents: per-vendor primary-source research + verify, canonical reasoning-replay reference, 3 code-seam maps, synth, critique). Critique verdict was `needs-revision` with 5 precision fixes — all folded in below (see **§13 Adversarial review applied**).

**Goal:** Add an "Open models" BYO-key provider spanning **GLM-5.2 (Z.ai)**, **Kimi-K2.6 (Moonshot)**, **MiniMax-M3 (MiniMax)** via **direct per-vendor keys**, surfaced as **one** Settings "Open models" entry with a vendor-spanning model dropdown, available across **every** AI feature **including the 12-tool assistant**, with **full reasoning preservation** in the multi-turn tool loop.

**Non-goals (v1):** OpenRouter/aggregator routing; China-region hosts; Anthropic-compatible endpoints for these vendors; `json_schema` strict mode; MiniMax image input; per-use-case model routing (separate future effort).

---

## 1. Approved product decisions (from brainstorming)

- **Direct vendor keys** (not an aggregator). One key per vendor, in Keychain.
- **One "Open models" Settings entry** whose model dropdown spans all three vendors; the selected *model* determines which vendor key + base URL is used.
- **Default/first-class models:** GLM-5.2, Kimi-K2.6, MiniMax-M3 (others may appear in the dropdown via fallback lists but these three are the named set).
- **All features incl. the assistant**, with **full reasoning preservation** (the user explicitly chose this over the disable-thinking-in-the-loop hybrid).

## 2. Architecture overview

All three vendors are driven on their **OpenAI-compatible `/chat/completions`** endpoints (verified: the better-documented, signature-free reasoning path for each). The binary OpenAI/Anthropic dispatch is generalized via a **`ProviderDescriptor` registry**; a vendor-agnostic **`ReasoningTrace`** is captured on each provider turn, stored on assistant history inside the loop, and re-serialized per-vendor on the next request.

**Two reasoning regimes, split by call shape** (this is NOT the rejected hybrid — it preserves reasoning exactly where vendors require it):

1. **One-shot structured calls** (`generate()` features: week-gen, recipe/event drafts, `wantsStructuredJSON`): thinking **disabled** per vendor for clean JSON. No multi-turn continuity ⇒ no reasoning to preserve.
2. **Assistant tool loop** (`chatWithTools` → `AssistantEngine.drive`): thinking **enabled**, reasoning **captured + replayed verbatim every iteration**. This is the only place vendor docs require replay (within one tool-call task).

**Critical seam (verified):** cross-user-turn history is rebuilt from persisted `contentMarkdown` only (`SimmerSmith/SimmerSmith/App/AppState+Assistant.swift:176-186`), so reasoning **never needs to survive persistence** — the load-bearing replay is purely in-memory inside `AssistantEngine.drive` (`AssistantEngine.swift:213-286`). **No CloudKit schema migration.**

The descriptor registry **does not** fold in OpenAI/Anthropic — their existing switch-based methods stay untouched (zero regression surface); only the new `.openModels` arm routes through descriptor-driven code.

## 3. Data model changes

All new types live in **AIProviderKit** (`SimmerSmithCloudKit/Sources/AIProviderKit/`).

**3.1 Reasoning carrier** — add to `AIProvider.swift` next to `AIRequest`/`AIResponse`:

```swift
public enum ReasoningStyle: String, Sendable, Equatable {
    case none              // no reasoning captured / thinking disabled
    case reasoningContent  // GLM, Kimi: plaintext reasoning_content string is the whole state
    case reasoningDetails  // MiniMax split=true: reasoning_content + verbatim reasoning_details array
    case signedBlock       // RESERVED (Anthropic-style block+signature); not implemented for OSS vendors
}

public struct ReasoningTrace: Sendable, Equatable {
    public var style: ReasoningStyle
    public var text: String?          // reasoning_content verbatim (replay-critical: GLM/Kimi/MiniMax)
    public var detailsJSON: String?   // MiniMax reasoning_details array re-encoded to a JSON string
    public var signature: String?     // signedBlock only; nil for OSS vendors
    public init(style: ReasoningStyle = .none, text: String? = nil, detailsJSON: String? = nil, signature: String? = nil)
    public var isEmpty: Bool { style == .none || ((text?.isEmpty ?? true) && (detailsJSON?.isEmpty ?? true)) }
}
```

**3.2 `CloudModel`** (`AIProvider.swift:30-33`) — add a case; keep existing cases:

```swift
public enum OpenModelVendor: String, Sendable, Equatable, CaseIterable { case glm, kimi, minimax }
public enum CloudModel: Sendable, Equatable {
    case openAI, anthropic, gemini
    case openRouter(String)
    case openModels(OpenModelVendor)   // NEW
}
```

**3.3** `ToolUseTurn` (`BYOKeyProviderTools.swift:108-118`) — add `public var reasoning: ReasoningTrace?` (default `nil`), set in both parsers.
**3.4** `AIChatMessage` (`BYOKeyProviderTools.swift:19-48`) — add `public var reasoning: ReasoningTrace?` (default `nil`); the `.text(...)` helper leaves it nil.
**3.5** `AIResponse` (`AIProvider.swift:64-68`) — add `public var reasoning: ReasoningTrace? = nil` (defaulted; **optional/telemetry**, not load-bearing). Auto-synthesized `Equatable` still holds — confirm no test asserts `AIResponse` equality in a way that now distinguishes nil vs populated reasoning.
**3.6** `AIRequest` — **no** new reasoning field. Prior reasoning travels only inside the `messages: [AIChatMessage]` array. Thinking on/off is decided by **call shape + descriptor**, not a request flag (the one-shot vs tool-loop distinction already exists structurally: `generate()` vs `chatWithTools()`).

## 4. ProviderDescriptor registry

New file `SimmerSmithCloudKit/Sources/AIProviderKit/ProviderDescriptor.swift` — single source of truth for the three new vendors.

```swift
public struct ProviderDescriptor: Sendable {
    public let vendor: OpenModelVendor
    public let id: String              // "glm" | "kimi" | "minimax"
    public let displayName: String     // "GLM (Z.ai)" | "Kimi (Moonshot)" | "MiniMax"
    public let keychainKeyID: String   // "zai" | "moonshot" | "minimax"
    public let chatURL: String         // FULL /chat/completions path (avoids GLM "/v1 appended -> 404")
    public let modelsURL: String?      // /models if supported, else nil -> static fallback only
    public let defaultModel: String    // "glm-5.2" | "kimi-k2.6" | "MiniMax-M3"
    public let fallbackModels: [String]
    public let reasoningStyle: ReasoningStyle
    public let applyThinkingEnabled: @Sendable (_ body: inout [String: Any], _ model: String) -> Void
    public let applyThinkingDisabled: @Sendable (_ body: inout [String: Any], _ model: String) -> Void
    public let toolLoopTemperature: Double   // GLM 0.3, Kimi 1.0 (HARD), MiniMax 0.3
    public let oneShotTemperature: Double    // GLM 0.7, Kimi 0.6 (non-thinking HARD), MiniMax 0.7
}

public enum ProviderRegistry {
    public static func descriptor(for vendor: OpenModelVendor) -> ProviderDescriptor
    public static func vendor(forKeychainID id: String) -> OpenModelVendor?   // "zai" -> .glm, etc.
    public static let allOpenModelVendors: [OpenModelVendor] = OpenModelVendor.allCases
}
```

- Auth is **uniform `Authorization: Bearer <key>`** for all three (verified) — no auth-scheme field.
- Hosts are **international**: `api.z.ai`, `api.moonshot.ai`, `api.minimax.io`. China hosts out of scope (§12).
- `chatURL` is the **full** `/chat/completions` URL (GLM landmine: appending `/v1` → 404).
- **Sendable is valid** (verified): all stored props are Sendable; the `@Sendable (inout [String:Any], String) -> Void` closures are fine (the constraint is on the closure value, the non-Sendable `inout` param is passed synchronously, never captured across isolation).

## 5. Per-vendor handling (with MUST-VERIFY-IN-CODE flags)

All three: OpenAI-compatible `/chat/completions`, Bearer auth, OpenAI-shape `tools[]`/`tool_calls`/`{role:"tool"}` (already what `BYOKeyProviderTools` emits). Differences: base URL, keychain key, model id, the `thinking` param, the reasoning field(s), temperature.

**GLM-5.2 (Z.ai)** — keychain `zai`, `https://api.z.ai/api/paas/v4/chat/completions`, models `…/paas/v4/models`.
- Tool loop body: `thinking:{type:"enabled", clear_thinking:false}`. `clear_thinking:false` = **Preserved Thinking**, which makes replay **mandatory** (verified-conditional: required *only* under `clear_thinking:false`; we deliberately choose false for full preservation).
- Capture: `choices[0].message.reasoning_content` (String) → `style=.reasoningContent`.
- Replay: re-emit `reasoning_content` verbatim on the assistant tool-call message.
- **MUST-VERIFY-IN-CODE:** (a) the standard `/paas/v4` endpoint honors `clear_thinking:false` + `reasoning_content` replay **without a signature** on a live key; (b) do **NOT** send `reasoning_effort` in v1 (GLM-5.2-only, enum mapping uncertain); (c) **never** use `json_schema` — week-gen uses `response_format:{type:"json_object"}` + thinking disabled.
- One-shot: `thinking:{type:"disabled"}`, `response_format json_object`, temp 0.7.

**Kimi-K2.6 (Moonshot)** — keychain `moonshot`, `https://api.moonshot.ai/v1/chat/completions`, models `…/v1/models`.
- Tool loop body: `thinking:{type:"enabled", keep:"all"}` **AND `temperature` MUST be 1.0** (verified HARD constraint: thinking mode uses fixed temp 1.0, other values error). This **collides** with the loop default 0.3 — `descriptor.toolLoopTemperature=1.0` overrides (see §6 and the explicit T5 instruction).
- Capture: `choices[0].message.reasoning_content` (String) → `style=.reasoningContent`.
- Replay: re-emit `reasoning_content` on the assistant tool-call message every iteration.
- Failure if omitted: **HTTP 400 "reasoning_content is missing …"**. **MUST-VERIFY-IN-CODE:** detect on substring `"reasoning_content is missing"`; the literal `"at index N"` is community-sourced — never hardcode it.
- `tool_choice`: only `none`/`auto`/`null` (we send `auto` — fine).
- One-shot: `thinking:{type:"disabled"}`, temp 0.6 (non-thinking HARD), `response_format json_object`. **MUST-VERIFY-IN-CODE:** content stays pure JSON under thinking-disabled (extract-JSON fallback covers it).

**MiniMax-M3** — keychain `minimax`, `https://api.minimax.io/v1/chat/completions`, models `…/v1/models` (**MUST-VERIFY** models endpoint exists; else fallback list only).
- Tool loop body: `thinking:{type:"adaptive"}` **AND `reasoning_split:true`**. On the OpenAI path, literal `{type:"enabled"}` is undocumented — use `"adaptive"` (verified) or omit; `"enabled"+budget_tokens` is Anthropic-only. `reasoning_split:true` splits reasoning OUT of `content` into `reasoning_content` + `reasoning_details`, avoiding the inline-`<think>`-in-content JSON trap.
- Capture: `reasoning_content` (String) + `reasoning_details` (array → re-encode to `detailsJSON`) → `style=.reasoningDetails`.
- Replay: re-emit the **whole assistant message including `reasoning_details`** verbatim (verified). Replay `content`, `reasoning_content`, `reasoning_details`, `tool_calls`.
- Omission **degrades silently** (no hard 400 on the OpenAI path) into looping/dropped-plan tool use — the trap the repo already hit by stripping `<think>`. Keep the UI-stripped copy separate from the raw replay copy (`ReasoningTrace` stores raw; UI only ever sees `turn.text`).
- One-shot: `thinking:{type:"disabled"}`. **`response_format` is UNRELIABLE on M3** — week-gen relies on **prompt-carried JSON contract + `extractJSONObject` (strip fence + strip `<think>`)**, not `response_format`. **MUST-VERIFY-IN-CODE:** whether M3 honors `json_object` at all; default to NOT sending it and parsing defensively.
- Temp: 0.3 tool loop / 0.7 one-shot.

## 6. Reasoning replay design (the heart)

Capture → store → replay; vendor-agnostic in the loop, per-vendor only at the serialization boundary.

**CAPTURE** (parsers, `BYOKeyProviderTools.swift`). Add `parseOpenModelsToolTurn(json, style:)` mirroring `parseOpenAIToolTurn` (text + tool_calls + finish_reason) **plus**:
- `.reasoningContent` (GLM, Kimi): `reasoning = (message["reasoning_content"] as? String).map { ReasoningTrace(style:.reasoningContent, text:$0) }`.
- `.reasoningDetails` (MiniMax): capture `reasoning_content` **and** re-serialize `message["reasoning_details"]` (array) to a JSON string via `JSONSerialization`; `reasoning = ReasoningTrace(style:.reasoningDetails, text:rc, detailsJSON:detailsStr)`.
- Construct `ToolUseTurn(text:, toolCalls:, finished:, reasoning:)`.

**STORE** (`AssistantEngine.swift:239-241`) — the one-line load-bearing fix:
```swift
messages.append(AIChatMessage(role: .assistant, text: turn.text, toolCalls: turn.toolCalls, reasoning: turn.reasoning))
```
In-memory only (`messages` is the loop-local array, line 213). No persistence change; the UI/persistence path still stores only `turn.text`/`contentMarkdown` — reasoning is intentionally **not** persisted (matches every vendor's single-task replay requirement; dodges a CloudKit migration).

**REPLAY** (encoder, `BYOKeyProviderTools.swift`). Add `encodeOpenModelsMessages(messages, systemPrompt, vendor)` mirroring `encodeOpenAIMessages`, but on an assistant turn with tool calls **and** a non-empty reasoning trace, inject the vendor's reasoning fields onto the **same** assistant message object that carries `tool_calls` (research: reasoning rides on the assistant message; **presence** matters, field order does not):
```swift
var entry: [String:Any] = ["role":"assistant","tool_calls":calls]
entry["content"] = (msg.text?.isEmpty == false) ? msg.text! : NSNull()
if let r = msg.reasoning, !r.isEmpty {
    switch r.style {
    case .reasoningContent: entry["reasoning_content"] = r.text                 // GLM, Kimi
    case .reasoningDetails:                                                      // MiniMax
        entry["reasoning_content"] = r.text
        if let d = r.detailsJSON, let arr = try? JSONSerialization.jsonObject(with: Data(d.utf8)) { entry["reasoning_details"] = arr }
    case .signedBlock, .none: break
    }
}
```
Tool results still emit as `{role:"tool", tool_call_id, content}` (lines 210-219); assistant-turn-then-tool-results ordering is already correct.

**Preservation guarantee, stated honestly:** `reasoning_content` (a String) is byte-exact. `reasoning_details` round-trips through `JSONSerialization` (parse→serialize→parse→serialize), so it is **structurally/semantically preserved, not byte-identical** — acceptable because the OpenAI path carries no signature to validate against. Tests assert **parsed-object equality**, not string equality.

**THINKING/TEMPERATURE injection** happens in the new `chatWithToolsOpenModels(...)` via `descriptor.applyThinkingEnabled(&body, model)` and `descriptor.toolLoopTemperature` — all in one place. **Kimi temperature override (critical):** `chatWithToolsOpenModels` is invoked through the `AssistantToolChat` conformance which **hardcodes `temperature: 0.3`** (`BYOKeyProviderTools.swift:107`, called by `AssistantEngine.drive:221-223`). The openModels arm **MUST ignore the incoming `0.3` and substitute `descriptor.toolLoopTemperature`** (Kimi=1.0). This is the single highest-risk silent failure.

## 7. Settings UX

One "Open models" provider entry with a vendor-spanning model dropdown (not three sibling sections). `SettingsView.swift:66-94`:
1. Add a 4th provider-picker tag: `Text("Open models").tag("openmodels")`.
2. When `aiDirectProviderDraft == "openmodels"`, render a **single** vendor-spanning Model picker (new `OpenModelsPickerRow`, or a variant of `AIModelPickerRow`): options = union of the three vendors' models, **SwiftUI `Section` per vendor**, each row labeled `"<displayName> · <modelId>"`, tag = composite `"<vendor>:<modelId>"` (e.g. `"glm:glm-5.2"`). Selecting a row sets **both** the vendor and model drafts.
3. Below the dropdown, show the key field for **the selected model's vendor only** (dynamic `SecureField` + key-status `HStack`, reuse the Gemini-image-key pattern at `SettingsView.swift:185-208`). Switching to a different vendor's model re-targets that vendor's Keychain entry. One entry, but the user keys all three over time (select model → enter that vendor's key → Save).
4. Save / Test Key / Clear operate on the selected vendor's keychain key.

Drafts (`AppState.swift` near 151-163): add `aiOpenModelsVendorDraft: String = ""` (`glm|kimi|minimax`) and `aiOpenModelsModelDraft: String = ""`. Reuse `ckAIModelOptions`/`isFetchingAIModels`/`ckAIModelFetchError` dictionaries keyed by vendor keychain id (`zai`/`moonshot`/`minimax`). `AIModelPickerRow.swift` savedDraft getter/setter (29-39) routes `provider=="openmodels"` to `aiOpenModelsModelDraft`; `fetchKey` (78-80) keys off the selected vendor's keychain id.

Footer: each vendor needs its own key, entered by selecting that vendor's model first; keep the "stored in this device's Keychain, never sent to our servers" reassurance.

## 8. Persistence

Provider-keyed, extending the private-plane `PrivateProfileSetting` + Keychain split. **No CloudKit schema change.**

- Private-plane keys (`AIService.swift:28-30`): `ai_direct_provider` now also accepts `"openmodels"`; add `keyOpenModelsVendor = "ai_openmodels_vendor"` and `keyOpenModelsModel = "ai_openmodels_model"` (two keys, mirroring `ai_openai_model`/`ai_anthropic_model` — independently editable, not a packed `"vendor:model"`).
- Keychain (`KeychainKeyStore`, generic by string — `KeyStore.swift:6-8`): per-vendor keys `zai`/`moonshot`/`minimax`, zero-cost.
- `saveAISettings` (`AppState+AI.swift:21-95`): for `openmodels`, upsert the two new keys and save the API key to the **selected vendor's** keychain id (`descriptor.keychainKeyID`). Keep `ai_direct_provider="openmodels"`.
- `loadAISettings` (`AIService.swift:188-197`): **define the new return shape explicitly** (today `(provider, openAIModel, anthropicModel)`; extend to also carry `openModelsVendor`/`openModelsModel`, e.g. a small struct) so `syncAIDraftsFromRepo` (`AppState+AI.swift:209-217`) hydrates the new drafts. Tolerate absent keys (default empty).
- `resolveConfiguration` (`AIService.swift:220-244`): collapse to `(CloudModel, modelID: String)`. **Spell out the per-site mapping:** each of the three construction sites (`generate:56-61`, `testKey:135-139`, `makeAssistantProvider:210-215`) routes the single `modelID` into the correct `BYOKeyProvider` init slot by `cloudModel` (`openAIModel` / `anthropicModel` / new `openModelsModel`). Add a single helper `keychainKeyID(for: CloudModel) -> String` (`"openai"`/`"anthropic"`/`descriptor.keychainKeyID`) that removes the `cloudModel == .openAI ? "openai" : "anthropic"` ternary repeated at 52/141/206.
- `BYOKeyProvider.init` (`Providers.swift:65-78`): add `openModelsModel: String = ""` alongside the existing two slots (avoids churning OpenAI/Anthropic callers).
- `refreshCKAIModels` (`AppState+AI.swift:129-158`): relax the guard at 132 to also allow the three vendor keychain ids; store under `ckAIModelOptions[<keychainID>]`.
- Migration: purely additive; existing OpenAI/Anthropic users unaffected.

## 9. Error handling & degradation

1. **Web search:** openModels has no first-party web-search tool. In `generate()` (`Providers.swift:80-91`) the `.openModels` case under `request.wantsWebSearch` throws `AIError.webSearchUnsupported(model)` (reuse the existing branch). **Update the copy** at `AIProvider.swift:118-119` ("Switch to OpenAI or Anthropic") to read sensibly with a third provider.
2. **Friendly `CloudModel` strings:** `AIError.errorDescription` interpolates `\(model)` for `noKeyConfigured` (`AIProvider.swift:104`) and `webSearchUnsupported` (`:119`); default reflection prints `openModels(AIProviderKit.OpenModelVendor.glm)`. Add a friendly `CloudModel` description / displayName mapping.
3. **Structured-output fallback:** extend `extractJSONObject` (`Providers.swift:235-241`) with a **leading `<think>…</think>` strip** before fence-stripping (new `stripThinkTags(_:)`), as a MiniMax defense. One-shot `openModels` `generate()` mirrors `callOpenAI`'s do/catch (`:109-119`): try thinking-disabled + `json_object`; on `httpError 400` with `wantsStructuredJSON`, retry **without** `response_format` and rely on `extractJSONObject`.
4. **Tool-loop guards:** detect Kimi `"reasoning_content is missing"` 400 and surface a clear developer-facing message (the canary — should never fire if replay is wired; do not swallow). The 6-iteration cap (`AssistantEngine.maxToolIterations`) bounds MiniMax silent-degradation loops. GLM infinite-loop (clear_thinking:false without replay) is impossible by construction since the encoder always re-emits `reasoning_content` for `.reasoningContent` — add a unit test asserting it.
5. **No-key / unsupported:** reuse `AIError.noKeyConfigured` / `AIServiceError.unsupportedProvider`; extend the unsupported-provider switch (`AIService.listModels:158-162`) to accept the three keychain ids.
6. **Capture is best-effort:** a turn with no `reasoning_content` ⇒ `reasoning == nil`, loop proceeds exactly as today.

## 10. Test plan

**Unit (headless, `MockHTTPTransport`):**
- **A. Parser capture:** GLM/Kimi canned response with `reasoning_content` + `tool_calls` → `style==.reasoningContent`, text matches, toolCalls parsed. MiniMax with `reasoning_content`+`reasoning_details` → `style==.reasoningDetails`, `detailsJSON` round-trips the array (**assert parsed-object equality, not string equality**). Absent reasoning → `reasoning==nil`, turn otherwise identical to OpenAI parse.
- **B. Encoder replay:** assistant `AIChatMessage` with reasoning + tool_calls → emitted assistant dict has `reasoning_content` (GLM/Kimi) / `reasoning_content`+`reasoning_details` (MiniMax) on the **same** object as `tool_calls`, `content` present-or-`NSNull`, followed by `{role:"tool"}`. Round-trip: capture→append→re-encode, assert `reasoning_content` bytes unchanged (the GLM-infinite-loop / Kimi-400 regression lock).
- **C. Thinking/temperature wiring:** Kimi tool-loop body `temperature==1.0` + `thinking.keep=="all"` **driven through the real `AssistantToolChat` protocol call path** (proves the incoming 0.3 is dropped); GLM `thinking.clear_thinking==false`; MiniMax `reasoning_split==true` + `thinking.type=="adaptive"`. One-shot: `thinking.type=="disabled"`; Kimi one-shot `temperature==0.6`.
- **D. Fallbacks:** `stripThinkTags` removes a leading `<think>…</think>` before JSON; `extractJSONObject` still passes existing OpenAI/Anthropic cases (no regression).
- **E. Descriptor registry:** `descriptor(for:)` host/key/default per vendor; `vendor(forKeychainID:)` maps `zai→.glm` etc.
- **F. Engine thread-through:** scripted `AssistantToolChat` double returns a turn with reasoning; assert the next provider call receives an assistant history message with non-nil reasoning (proves the line-240 thread-through).

**Human on-device gate (the do-it-right acceptance) — run per model with a real key, recorded per model in the PR:**
1. **Week generation** (strict JSON): full 21-meal week decodes cleanly (no `<think>` leak, no fence) — proves thinking-disabled + extract-JSON.
2. **Multi-iteration assistant tool sequence:** a prompt forcing ≥2 tool calls across ≥3 loop iterations (e.g. "swap Tuesday dinner to something cheaper and then rebalance the day"). Assert: no infinite loop, no Kimi 400, coherent final answer reflecting earlier tool results — proves reasoning replay holds across iterations.

## 11. Task breakdown (ordered, subagent-sized; critique fixes folded in)

- **T1 — Core reasoning + vendor types (buildable).** Add `ReasoningStyle`, `ReasoningTrace`, `OpenModelVendor`, `CloudModel.openModels`, and the `reasoning` field on `ToolUseTurn`/`AIChatMessage`/`AIResponse` (all defaulted nil). **Also add temporary throwing `.openModels` arms** to the **four** exhaustive `CloudModel` switches the new case breaks: `Providers.swift:81-91` (web-search), `:93-100` (generate), `:387-395` (listModels), `BYOKeyProviderTools.swift:137-150` (chatWithTools) — e.g. `case .openModels: throw AIError.notWiredYet(tier)`. *Acceptance:* package builds; existing AIProviderKit tests pass unchanged; new types public + Equatable.
- **T2 — ProviderDescriptor registry.** New `ProviderDescriptor.swift` + `ProviderRegistry` for the three vendors. *Acceptance:* test E.
- **T3 — openModels one-shot `generate()`.** Route `.openModels` through an OpenAI-compatible call via the descriptor (Bearer, `descriptor.chatURL`, model id, thinking disabled, one-shot temp, `json_object` with 400-no-`response_format` retry). Add `stripThinkTags` inside `extractJSONObject`. Add the `webSearchUnsupported` branch. In-provider key lookup uses `descriptor.keychainKeyID` (not a hardcoded string). *Files:* `Providers.swift` (generate, new `postOpenModelsChat`, `extractJSONObject:235-241`, `init:65-78`). *Acceptance:* MockHTTPTransport test — one-shot body thinking-disabled + correct temp; `stripThinkTags`; OpenAI/Anthropic generate tests unchanged.
- **T4 — openModels listModels + catalog.** `listModels` routing (`descriptor.modelsURL` or fallback) + `AIModelCatalog` entries. **When `modelsURL==nil`, perform a real authenticated probe (a minimal chat completion) — not a static-only return — OR surface "cannot validate" for that vendor** (closes the `testKey` false-positive). *Files:* `Providers.swift:386-395` + new `listOpenModelsModels`; `AIModelCatalog.swift:24-32,39-62,69-75`. *Acceptance:* test key lists models for a keyed vendor; `curatedModels` returns vendor fallback for unknown raw lists; no false-positive Test Key.
- **T5 — openModels tool loop + reasoning capture/replay.** Add `chatWithToolsOpenModels` + `parseOpenModelsToolTurn(style:)` + `encodeOpenModelsMessages(vendor:)`. Capture + replay verbatim; inject per-vendor thinking + tool-loop temperature via descriptor. **Explicit:** `chatWithToolsOpenModels` ignores the temperature it is called with (hardcoded 0.3 from `AssistantToolChat`) and uses `descriptor.toolLoopTemperature`; in-provider key lookup uses `descriptor.keychainKeyID`. *Acceptance:* tests A/B/C incl. verbatim round-trip; **Kimi body `temperature==1.0` asserted through the real protocol call path**; GLM `clear_thinking==false`; MiniMax `reasoning_split==true`.
- **T6 — Engine thread-through.** `AssistantEngine.swift:239-241` carries `turn.reasoning`. *Acceptance:* test F.
- **T7 — AIService resolution + keys.** `resolveConfiguration → (CloudModel, modelID)` with the **explicit per-site init-slot mapping** at the three construction sites; add `keyOpenModelsVendor`/`keyOpenModelsModel`; pin the new `loadAISettings` return shape; add `keychainKeyID(for: CloudModel)`; update generate/testKey/makeAssistantProvider/listModels; relax the unsupported-provider switch. *Acceptance:* build + existing AIService tests pass; selecting an openmodels vendor+model resolves to `.openModels(vendor)` with the right key.
- **T8 — Persistence + drafts.** Add the two drafts; `saveAISettings` upserts vendor+model and saves to the selected vendor's keychain id; `syncAIDraftsFromRepo` hydrates; `refreshCKAIModels` accepts vendor keychain ids. *Acceptance:* save→reload round-trip; `ckAIModelOptions` populates for the selected vendor.
- **T9 — Settings UI.** "Open models" tag; vendor-spanning sectioned dropdown (composite tags) setting both drafts; dynamic per-selected-vendor key field + status + Save/Test/Clear (Gemini-image-key pattern). **Verify the SwiftUI Picker round-trips the composite `vendor:model` tag and the key field updates on vendor switch.** *Acceptance:* manual — GLM model shows Z.ai key field; switching to a Kimi model re-targets Moonshot key; Save persists; Test Key validates the selected vendor.
- **T10 — Aggregate green check + human gate.** (a) all unit tests green; (b) the on-device human gate — **one `[?] awaiting human verify` checkbox PER model** (GLM-5.2 / Kimi-K2.6 / MiniMax-M3), each running the week-gen strict-JSON + multi-iteration tool sequence; record pass/fail per model in the PR. (Unit tests A–F are owned by T2/T3/T5/T6 — T10 does not re-author them.)

## 12. Open risks

- **Kimi temp=1.0 vs loop 0.3** — highest-likelihood implementation miss; covered by the T5 explicit instruction + test C through the real protocol path.
- **GLM `clear_thinking:false` replay contract** on the standard `/paas/v4` endpoint (no-signature, presence-not-order) — MUST-VERIFY on a live key before shipping.
- **Kimi 400 string** community-sourced — detect by substring, never hardcode `"at index N"`.
- **MiniMax `response_format` unreliable** — week-gen must not depend on it; `stripThinkTags` is the guard.
- **MiniMax reasoning replay degrades silently** if `reasoning_details` is dropped — only the on-device multi-iteration gate catches a regression; keep that gate mandatory.
- **Region split** — only international hosts wired; China-region keys 401 (out of scope v1; surface a clear auth error).
- **`json_schema` strict** unconfirmed for GLM/MiniMax, unverified-with-thinking for Kimi — v1 uses `json_object`/prompt-contract only.
- **Anthropic-compatible endpoints** exist for all three but their block/signature mechanics are LOW-confidence — deliberately NOT used; `signedBlock` reserved, not implemented.
- **Vendor-spanning single-dropdown UX** is novel here — verify Picker composite-tag round-trip + key-field re-targeting (T9).
- Stale `gpt-4o`/`claude` defaults elsewhere left untouched (bounded diff; not an openModels correctness risk).

## 13. Adversarial review applied (critique `needs-revision` → fixed)

1. **T1 buildability** — added the four placeholder throwing `.openModels` switch arms so "package builds" is achievable.
2. **Kimi temperature override** — made "drop the incoming 0.3, use `descriptor.toolLoopTemperature`" an explicit T5 instruction + a test through the real protocol path.
3. **`reasoning_details` "verbatim"** — downgraded to structural/semantic preservation; test A asserts parsed-object equality.
4. **`testKey` false-positive** — T4 requires a real authenticated probe (or explicit "cannot validate") when a vendor has no `/models`.
5. **Completeness gaps** — friendly `CloudModel` error strings; explicit `(CloudModel, modelID)→init-slot` mapping at the three sites; `descriptor.keychainKeyID` for in-provider lookups; pinned `loadAISettings` return shape; T10 restructured to human-gate-only, per-model.

## 14. Confidence

- **HIGH:** all three are OpenAI-compatible `/chat/completions` + Bearer + OpenAI-shape tools (matches existing emission); `reasoning_content` is the replay carrier for GLM/Kimi; MiniMax `reasoning_split=true` yields `reasoning_content`+`reasoning_details`; replay required within a single tool-call task; the in-loop drop is exactly `AssistantEngine.swift:240` and cross-turn history is markdown-only (`AppState+Assistant.swift:176-186`) ⇒ no persistence/CloudKit change; `KeyStore` generic ⇒ per-vendor keys free; the descriptor pattern cleanly replaces the binary switches at the cited lines; Sendable design sound (`detailsJSON`-as-String is the right move).
- **MEDIUM (MUST-VERIFY-IN-CODE):** GLM `clear_thinking:false` replay contract; Kimi pure-JSON-under-thinking + the literal 400; MiniMax `/models` existence + `response_format` honoring; whether reasoning field **order vs presence** matters (research says presence; we capture-verbatim regardless).
- **LOW / deferred:** Anthropic-compatible endpoints for all three; China hosts; `json_schema` strict mode.
