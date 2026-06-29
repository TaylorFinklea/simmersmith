# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. ≤20 lines.
> Legacy session history belongs in git log, decisions.md, and phases/*.

## Current (2026-06-29) — Voice week-planning SHIPPED build 138; awaiting on-device gate

Talk-out-your-week built per `phases/voice-week-planning-spec.md` (T0-T10). Week-tab mic → **a TEXT BOX**
(system keyboard on-device dictation OR typing — no app audio/speech) → on-device FoundationModels `@Generable`
parse (cloud fallback on ineligible HW / error) → best-match-else-free-text resolve → review screen → existing
`saveWeekMeals`. **Build 138 pivot:** the custom DictationService (AVAudioEngine+SFSpeech) crashed
(`_dispatch_assert_queue_fail`, 2nd mic tap) + blank sheet → deleted; replaced by the system keyboard. Composer
mic reverted (keyboard already dictates there). Custom transcription deferred to iOS 27 third-party dictation. Canonical
plain `ParsedWeeklyPlan` + resolver + availability in SimmerSmithKit (host-tested, **12 tests** incl. the UTC
mealDate off-by-one landmine); app-target `@Generable GenerableWeeklyPlan` adapter; FoundationModels + Speech API
**SDK-header-verified**. Bypasses the commit-on-call assistant tool-loop (one-shot `generate` + direct
`saveWeekMeals`) to honor review-before-apply. Commits `c7a0393` (feature) + `22ec61d` (8-finding adversarial-review
fixes: approved-flag, out-of-week dates, dictation race, JSON robustness) + build bump. **Build 137 on TestFlight.**

**BLOCKER — on-device human gate:** harness-deck `simmersmith/voice-week-planning-device-test` (awaiting-review,
8-step checklist + approval). On-device transcribe→`@Generable`-parse has no Apple sample. Needs iPhone 15 Pro+/
iOS 26 + AI on (airplane mode proves on-device); ineligible HW → cloud (needs BYO key). Decisions → decisions.md.

## Current (2026-06-29) — Household sharing v1 (two-account CKShare) CODE-COMPLETE; awaiting two-device gate

Real two-account sharing built per `phases/household-sharing-spec.md` (T1-T7): owner shares the household
zone with ONE partner via a zone-wide CKShare; participant ADOPTS (no merge), both edit. Role on
HouseholdSession (owner private DB / participant shared DB, per-scope state); engine ownsZone + share-record
filter + owner-safe revocation; zone-wide share create/accept primitives; scene-delegate accept (warm+cold,
CKSharingSupported) + PendingShareInbox; participant boot + post-accept double-fetch; accept-before-mint launch
ordering (wireHouseholdRepositories extracted, shared); Fly invite/join retired + joinHousehold hard-gated.
**App builds; 321 package tests pass.** Committed local-only (T1+T2 `20b245d`, primitives `1532205`, T3-T7 `d323a1d`).
2 adversarial reviews folded in (the cold-launch orphan-mint hole; owner-only write-gating rejected; etc.).

**Shipped: TestFlight build 135** (`b…` after the docs commit) — full sharing v1 + open-models + config-aware
APNs (Debug→development, Release→production; entitlements use `$(SM_APS_ENVIRONMENT)`). Ops preconditions are
DONE/moot: schema needed nothing (no new record types; household types already in Production — that's why
TestFlight works); APNs production landed in 135 (App Store validation confirmed it resolved).

**BLOCKER — two-device human gate (Savanne joins):** published to harness-deck (`simmersmith/household-sharing-device-test`,
awaiting-review, with the per-step checklist + an approval block for the result). NOT verifiable by me —
CKShare+CKSyncEngine has no Apple sample + needs two real iCloud accounts. Install build 135 on BOTH devices,
run the 7 steps. MUST-VERIFY-ON-DEVICE: scene-delegate accept fires; post-accept fetch populates; no orphan-mint
on cold accept; bidirectional sync; revocation purge. Also still pending: **push `main`** (local-only).

## Current (2026-06-28) — Open-model AI providers (GLM-5.2/Kimi-K2.6/MiniMax-M3) shipped; build 134 on TestFlight

New BYO-key "Open models" provider: GLM-5.2 (Z.ai), Kimi-K2.6 (Moonshot), MiniMax-M3 (MiniMax), direct
per-vendor keys, ONE Settings entry with a vendor-spanning model dropdown, available across every AI feature
incl. the 12-tool assistant, with **full reasoning capture/replay** in the tool loop. Built T1-T10 via the
spec `phases/oss-ai-providers-spec.md` (Opus implemented; 2 adversarial-review workflows caught + fixed: object-
shaped tool-call args dropped; default-GLM not committed → silent key-save no-op). 318 CK tests pass; app builds.
**Build 134 uploaded to TestFlight.** Architecture: descriptor registry (no binary openai/anthropic assumption),
vendor-agnostic ReasoningTrace, in-memory replay in AssistantEngine.drive (NO CloudKit migration). Decisions in
`decisions.md` (2026-06-28).

**Open items (human, on-device gate per model — needs YOUR keys):** for EACH of GLM-5.2 / Kimi-K2.6 / MiniMax-M3:
(1) week-gen produces clean strict JSON; (2) a multi-iteration assistant tool sequence holds (no loop, no Kimi 400,
coherent). MUST-VERIFY-IN-CODE flags (live key): GLM clear_thinking:false replay contract; MiniMax /models endpoint
+ response_format honoring; Kimi 400 string. Also still pending from 133: confirm week-gen timeout + payload-decode.

## Current (2026-06-27) — on-device QA of the BYO-AI tools; build 133 UPLOADED to TestFlight

Builds 127-132 shipped this session (Monday-week cutover, screen-wide week swipe, customizable per-screen
assistant prompts, AI error clarity + OpenAI/Anthropic structured-output 400 recovery). Build 132 fixed the
Anthropic prefill rejection (confirmed on-device: recipe suggest/save now succeed). **Build 133 uploaded**
(was briefly blocked: Xcode 26.0.1 had the iOS 26 platform + sim runtime uninstalled post-update; resolved once
the component download finished). Two build-133 fixes (from on-device screenshots): `381f50d` BYO request timeout
60s→180s (week-gen "request timed out"); `f652952` surface the real DecodingError on recipe/meals payload
("Could not read the recipe payload"). 298 CK tests pass.

**Open items (human):** on-device verify 133 (week-gen no longer times out; the payload error, if it recurs, now
names the field). Likely decode follow-up: if the surfaced reason names ingredients/steps wrong-type, make the
app-level decode tolerant of string-array ingredients/steps (deferred — diagnostics-first, see chat).

## Current (2026-06-22) — SP-C COMPLETE: CloudKit cutover + full AI track, all on main

Both branches MERGED to `main` (--no-ff), NOT pushed (local only): `sp-c/cloudkit-cutover-identity`
(`a9e8d8a`, the data cutover) + `sp-c/ai-track` (`15e3b05`, AI-1..AI-5). main builds; 276 CK tests pass.

**Status:** The rearchitecture is built — no central server needed; everything runs on CloudKit +
on-device with the user's BYO key.
- **Data cutover (on-device VALIDATED, build 120):** Identity (no sign-in), Weeks/Grocery, Events,
  Pantry/Profile (NSPCKC private plane), factory-reset "Start Fresh from Fly", orphan-recipes discovery fix.
- **AI track (built + 2-lens reviewed, builds 121-124, on-device PENDING):** AI-1 week-gen · AI-2 recipe AI
  (JSON-LD import + variation/suggestion/companion/refine + web search) · AI-3 nutrition (catalog) + event
  AI + rebalance · AI-4 images (OpenAI/Gemini) · AI-5 the tool-calling Assistant (12 tools, private-plane
  threads). All via AIService/BYOKeyProvider, keys in Keychain.

**Follow-ups (2026-06-23, all on `main`, NOT pushed):**
- `b1500ef` (build 125) — Settings → AI **key-aware model dropdown** (live /v1/models curated + fallback +
  Custom…), replacing the free-text field. AIModelCatalog (+13 tests). 7 review fixes.
- `66c9e59` — assistant **"Week not found"** data-safety: WeekRepository.saveWeekMeals guards the .week parent
  (no orphan meal writes) + diagnostic; weeks_get_current only surfaces a repo-resolvable week.
- `0610923` (build 126, cutting) — **CloudKit owns the current week** (cutover off Fly): WeekBoundary (+7
  tests) · WeekRepository.ensureCurrentWeek (deterministic name) · AppState.ensureCurrentCloudKitWeek carries
  over the in-memory Fly/cached week's meals + period · mirror resolves by range-contains. 5 review findings,
  F1+F3 fixed. RCA: currentWeek was Fly-sourced + weeks weren't auto-imported → phantom week.

**Open items (human):** push `main` when ready · on-device verify build 126 (assistant can save to the current
week; model dropdown) · possible leftover orphan weekMeal records from pre-66c9e59 failed saves (invisible/
harmless; cleanup available on request) · CloudKit Prod schema deploy for weeks/events/pantry full re-import.

**Deferred follow-ons:** CKShare-participant (Savanne joins) · SP-D (retire Fly + the dead Fly fallback
branches). AI v2 refinements: token-streaming the assistant, full 49-tool set, web-search/exports tools,
full-macro nutrition (needs the catalog to publish macros). Backlog: PrivatePlaneStore SwiftData tests
crash under macOS `swift test` (pre-existing, masked — see roadmap).
