# Current State

> Loop-state: Branch / Plan checkboxes / Blockers / Open questions only. ≤20 lines.
> Legacy session history belongs in git log, decisions.md, and phases/*.

## Current (2026-06-27) — on-device QA of the BYO-AI tools; build 133 staged, NOT uploaded

Builds 127-132 shipped this session (Monday-week cutover, screen-wide week swipe, customizable per-screen
assistant prompts, AI error clarity + OpenAI/Anthropic structured-output 400 recovery). Build 132 fixed the
Anthropic prefill rejection. **Build 133 (committed, c3a5eb2) staged but BLOCKED from upload:** this Xcode
(26.0.1/17A400) reports the iOS 26.0 **device platform + simulator runtime as uninstalled** — archive
destination resolution and actool both fail. App+package Swift compile cleanly vs the iOS 26 SDK; 298 CK tests pass.
Two build-133 fixes (from on-device screenshots): `381f50d` BYO request timeout 60s→180s (week-gen "request
timed out"); `f652952` surface the real DecodingError on recipe/meals payload ("Could not read the recipe payload").

**Blocker (human):** install iOS 26.0 platform + a simulator runtime via Xcode > Settings > Components, then run
`scripts/release-ios.sh` to upload build 133. Likely-pending decode follow-up: if the surfaced reason names
ingredients/steps wrong-type, make the app-level decode tolerant of string-array ingredients/steps.

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
