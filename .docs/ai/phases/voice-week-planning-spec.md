# Voice Week-Planning — Spec

**Status:** approved design, pre-plan. Authored 2026-06-29 (Opus) from a deep workflow that **verified the iOS 26 Speech + FoundationModels APIs against the actual SDK headers** (`iPhoneOS26.0.sdk` `.swiftinterface`), re-mapped the app seams, synthesized, and adversarially critiqued. Critique verdict `needs-revision` — fixes folded in (see **§14**).

**Goal:** Hit a button, **talk out your week** ("Monday taco night, Tuesday leftovers, that salmon recipe Wednesday, order pizza Friday…"), and the app fills meals into each day. **User-locked scope:** full hybrid now (on-device transcribe + on-device Foundation Models parse on eligible hardware; cloud fallback otherwise) · **review screen before applying** · **best-match-else-free-text** recipe resolution · entry via a **Week-tab "Plan by voice" button** + a **mic in the assistant composer**.

**Critical environment fact (verified):** `IPHONEOS_DEPLOYMENT_TARGET = 26.0`. So Speech (`SpeechTranscriber`/`SpeechAnalyzer`) and FoundationModels (`SystemLanguageModel`) are **always present at the SDK level** — there is **no OS-version gate**. The on-device-vs-cloud split is a pure **runtime availability branch** (`SystemLanguageModel.availability` + speech asset readiness), and the `SFSpeechRecognizer` path is a runtime-robustness fallback, not a version fallback.

---

## 1. Architecture — 4 layers, one terminal pipeline

1. **Transcribe (on-device)** → transcript `String`. `SpeechTranscriber`/`SpeechAnalyzer` when the locale asset is installed; `SFSpeechRecognizer` (the shipping `VoiceCommandService` path) otherwise.
2. **Parse (on-device or cloud)** → `ParsedWeeklyPlan`. On-device: FoundationModels `@Generable` constrained decoding. Ineligible HW / parse error: one cloud call returns `ParsedWeeklyPlan`-shaped JSON.
3. **Resolve (on-device, pure)** → `[MealUpdateRequest]` proposal. Best-match each `rawDish` against `appState.recipes`, else free-text; intents → sentinels. No cloud.
4. **Review → Apply (on-device, existing)** → on confirm, `appState.saveWeekMeals(weekID:meals:)` → CloudKit + grocery regen.

All four transcribe×parse combinations converge on the **same** resolve → review → apply tail. **Nothing persists until the user confirms the review screen.**

## 2. Data model

`ParsedWeeklyPlan` (parse output) is **distinct** from `MealUpdateRequest` (apply payload); they're kept in lockstep by a deterministic mapping + checked-in fixtures, not by being the same type.

New file `Features/VoicePlanning/ParsedWeeklyPlan.swift` (app target). Declared **both** `@Generable` (on-device constrained decoding) **and** `Codable` (cloud JSON + fixtures decode through the same struct):

```swift
@Generable(description: "A weekly meal plan parsed from a spoken request")
struct ParsedWeeklyPlan: Codable, Sendable, Equatable { let entries: [ParsedMealEntry] }

@Generable struct ParsedMealEntry: Codable, Sendable, Equatable {
    let day: String        // "Monday"…"Sunday" or "today"/"tomorrow" (normalized downstream)
    let slot: String       // breakfast | lunch | dinner
    let rawDish: String     // dish exactly as spoken
    let intent: MealIntent
}
enum MealIntent: String, Codable, Sendable { case recipe, eatOut, leftovers, skip }
```

- **MUST-VERIFY-IN-CODE (compile gate, T1):** `@Generable` on an **enum** is NOT in the verified symbol set (only the macro signature + `GenerationSchema(type:description:anyOf:)` for enum-shaped schemas are verified). If `@Generable enum` doesn't compile, drop the macro from `MealIntent` and express it as a `GenerationSchema` `anyOf` choices string-constraint (verified). Same MUST-VERIFY for the `@Guide(description:)` per-property macro — fallback to the type-level `@Generable(description:)` + prompt instructions (the parse still works because `slot`/`intent` are constrained and `day` is normalized downstream).

