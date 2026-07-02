# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. ≤20 lines.
> Legacy session history belongs in git log, decisions.md, and phases/*.

> **Backlog/ready-queue → beads (`bd ready`) as of 2026-06-30 (pilot).** New actionable work is filed in beads, not roadmap Now or this file. `.beads/` is git-excluded (stealth, local-only); decisions/phases/loop-state stay prose. See AGENTS.md → "Task tracking — beads pilot".

## 2026-07-01 — Architecture review COMPLETE; backlog rebuilt in beads

80-agent adversarially-verified review (Fable Lead) → 5 ADRs in decisions.md + report
`phases/arch-review-2026-07-01-report.md` + ~31 new beads (P1 data-loss/launch → P4).
Top of queue: `enx` (assistant full-REPLACE data-loss guard), `9i6` (backup-recover
reverts newer edits), `7f2` (paywall real-money w/ dead Fly fulfillment), `gju` (repair
layer unwired). SP-D decomposed under epic 990 (ports 990.1-7 → retire 990.8-12).
Beads `ike`/`2v5` closed superseded (OpenRouter pivot). Device gates unchanged (3sf
streaming build, nli voice, 3hn backup-recover, sharing).

## 2026-07-02 — From-zero re-review (Fable) RECONCILED; SP-D ports SHIPPED

Ports landed (`65700f0..224eb3a`, beads 990.1/2/3/6/7 closed; specs `ea23b25`). Full independent
re-review (114 agents, product-truth + steady-state lenses NEW) → 40 confirmed; reconciliation ADR
in decisions.md 2026-07-02 + `phases/arch-review-v2-2026-07-02-report.md`. Standing ADRs 1/2 +
both SP-D specs CONFIRMED; ADR-3/4/5 AMENDED. New P1 lane (label `arch-v2`): r8q cold-launch
token reset · 6ce rebase LWW · eky UI merge choke point · 9zf RepairScheduler isolation ·
7pr Smith-tab/assistant dead ends · 962 Create-with-AI port · 5w8 privacy-policy rewrite ·
9wr PUBLIC grant revoke (user Dashboard op). Build-147 product test still awaiting device run
(hdeck `p1-milestone-product-test`).
**HANDOFF → Opus: execute per `phases/arch-v2-execution-plan.md`** (lane/collision map + order +
non-negotiables; r8q and e0a carry LEAD notes — read them before implementing).
**Destination = `phases/launch-runbook.md`** (epic 0lm): Gates 0–4 to App Store submission;
launch does NOT wait for Fly deletion. Post-launch structural track = epic z69.

**P1 milestone EXECUTED same day (fleet):** 10 beads closed via commits `12b7f2f..7486a18`
(merge-guard, backup later-wins, RepairScheduler, StoreKit-local+dark paywall, confirms,
gated migration UI, SecretSanitizer known-value, privacy manifest, CI, dead code).
Kit 123 + CK 384 tests green; app builds. Build bumped to 147 — **USER: run
`scripts/release-ios.sh` to cut TestFlight 147** (agent-blocked: release = human call).
Product test: harness-deck `simmersmith/p1-milestone-product-test` (covers 147 + 3sf gate).

## Plan — 3sf token streaming (ACTIVE, spec `phases/oss-assistant-streaming-spec.md`)

- [x] Phase 1 — AssistantEngine streaming seam: `ToolUseStreamEvent` + `streamWithTools`
  (default-impl wraps `chatWithTools`, backward-compatible) + `drive` forwards live `assistant.delta`,
  `didStreamDelta`-gated `finish`. Package-only, 334 pkg tests pass (3 new streaming tests). Sonnet 5.
  Verify: `swift test --package-path SimmerSmithCloudKit`.
- [x] Phase 2.0 — shared SSE event reader (`SSEEvent` + synchronous `SSEParser`) in AIProviderKit, fixture-tested. DONE: new `SSEReader.swift` + `SSEReaderTests.swift` (7 cases); 341 CK tests pass. Verify: swift test --package-path SimmerSmithCloudKit ✓
- [x] Phase 2a — OpenAI `streamWithTools` SSE override + streaming transport seam (`HTTPTransport.lines(for:)`). DONE (Sonnet 5): tool-call deltas accumulated by index → `ToolUseTurn` matching `parseOpenAIToolTurn`; live `.textDelta`s; non-OpenAI vendors keep the Phase-1 default (single-witness-per-type). 348 CK tests pass (7 new). Verify: swift test --package-path SimmerSmithCloudKit ✓
- [x] Phase 2b — Anthropic `streamWithTools` SSE override. DONE (Sonnet 5): named content-block SSE → `input_json_delta` accumulated by index → `ToolUseTurn` matching `parseAnthropicToolTurn`; dispatch is now a switch (.openAI/.anthropic/default); the 2a fallback test legitimately repointed to `.openModels(.glm)`. 350 CK tests pass. Verify: swift test --package-path SimmerSmithCloudKit ✓
- [x] Phase 2c — open-models `streamWithTools` SSE override. DONE (Sonnet 5 + Opus backstop): OpenAI-compatible SSE + `reasoning_content` accumulation → `ToolUseTurn` matching `parseOpenModelsToolTurn` per `reasoningStyle`; MiniMax `reasoning_details` best-effort/device-gated (not fabricated); 2b fallback test replaced with 3 open-models streaming tests. Adversarial verify caught a real turn-equivalence edge (`.reasoningDetails` text `""` vs `nil`) → Opus fixed (nil-if-empty). 352 CK tests pass. Verify: swift test --package-path SimmerSmithCloudKit ✓
- [x] Phase 3 (code) — app wiring VERIFIED, no wiring change needed: all engine events share one `messageId` → `applyAssistantDelta` APPENDS each delta onto the seeded row on `@Observable` MainActor state; `URLSession.bytes.lines` streams; `for try await` applies each event live; `ForEach(thread.messages)` re-renders per delta — no defeating buffer. 5-lens adversarial audit (workflow) surfaced + FIXED one Phase-2b gap: Anthropic multi-text-block live stream ran blocks together (`"AB"`) vs `parseAnthropicToolTurn`'s `"\n"`-join (`"A\nB"`) — now yields a `"\n"` delta ONCE at the block boundary (`lastStreamedTextIndex`). App builds (iOS Sim); 353 CK tests pass (1 new). Verify: `swift test --package-path SimmerSmithCloudKit` ✓ + app xcodebuild ✓
- [x] Phase 3 device test (1st, live keys) FAILED → root-caused + FIXED (commit `015947f`): Anthropic "did not stream", OpenAI "temporarily unavailable". ROOT CAUSE — `URLSessionTransport.lines(for:)` used `bytes.lines` (`AsyncLineSequence`), which DROPS blank lines → `SSEParser` (dispatch-on-blank) never fired on device → no deltas + invalid-JSON collapse (verified empirically; fixtures missed it — mock + default transport both keep blanks). Fix: new `SSELineSplitter` (byte→line, preserves blanks); transport feeds `session.bytes` through it. ALSO `describe()` now delegates `.httpError` to `AIError.errorDescription` (401/429/HTTP-N) so the real OpenAI cause is visible (Test-Key only lists models, so it passes even when chat fails). 357 CK tests pass. Verify: `swift test --package-path SimmerSmithCloudKit` ✓ + app build ✓
- [x] OpenRouter pivot (commit `c7fa6a8`, user decision): OpenRouter (one key, OpenAI-compatible) REPLACES direct GLM/Kimi/MiniMax as the open-models provider (direct code hidden, not deleted). New `OpenModelVendor.openRouter` → reuses the whole descriptor-driven path; curated slug dropdown + Custom…; `modelsURL` nil → Test-Key does a real chat probe; reasoningStyle `.none`. 358 CK tests pass; app builds. Reasoning replay deferred (decisions.md).
- [ ] Phase 3 device gate (HUMAN — not looped): needs a FRESH build (streaming + OpenRouter are NOT in any TestFlight build yet — all commits are after the build-146 bump; run `scripts/release-ios.sh` / bump build). Then confirm tokens VISIBLY stream on OpenAI / Anthropic / OpenRouter, the OpenAI error (if any) now names the real HTTP status, and an OpenRouter multi-step tool request holds. → harness-deck `simmersmith/assistant-streaming-device-test`.

## Current (2026-06-30) — Backup & Restore SHIPPED build 145; awaiting recover device gate

In-app backup safety net (spec `phases/backup-restore-spec.md`). Settings → **Backups**: generic store-level
snapshot of the whole household (all 19 record types via `HouseholdRecordCodec`→`HouseholdRecordValue`→JSON, exact
IDs; images excluded). **Restore = RECOVER** (additive upsert — re-adds deleted, overwrites changed, never deletes
newer). Auto rolling (14, once/day on launch) + manual + ShareLink export + `.fileImporter`. New: `HouseholdBackup`/
`BackupCodec`/`BackupFilePolicy` (HouseholdRecords, now Codable+Sendable-ish), `AppState+Backup`, `BackupRestoreSection`.
**43 HouseholdRecords tests pass** (round-trip + retention). 10-finding adversarial review fixed (3 critical, all
restore: merger-clobber, participant-shared-zone warning, drain-completeness). Build 145 on TestFlight. **BLOCKER —
recover device gate** (back up → delete meal → recover → returns): harness-deck `simmersmith/backup-restore-device-test`.
**Deferred adversarial-review findings resolved (2026-06-30, Sonnet 5):** I2 → bead `pro` (HouseholdRecordCodec.decode
now logs a `[Backup] decode:` warn on a present-but-wrong-type field instead of silently dropping it); I5 → bead `54w`
(auto-snapshot encode/write moved to a detached `.utility` task off the main actor; `HouseholdBackup` made `Sendable`).

## Current (2026-06-29) — Sharing accept WORKS; participant fetch retry (144); also voice 141 cloud-only

Sharing two-device gate progressing on-device: share+invite work (142, owner shows partner "Invited"); accept
works (143 fixed the cold-launch race — partner lands in the shared household); participant week was empty →
144 retries the post-accept fetch (6x until weeks land) + gives "Refresh Now" a CloudKit pull + `[Sharing]` count
logs. AWAITING: does Savanne's week fill on 144 (or the counts). Builds 143/144 have `[Sharing]` console diagnostics.

## Current (2026-06-29) — Voice week-planning SHIPPED build 141; cloud-only parse, merges into week

**Build 141 (data-loss fix):** voice Apply now MERGES into the week (`VoicePlanResolver.merge(voice:into:)`,
host-tested) — `saveWeekMeals` is a full REPLACE, so applying only the voice meals had been DELETING the rest of
the planned week (unrecoverable; CloudKit has no trash). Also fixed a blank first-open sheet (`.sheet(item:)`).
**140:** on-device FoundationModels parse feature-flagged OFF (`OnDeviceParseService.isEnabled=false`) → parsing
uses the configured Settings cloud model. 139 fixed the "invented a full week" hallucination (extract-only prompts
+ dedup). 138 moved transcription to the system keyboard (custom AVAudioEngine crashed). 14 package tests pass.
On-device code dormant behind the flag for a later revisit.

## (superseded) Voice week-planning build 138 — system keyboard dictation

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
full-macro nutrition (needs the catalog to publish macros). PrivatePlaneStore `swift test` crash
(signal 5) — **FIXED 2026-06-30** (bead ww9, `d7e3737`): the 8 tests now skip via a `.enabled(if:)`
ConditionTrait under un-entitled `swift test` (env `SIMMERSMITH_PRIVATE_PLANE_ENTITLED_HOST` to run on an
entitled host); `swift test --package-path SimmerSmithKit` is a trustworthy green signal again (was masking).