**Apply payload (existing, do NOT redefine):** `MealUpdateRequest` (`SimmerSmithModels.swift:2543-2611`) — required `dayName`/`mealDate`/`slot`/`recipeName`; optional `recipeId`/`servings`; tolerant decoder defaults the rest.

## 3. Mapping (the lockstep seam) `ParsedMealEntry` → `MealUpdateRequest`

This is the **highest-risk section** (critique #1/#2 — a UTC-calendar landmine). Implement precisely:

- **Day-name → weekday-index → offset: NO existing helper — author one.** `DayKey` lives in `Utilities/DayKey.swift` (NOT Models) and only does `Date → name`. There is **no** name→index→offset helper anywhere. Author `weekdayIndex(forName:)` (Monday=…Sunday, case-insensitive, + "today"/"tomorrow"/"tonight" relative handling).
- **Calendar choice is FORCED: UTC.** `meal_date` is persisted at **UTC midnight** (DayKey's own doc comment). The codebase has two conflicting calendars — `DayKey.utcCalendar` (UTC) and `RecipeWeekAssignmentView`'s private `Calendar.isoWeek` (Monday-first, `.current` TZ). **Use `DayKey.utcCalendar`** for all offset math; a wrong-TZ offset mis-attributes a meal to the adjacent day (the exact bug `meal_date`-at-UTC-midnight prevents).
- **`weekStart` is a String in one place, a Date in another (critique #2).** `AIPageContext.weekStart` is a `String` (`"yyyy-MM-dd"`, via `DayKey.server`); `WeekSnapshot.weekStart` is a `Date`. The mapping needs a **Date**: parse the `AIPageContext` string back to a Date with **UTC** semantics (mirror `DayKey.server`'s parse), or take `WeekSnapshot.weekStart` directly when available. `mealDate = weekStart(UTC) + weekdayOffset` via `DayKey.utcCalendar`.
- `slot` → lowercased, validated `breakfast|lunch|dinner`.
- `intent == .recipe`: best-match `rawDish` against the recipe list (§4) → above threshold: `recipeId = match.recipeId`, `recipeName = match.name`; below: `recipeId = nil`, `recipeName = rawDish` (titlecased). **This IS best-match-else-free-text.**
- `intent == .eatOut|.leftovers|.skip`: `recipeId = nil`, `recipeName` = sentinel ("Eat out" / "Leftovers" / "Skip"), raw phrase in `notes`. **MUST-VERIFY-IN-CODE BEFORE T2 (critique #4):** confirm `WeekMeal`/the Week UI can represent a non-recipe meal (the app shows "Out to eat" as a dinner — so it's representable; verify the exact field/sentinel it uses and mirror it). **Fallback if not cleanly representable:** store as a free-text `recipeName` with the phrase, drop the dedicated intents to free-text. Resolve the mechanism before T2 commits to the intents.
- `approved = false` on every proposed row (the review screen flips it).

## 4. Resolve (on-device, pure) — best-match-else-free-text

Recipe resolution is **on-device, no cloud**. Match each `ParsedMealEntry.rawDish` (intent `.recipe`) against `appState.recipes` (`[RecipeSummary]` via `RecipeRepository`; fields `recipeId/name/tags/cuisine/mealType/archived` at `SimmerSmithModels.swift:1803-1832`). Deterministic scorer over **non-archived** recipes: normalized exact → token-subset/contains → optional light fuzzy; threshold gate. Above → `recipeId`; below → free-text (`recipeId = nil`, `recipeName = rawDish`). Pure + injectable (`[RecipeSummary]` in, `[MealUpdateRequest]` out) → fully headless-testable.

## 5. On-device parse (FoundationModels) — SDK-verified

- **Availability gate first (read, don't call):** `let model = SystemLanguageModel.default; switch model.availability` over the `@frozen` enum → `.available` vs `.unavailable(reason)` where reason ∈ `{deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady}` (verified). `.available` → on-device; any `.unavailable` → cloud (§6). `.modelNotReady` → cloud-now, retry-on-device-later (advisory).
- **Session:** `LanguageModelSession(instructions:)` convenience init (verified) with a tight instruction: *"Extract a weekly meal plan. One entry per assigned meal. Map vague phrasing to intent recipe|eatOut|leftovers|skip. Do NOT invent meals not spoken."* No tools (pure extraction). **Recipe library NOT in the prompt** (resolution is §4).
- **Constrained generation:** `let response = try await session.respond(to: <Prompt>, generating: ParsedWeeklyPlan.self); let plan = response.content` (verified `respond(to:generating:includeSchemaInPrompt:options:) -> Response<Content>`). Keep `includeSchemaInPrompt: true` (default). **MUST-VERIFY (critique):** `respond(to:)` takes a `Prompt`; the verified sample passed a String *literal*. Passing the `transcript` String *variable* may need `Prompt(transcript)` — wrap it.
- **NaturalLanguage pre-segment:** before the model call, `NLTokenizer(.sentence)` segments the transcript so long multi-day utterances stay in-window and parse reliably.
- **Errors (critique #6 — broaden):** catch `LanguageModelSession.GenerationError` (verified cases incl. `exceededContextWindowSize`, `guardrailViolation`, `decodingFailure`, `rateLimited`, `refusal`, **`assetsUnavailable`, `unsupportedGuide`**). `exceededContextWindowSize` → re-run per NL segment + merge. **Every other case + a `default:` → cloud parse with the same transcript.** No `GenerationError` case dead-ends. (`unsupportedGuide` is directly reachable because `@Guide` is MUST-VERIFY.)
- No token-count API exists in iOS 26 FoundationModels (gotcha) — size management is NL segmentation, not pre-counting. `GenerationOptions(temperature:)` low if extraction is loose.

## 6. Cloud parse fallback — the RIGHT seam + a new schema artifact (critique #3, #feasibility)

The cloud side has no `@Generable` constraint. Structured JSON in this codebase is produced by a **prompt-embedded JSON schema + `response_format: json_object`** then `extractJSONObject`, exactly as `MealPlanSchema.swift`/`RecipeAISchema.swift`/`EventMenuSchema.swift` do. So:

- **New artifact (T8):** author a `ParsedWeeklyPlan` JSON schema + prompt, mirroring `MealPlanSchema.swift`.
- **Use the existing structured-generation seam — NOT `makeAssistantProvider`/`chatWithTools`.** Generate via `AIService.generate(AIRequest(... wantsStructuredJSON: true))` (the `ProviderRouter`+`AIClient`+`noKey`/`noProvider`-gated path week/recipe/event-menu generation already uses). `makeAssistantProvider()` is the tool-LOOP factory (it would commit pre-review) — wrong here.
- Extract `AIResponse.text` → `extractJSONObject(...)` → `SimmerSmithJSONCoding.makeDecoder().decode(ParsedWeeklyPlan.self, ...)`, then rejoin the same resolve → review → apply pipeline. **Writes nothing.**
- Used when (a) hardware ineligible, or (b) the user under-specifies ("fill the rest with quick dinners") and wants suggestions.

**Why the cloud step is NOT the assistant tool-loop:** `weeks_update_meals` / `AssistantEngine.run` / `sendAssistantMessage` **commit immediately** (→ `saveWeekMeals` → CloudKit). That conflicts with review-before-apply. So the cloud parse uses a **one-shot structured `generate`** (no write tool); `weeks_update_meals`/`saveWeekMeals` is the **commit seam only**, called once after review.

## 7. Review screen — `Features/VoicePlanning/VoicePlanReviewView.swift`

Sheet presented after parse+resolve, **before any write**. Inputs: active `weekId`/`weekStart` + the resolved `[MealUpdateRequest]` proposal (`approved=false`).
- Header: "Review your week" + the (collapsible) transcript so the user sees what was heard.
- Day×slot list (Mon–Sun, b/l/d). Each row: day+slot, resolved `recipeName`, a provenance badge — **matched** (recipeId set) / **new/free-text** (recipeId nil) / intent sentinel (Eat out / Leftovers / Skip). Low-confidence rows float to top, flagged.
- Per-row edits (v1 min): delete; toggle a free-text row to pick a real recipe (reuse the existing recipe picker — FIND it; else a searchable list over `appState.recipes`); edit `recipeName`. Day/slot moves are out of v1.
- Footer: **"Apply to week"** (flips `approved=true`, calls apply) + **"Cancel"** (writes nothing).
- **Apply:** call `appState.saveWeekMeals(weekID:meals:)` (`AppState+Weeks.swift:250`) directly with the reviewed `[MealUpdateRequest]` — the same call `weeks_update_meals` wraps, so grocery regen + CloudKit mirror + `week.updated` fire identically.
- Reuse app design tokens (`SMColor/SMSpacing/SMRadius/SMFont`) + WeekView meal-row components where they exist.

## 8. Availability + fallback (never dead-end)

A small **headless-testable** `VoicePlanningAvailability` resolver decides PARSE source + TRANSCRIBE engine independently:
- **PARSE:** `SystemLanguageModel.default.availability` → `.available` → on-device; `.unavailable(.deviceNotEligible|.appleIntelligenceNotEnabled)` → cloud; `.unavailable(.modelNotReady)` → cloud-now + "on-device soon" hint.
- **TRANSCRIBE:** `SpeechTranscriber` when `AssetInventory.status(forModules:)` reports the locale installed (or installs); else `SFSpeechRecognizer` (shipping). No OS branch. **Ship `SFSpeechRecognizer` first; gate `SpeechTranscriber` behind successful asset reservation.**
- **Degradation order:** on-device transcribe → on-device parse (best). Parse `GenerationError` → cloud parse. `SpeechTranscriber` asset failure → `SFSpeechRecognizer`. Cloud parse fails (`noProviderConfigured`/`noKeyConfigured`) → clear actionable error, **keep the transcript**. Transcription unavailable / permission denied → plain text composer (mic just doesn't activate). All four transcribe×parse combos converge on one resolve→review→apply tail.

**PRODUCT DECISION baked in (critique #feasibility — the dominant-cohort dead-end):** on-device parse needs an Apple-Intelligence-eligible device (iPhone 15 **Pro**+/A17 Pro/M-series). The large cohort (iPhone 15/SE/older, all on iOS 26) **always routes to cloud → needs a BYO key.** No key + ineligible HW = no parse path. **v1 behavior (recommended default — confirm if you want otherwise):** always **show** the "Plan by voice" entry; when neither on-device parse nor a configured cloud key is available, tapping it shows a one-tap **"Set up an AI provider in Settings to plan by voice"** prompt (reuse existing `noProviderConfigured` copy) — never a silent dead-end, never a hidden button. Transcription + a manual-edit review still work even without parse (the transcript is shown; the user can hand-assign).

## 9. Entry points

Both feed a new `VoicePlanningCoordinator` (transcribe → parse → resolve → present review):
1. **Week-tab "Plan by voice" button** — add near the WeekView hero/toolbar; pass the week context (`weekId` + `weekStart`, from `publishContext()` `WeekView.swift:1447-1460`) into the coordinator. Presents a lightweight "listening" sheet (live partial + stop) → on stop, parse+resolve → swap to `VoicePlanReviewView`. Mirror existing toolbar/hero styling.
2. **Composer mic** — in `AIAssistantSheetView.composer` (`220-273`), a mic `Button` between the `TextField` (227) and send `Button` (235), same `HStack(alignment:.bottom)`. **v1 = pure dictation into the text field** (live partial streams into `AIAssistantCoordinator.composerText`; tap to start/stop, glyph mirrors the send/stop swap at 246-261). The dedicated button owns the full review flow; the composer mic just dictates (keeps the composer change minimal). Routing composer-mic into review is out of v1.

`VoicePlanningCoordinator` must be reachable from both views — mirror how `aiCoordinator` is environment-injected.

## 10. Error handling

Layered, never dead-end, terse actionable copy (mirror `ToolRegistry.failure`/`AIServiceError`): permissions denied → Settings deep-link, composer text still works; transcription engine unavailable / 0-channel format → reuse the Build-66 `installTap` guards verbatim (`VoiceCommandService.swift:132,142`), `SpeechTranscriber` asset failure → silent `SFSpeechRecognizer` fallback; on-device `GenerationError` → §5 (never raw to the user); cloud parse fail → "Set up an AI provider…" / "Couldn't reach the AI service — your transcript is saved", **always preserve the transcript**; empty/garbage parse → review screen empty-state with the raw transcript (no auto-write); apply fail (`saveWeekMeals` throws) → `ToolRegistry.message(for:)` ("Weeks need iCloud…"), keep the reviewed proposal for retry; cancellation → mirror `cancelInFlightTurn()`, writes nothing.

## 11. Test plan

Framework: **Swift Testing** (`ToolRegistryDecodeTests.swift` is the model). **Headless-first** — everything but live audio/model is a pure unit:
1. `ParsedWeeklyPlan` Codable round-trip (cloud/fixture JSON ↔ struct).
2. **Mapping correctness (THE critical test, critique #feasibility — test the PRODUCTION path):** `map(plan, recipes:weekStart:)` → `[MealUpdateRequest]`, assert **construction** correctness directly: `mealDate` (UTC, weekStart+offset, relative-day normalization), `slot`, `recipeName`/`recipeId` (match vs free-text), each intent sentinel. This is what `saveWeekMeals` actually consumes (in-memory, no JSON round-trip).
3. **Tool-contract guard (secondary):** the same `[MealUpdateRequest]` → `SimmerSmithJSONCoding.makeEncoder()` → dict array → `ToolRegistry.decodeMeals` (`ToolRegistry.swift:421`) must not throw — guards the `weeks_update_meals` tool path (not the production apply path; framed honestly).
4. Best-match scorer (injected `[RecipeSummary]` → threshold/archived/exact/token-subset/below→nil).
5. Availability resolver (each `Availability` case × asset status → chosen parse source + transcribe engine; all four combos terminate at one pipeline entry).
6. Error fallbacks (each `GenerationError` variant → cloud-fallback selected; apply throw → proposal retained).

**Device-gated (real hardware, human gate, NOT CI):** SpeechTranscriber live transcription (asset reserve/install, `AnalyzerInput`, `isFinal`); FoundationModels live parse (eligible HW); end-to-end on device (speak → review → apply → CloudKit week + grocery regen, in airplane mode to prove on-device); ineligible-HW path routes to cloud and still reaches review→apply.

## 12. Task breakdown (ordered; headless-first; critique fixes folded in)

- **T0 — Resolve the non-recipe-intent mechanism (spike, MUST-VERIFY).** Confirm how `WeekMeal`/Week UI represents a non-recipe meal (the "Out to eat" dinner). Decide: keep `eatOut/leftovers/skip` intents (and the exact sentinel/field) vs collapse to free-text. Gates T1/T2. *Accept:* documented decision + the field/sentinel to use.
- **T1 — `ParsedWeeklyPlan` value types + intents (headless).** + the `@Generable`-on-enum / `@Guide` compile MUST-VERIFY gate (fallback to `GenerationSchema anyOf`). *Files:* new `Features/VoicePlanning/ParsedWeeklyPlan.swift` + test. *Accept:* compiles with `FoundationModels` import; Codable round-trip; gate resolved.
- **T2 — Resolve + mapping `ParsedWeeklyPlan` → `[MealUpdateRequest]` (headless).** Author `weekdayIndex(forName:)` + the UTC offset math (`DayKey.utcCalendar`); parse `weekStart` String→Date (UTC). *Files:* new `VoicePlanResolver.swift`. *Accept:* test #2 (construction correctness) passes incl. mealDate UTC + relative-day + sentinels.
- **T3 — Tool-contract round-trip test (headless).** `decodeMeals` guard for the `weeks_update_meals` path; framed as a contract guard, not the production safety net. *Accept:* round-trip passes for every fixture.
- **T4 — `VoicePlanningAvailability` resolver (headless).** *Accept:* test #5.
- **T5 — `DictationService`: `SFSpeechRecognizer` engine first (device-gated).** Mirror `VoiceCommandService` patterns (115-122,146-148,71-84,132,142) into a NEW file; do not mutate the shipping service. *Accept:* live partial+final, no installTap crash.
- **T6 — `SpeechTranscriber` engine behind availability (device-gated).** Verified API (§ transcription); asset failure → SFSpeech fallback. *Accept:* on eligible HW transcribes via SpeechTranscriber.
- **T7 — `OnDeviceParseService` (device-gated).** §5 incl. the `default: → cloud` GenerationError branch. *Accept:* eligible HW yields sensible `ParsedWeeklyPlan`; errors route to cloud.
- **T8 — `CloudParseService` (reuse).** New `ParsedWeeklyPlan` JSON schema + prompt (mirror `MealPlanSchema.swift`); generate via `AIService.generate(AIRequest(wantsStructuredJSON:true))`; `extractJSONObject` → decode. *Accept:* returns a decodable plan; surfaces `noProvider/noKey`; writes nothing.
- **T9 — `VoicePlanReviewView` + apply (UI).** Calls `saveWeekMeals`. *Accept:* renders proposal, edits mutate payload, Apply commits, Cancel writes nothing.
- **T10 — `VoicePlanningCoordinator` + two entry points (UI wiring)** incl. the ineligible-HW-no-key CTA (§8). *Accept:* button launches listen→review→apply; composer mic dictates; both build.
- **T11 — Device-gated human gate.** Real iPhone 15 Pro+/iOS 26 + AI on: full flow both entry points, airplane-mode on-device proof, ineligible path → cloud → review. `[?] awaiting human verify`.

## 13. Out of scope (v1)

Multi-locale/non-English; streaming live-parse preview; composer-mic auto-routing into review; day/slot moves in review; new Fly endpoints or new ToolRegistry tools; freemium gating; persisting raw audio (transcript only, transiently); re-architecting `VoiceCommandService` (Cooking-Mode keyword voice untouched — patterns copied into a new `DictationService`).

## 14. Adversarial review applied (`needs-revision` → fixed)

1. **Day-name→offset helper doesn't exist + UTC landmine** — §3 forces authoring `weekdayIndex(forName:)` over `DayKey.utcCalendar`, justified against `meal_date` UTC-midnight storage and the `Calendar.isoWeek` conflict.
2. **`weekStart` String vs Date** — §3 specifies parsing the `AIPageContext` String → Date (UTC) / using `WeekSnapshot.weekStart`.
3. **Cloud parse seam + missing schema artifact** — §6 uses `AIService.generate(AIRequest(wantsStructuredJSON:))` + a new `ParsedWeeklyPlan` JSON schema/prompt + `extractJSONObject`, NOT `makeAssistantProvider`/`chatWithTools`. New T8 subtasks.
4. **Non-recipe intent storage unverified** — new **T0 spike** gates it with a fallback.
5. **`@Generable`-enum + `respond(to:)` String asserted as fact** — §2/§5 mark both MUST-VERIFY with verified fallbacks (`GenerationSchema anyOf`, `Prompt(transcript)`).
6. **GenerationError catch incomplete** — §5 adds `assetsUnavailable`/`unsupportedGuide` + a `default: → cloud` branch.
7. **Lockstep test guarded a non-production path** — §11 test #2 now asserts `MealUpdateRequest` construction correctness (the real `saveWeekMeals` risk); #3 reframed as the tool-contract guard.
8. **Ineligible-HW-no-key dead-end** — §8 makes it a baked-in product decision (always-show entry + "set up AI" CTA, transcription+manual-edit still works).

## 15. Confidence

- **HIGH:** the Speech path trusts only SDK-verified symbols (`SpeechTranscriber(locale:transcriptionOptions:…)`, `SpeechAnalyzer(inputSequence:…)`, `AssetInventory.reserve/status/assetInstallationRequest`, `AnalyzerInput(buffer:)`, `finalizeAndFinishThroughEndOfInput()`) and flags the rest (`Preset` cases, `Result.text`, `bestAvailableAudioFormat`) as MUST-VERIFY; the FoundationModels core (`SystemLanguageModel.default.availability`, `LanguageModelSession(instructions:)`, `respond(to:generating:)`, the `GenerationError` cases, no-tokenCount) is faithful; the no-OS-gate/runtime-availability reasoning is correct; the deliberate bypass of the commit-on-call assistant seams for a one-shot `generate` + direct `saveWeekMeals` is the correct read.
- **MUST-VERIFY-IN-CODE (compile/runtime, on eligible HW):** `@Generable`-on-enum, `@Guide`, `Prompt(transcript)` wrapping, `Result.text`, `Preset` case names, `bestAvailableAudioFormat` — each with a verified fallback so none dead-ends.
- The genuinely device-gated parts (live transcription + on-device model) are proven only by the T11 human gate on real iPhone 15 Pro+/iOS 26 hardware — no Apple sample substitutes for it.
