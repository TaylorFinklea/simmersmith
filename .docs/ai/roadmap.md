# Roadmap

> Durable goals and milestones. Updated when scope changes, not every session.

## Vision

SimmerSmith is an AI-first meal planning app for the App Store. AI is the star — it plans your week, optimizes your grocery list, and makes every part of meal planning easier. Apple-native architecture (since 2026-06): CloudKit is the data plane (household zone via CKSyncEngine + cross-account CKShare; NSPersistentCloudKitContainer private plane; iCloud account = identity, no sign-in), and AI runs BYO-key direct from the device (OpenAI / Anthropic / Ollama Cloud / NeuralWatt). The legacy FastAPI/Fly.io backend is being retired (SP-D, bead epic 990 — port-then-retire per decisions.md ADR-1 2026-07-01).

**Design direction**: Rich & dark editorial aesthetic with AI as a prominent floating action. Week, Recipes, and Assistant are the three core tabs.

## Now / Next / Later

Active items. Trim as completed.

### Now

**The six-week depth+stability program (2026-07-14 — audit-driven; owner-locked).**
Owner decisions 2026-07-14: **depth + stability BEFORE submission** (supersedes submit-ASAP) ·
~6 weeks to submission · launch FREE, paywall dark (ADR-2 confirmed; gateway post-launch behind
the activation gate) · restore recipe-photo rendering · hide the grocery feedback swipe, port
Plan Shopping only if it stays bounded · assistant gets streaming + first reversible write tools
pre-launch (owner override of Sol's stricter cut). Full audit: `phases/arch-audit-2026-07-14-report.md`
(45+ findings, 24 new beads, 30+ updated). Queue = `bd ready`; epic `0lm` + runbook still define
submission done-ness — the program below is HOW the next six weeks get there.

- **Wk1 — stop-ship safety + truth**: `deh` (debug check destroys real data — MUST ride build 154)
  · `48y` (assistant wrong-week + allergy bypass) · `dkj` (send-ack erases newer edit) · `91e`
  (migration receipts) · `f0s` (attendee deletes) · `7in` (epoch interiors) · `l4i`-stage-1 +
  `akv` (nutrition truth: hide false Drift, unhide free estimate + scanner + substitutions) ·
  `xwb`-stage-1 (stop invisible image spend) · hide 4ii entry points + `32i` swipe · `dac`/`kby`
  (dead surfaces + Settings truth) · `eig` neuter · timeboxed `z69.3` (app tests in CI).
- **Wk2 — persistent mirror in SHADOW mode** (`e0a` phase 1): transactional scoped mirror runs
  beside the full fetch, digest-compared; crash/replay/token-skew tests. Sel/build 157 captured the
  latency gate and exposed a fail-safe quarantine caused by a no-op grocery-repair sync loop; the
  TDD fix is green and build 160 must clear the online/offline device rerun. `2g1` context caps.
- **Wk3 — cached-launch cutover** (`e0a` phase 2): stop deleting the token; cached UI before
  reconciliation; orthogonal boot/sync states; exact-scope/authority gates; two-device +
  account-switch (`yqm`) + crash-recovery/token-resume device proof. Written staged/default-off
  spec: `phases/e0a-cache-first-cutover-spec.md`; `8qy` runs separately only if measurements prove
  projection scans block the absolute launch target.
- **Wk4 — product depth**: `jfn` onboarding (submission scope) · `wkx` week-gen eval slice ·
  `2d1` assistant ladder (reads → proposals → merge commit → reversible grocery writes) ·
  `xwb`-stage-2 photo rendering · `4ii` deterministic Plan Shopping if bounded · `l4i`-stage-2
  macro pass · `1sz` critical-journey a11y · `0g5`+`79y` (MetricKit + four-boundary diagnostics).
- **Wk5 — release closure**: `3sf` streaming (cut FIRST if slipping) · `5w8`+990.11 privacy/terms
  re-host · `9wr` grant revoke · `pb8` prod schema · `vwq` metadata/screenshots · 990.8 Fly strip
  (quarantine + CI grep gate, per conditions on the bead) · RC1.
- **Wk6 — soak + submit**: no features; device matrix (clean install, migration, two-device storm,
  offline, account switch, share lifecycle, keyless walk); RC defects only; submit.

**Standing device gates** (ride every build): `6uj` `a97` `nli` `3hn` `cnx` `cel` `f5e` `auc` `mmi`.
**Post-launch (unchanged order):** 990.9–.12 retirement tail · credits gateway `bx1`→`98v` behind
the activation gate · z69.1/.2 full structural extraction (re-scoped: only e0a's seams pre-launch)
· assistant write-tool ladder steps 5-6 · `a0a` web search (read-only mode) · SP-B AFM at iOS 27.

**Completed track history (details in decisions.md ADRs + phases/* reports):**
- SP-A CloudKit data plane — COMPLETE 2026-06-18 (household zone, CKShare, merge, migration runner).
- SP-C full app cutover — COMPLETE 2026-06-22 on `main` (CloudKit data + BYO-key AI; no central
  server). Remaining Fly-backed stragglers = SP-D port beads under epic `990`.
- Sharing v1 / Backup & Restore / voice planning / open-models providers / token streaming —
  shipped 2026-06-28..07-09; device gates beaded. Open models = Ollama Cloud + NeuralWatt
  (OpenRouter retired 2026-07-09, `5890cc8`).
- Ballast voice parsing — default-OFF adapter shipped in TestFlight build 160 with a 60-case
  synthetic golden corpus. Mock results prove wiring only; build 160 still uses the existing cloud
  parse flow and does not exercise Ballast. Enablement remains blocked until `simmersmith-zyp`
  passes the live hardware/non-inferiority gate. See the
  [quarantine ADR](decisions.md#2026-07-15--ballast-voice-parse-adapter-remains-quarantined-and-default-off).
- Architecture reviews v1+v2 (2026-07-01/02) rebuilt the backlog in beads; arch-v2 P1 data-safety
  wave landed 2026-07-02. **arch-v3 (2026-07-09)** = delta review of the post-v2 commits + forward
  track architecture (below).
- SP-D (Fly retirement) = post-launch tail (launch does NOT wait for it); SP-B (on-device AFM
  tiering) waits for iOS 27 GA (bead `95h`).

### Awaiting User / External

All user-blocked work is beaded (`bd ready` shows it): push `main` (`tjc`) · build 151 TestFlight
device gates `6uj` (Gate-1 regression), `a97`
(sharing), `nli` (voice), `3hn` (backup recover), `3sf` (streaming), `cnx` (Reminders) · product
test (hdeck `p1-milestone-product-test`) · `9wr` PUBLIC-grant revoke + `pb8` prod schema
(CloudKit Dashboard ops) · ASC privacy nutrition label (rides `5w8`). Ongoing: TestFlight dogfood
(Taylor + Savanne).

**New user decision when monetization activates:** Pro products must ship with Family Sharing
**off** (`isFamilyShareable = false`) — see decisions.md 2026-07-09; enabling it without
per-member identity is a data-integrity regression, not a growth lever.

### Post-launch tracks (architected 2026-07-09; each has a spec + beads)

Ordered by dependency, not appeal. None may be pulled forward before submission.

1. **Fly retirement (epic `990`)** — schema for `990.4` (RecipeMemory) **signed**; ports
   `990.4.x` / `990.5.x`, then the retirement chain `990.8`–`.12`. Gate-2 rule stands: land the
   ports OR hide the surfaces; visible-but-broken is not shippable.
2. **Credits gateway (`bx1` → `98v`)** — `phases/credits-gateway-spec.md`. Keyless users get
   cloud AI via a Cloudflare Worker + D1 + per-subject Durable Object, funded by the Pro
   subscription's monthly allowance plus a one-time starter grant. Panel-reviewed; two criticals
   (Family Sharing identity, D1 double-spend) folded in. Children `gw-1`–`gw-7` file when the
   ADR is accepted.
3. **Structural (`z69.1`–`z69.6`)** — `phases/structural-track-spec.md`. AppState is 8,228 lines
   across 19 files. S1 coordinator → S2 seams → **S3 app-target test host** (the point: app-side
   work becomes command-verifiable, hence cheap-model dispatchable) → S4 domain fan-out / S6 tool
   capability boundary. `z69.1` is blocked on `glw` (same files).
4. **AI & product features** — `phases/ai-feature-track-spec.md`. Wave 1 hygiene (`nt2`, `fbn`,
   `3pa`, `h2h`) is dispatchable now. Wave 2 (assistant depth: `2d1`, `a0a`, `3sf`) is gated on S6
   and on keyless users being able to reach it at all. Wave 3 (`95h`, `zyp`, `exc`) is iOS-27 /
   product-gated. `exc` is settled: **no conversational onboarding interview** (decisions.md).

### Next (committed milestones — specced 2026-05-14)

**M23.1 — Cart automation completion** (spec:
[`phases/cart-automation-completion-spec.md`](phases/cart-automation-completion-spec.md))
- Framework shipped 2026-05-15: `capture` subcommand, `locate()`
  domain-error helper, Sam's Club + Instacart driver scaffolds with
  empty `_SELECTORS` maps wired into the splitter via
  `_hint_needs_capture()` so the orchestrator routes around them
  until populated.
- **Remaining (interactive)**: Taylor runs `login --store sams_club`
  + `capture --store sams_club`, transcribes selectors into
  `stores/sams_club.py::_SELECTORS`, repeats for Instacart, then
  validates with a small fixture grocery list.

### Recently completed

**M21 follow-ups — Owner transfer + member removal** (shipped 2026-05-18 — build 100)
- `POST /api/household/transfer-owner` and
  `DELETE /api/household/members/{user_id}` (single endpoint handles
  both "leave" and "kick" semantics).
- Removed users get a fresh empty solo via the existing
  `create_solo_household` so no-household limbo is unreachable.
- Owner can't leave or be removed without transferring first.
- 17 new pytest cases; 435 total passing.

**Anthropic web search support** (shipped 2026-05-18 — build 99)
- Provider router in `recipe_search_ai.py` mirroring the
  `recipe_image_ai` pattern: user setting `recipe_search_provider`
  > global `ai_recipe_search_provider` > "openai" default.
- Anthropic Messages API + `web_search_20250305` tool path returns
  the same `_AIRecipe` shape as OpenAI so the iOS client doesn't
  care which one answered.
- 13 new pytest cases.

**M24.1 — Apple/Google web SSO on /oauth/authorize** (shipped 2026-05-15 — build 98)
- Real Apple Sign In for Web + Google Sign In for Web replace the
  V1 bearer-token-paste user-auth step (which stays as a dev /
  admin fallback under a collapsible).
- New `app/services/sso.py`: state JWT (HS256, provider-scoped,
  10-min TTL), Apple ES256 client_secret minting per token-exchange
  (no long-lived secret stored), web-flavored id_token verifiers,
  find-or-create user helpers reusing `apple_sub` / `google_sub`
  columns from iOS auth so web sign-in matches existing accounts.
- 4 new endpoints; authorize-page buttons each gated by env presence.
- 21 new pytest cases.
- **Awaiting user**: Apple/Google portal config + 6 Fly secrets.

**M24 — Remote OAuth MCP server** (shipped 2026-05-15 — build 97)
- 55-tool `app/mcp/` surface mounted at `simmersmith.fly.dev/mcp`
  behind OAuth 2.1 + PKCE (S256).
- RFC 8414 metadata, RFC 7591 dynamic client registration, stateless
  JWT access tokens (aud="mcp", 30-day TTL).
- Per-request user scoping via ContextVar; stdio path falls through
  to `local_user_id` so internal Codex routing keeps working.
- 17 new OAuth pytest cases.

**M22 + M22.1 + M22.2 — Grocery list polish + Reminders sync** (shipped 2026-05-03)
- Smart-merge regen preserves user edits (`is_user_added`,
  `is_user_removed`, `quantity_override`, `unit_override`,
  `notes_override`).
- Server-side household-shared check state.
- Per-event `auto_merge_grocery` toggle (default on).
- 5 new mutation routes under `/api/weeks/{id}/grocery/...`.
- iOS 5th tab + add/edit/remove + EventKit two-way Reminders bridge.
- Settings → Grocery → "Sync to Reminders" with list picker.
- **M22.1**: BGAppRefreshTask wakes the app to sync Reminders while
  backgrounded.
- **M22.2**: `event_quantity` column tracks event contribution
  separately so smart-merge regen can refresh week-meal portion
  without disturbing event additions.

**M23 — Cart automation skill** (scaffolded 2026-05-03; complete to
the level of "Aldi + Walmart drive carts; Sam's Club + Instacart
need real selectors after first-run login")
- `skills/simmersmith-shopping/` — full Python package with parser,
  reminders reader, splitter, per-store handlers, CLI.
- Aldi + Walmart Playwright drivers with real selectors.
- Sam's Club + Instacart login flows working; product search +
  cart-add stubbed (return empty list, splitter avoids them).
- `setup.sh` symlinks the skill into `~/.claude/skills/`.

**Later candidates** (post-M23.1 + M24)
- **Pro-gate household sharing** — tie existing household
  invitations to the Pro entitlement once M5 activates.
- **profile_settings split** — household-scoped keys (timezone,
  store info, household_name, week_start_day) move into
  `household_settings`. Tracked since M21 Phase 2; deferred again as
  the user-visible behavior is unaffected.
- **Image-gen failover** — OpenAI 5xx → retry once via Gemini. Was
  saved-for-dogfood; agent-doable when ready.

### Soon
- Backfill helper: a Settings button that runs difficulty inference on every recipe still missing a score.
- Instacart "shop now" affiliate integration (M2 secondary).
- Spoonacular estimated pricing fallback (M2 secondary).

### Later
- Provider-aware prompt tuning if Gemini benefits from a different prompt shape (M17 follow-up).
- Image-gen failover (OpenAI 5xx → retry once via Gemini) — saved for if dogfooding demands it.
- Per-user push quiet-hours customization (M18 ships a hard 22:00–07:00 window).
- Thread-deep-link routing for the AI-finished push (today's deep link parses `?thread_id=` but only routes to the assistant tab; opening the specific thread is a follow-up).
- Multi-machine push scheduler safety (Postgres advisory lock) — only if we scale past one Fly machine.

### Deferred (M7 Phase 6 only — Phase 5 was already done as M19)
- Phase 6: True per-day `generate_week_plan` (7× tokens; flag cost before shipping).
- (Phase 5 / Anthropic tool-use parity shipped 2026-04-30 as M19;
  `assistant_ai._run_provider_tool_loop` + `AnthropicAdapter` handle
  both providers. Roadmap entry above was stale.)

### M5 status (corrected 2026-05-14)

The "deferred — none done" framing was stale. The freemium /
subscription / paywall infrastructure is fully built across
backend (`app/services/entitlements.py`,
`app/services/subscriptions.py`, `app/api/subscriptions.py` with
`/verify` + `/apple-webhook`) and iOS (`Features/Paywall/`,
`AppState+Subscription.swift`, StoreKit linked). Builds 93–95
added the admin portal that tunes the freemium knobs. The gate is
currently dark via `trial_mode_enabled` ("free Pro for everyone
during beta"). What remains: App Store Connect product
configuration for `simmersmith.pro.monthly` / `.annual`, a
`.storekit` testing config, sandbox purchase validation, and the
decision to flip trial mode off. Treat M5 activation as a live
candidate once M24's tool-call cost question lands.

## Backlog — ultracode bug bash 2026-06-13

Full report: `.docs/ai/phases/bugbash-2026-06-13-report.md` (149-agent workflow:
55 confirmed bugs + 62 architecture findings, 10 refuted). Dominant theme was the
unfinished M21 household pivot.

- [x] **T1 — household-scoping cluster (9 bugs) — DONE `694ea92`** (2026-06-13).
  weeks/staples UNIQUE re-keyed to household_id (migration 0047), create_or_get_week
  savepoint recovery, update_profile/pantry/feedback/MCP-assistant/push-scheduler/
  week-planner all household-scoped. 11 new tests, suite 511 green, live AI verified.
- [x] **T7 — observability + error-handling — DONE `d772f9e`** (2026-06-13). Folded
  in the surfaced AI-gen-timeout/500: `configure_logging()` (root INFO→stdout, new
  `SIMMERSMITH_LOG_LEVEL`); global handlers (unhandled Exception → logged generic
  500 no-leak; OperationalError → 503+Retry-After); `/api/health/ready` SELECT 1;
  `AIProviderError` wraps provider timeout/HTTP/parse → generate route 503;
  `ai_timeout_seconds` 120→300. 7 new tests, suite 518 green, live-verified
  (forced timeout → 503 + logged). Remaining T7 follow-ups (separate scope): the
  ~30 `detail=str(exc)` route sites + the streaming-loop/vision_ai unwrapped
  provider calls + truncation detection (arch report AI-LLM + error-handling).
- [x] **T6 — crashes / dead features (4 bugs) — DONE `f770815`** (2026-06-13). #18
  rebalance-day AttributeError 500 (WeekMealIngredient.meal_id→week_meal_id;
  live-verified 200 with real AI), #3 cancelled-turn unreadable thread (added
  'cancelled' to AssistantMessageOut.status Literal), #33 import "1/0"
  ZeroDivisionError (guarded), #1 kid-friendly preset tuple-comma corruption.
  5 new tests, suite 523 green.
- [x] **T4 — event↔week grocery merge lifecycle (5 bugs) — DONE `9446002`** (2026-06-14).
  #9 delete-event grocery orphan, #10 re-date doesn't re-point, #11 manual-merge
  dropped on edit (new events.manually_merged flag, migration 0048 + keep_link),
  #37 rename strands rows (name-agnostic marker), #38 AI-regen sort_order collision.
  6 new tests, suite 528 green, live-verified routes + migration round-trip.
- [x] **Backend backlog sweep (19 findings) — DONE `2c84c05`,`478f9b8`,`bd4a9fb`** (2026-06-14).
  All remaining BACKEND bug-bash findings (T3 IDOR #5/#13/#17, backend mediums/lows,
  T7 follow-ups) via an 11-lane file-disjoint workflow (implement → adversarial
  review → integrate). Adversarial review caught 5 real bugs pre-commit. 92 new
  tests, suite 592 green, live AI verified (week-gen + macro-drift + assistant stream).
- [x] **iOS bug-bash findings (16) — DONE `9b50280`** (2026-06-14). All `ios-*`
  findings: FAB slot overwrite/locale, alias/event error surfacing, reminders
  mapping defer, push-token persist-after-success, subscription stale/revoked,
  paywall Terms→/terms, MealIcon tea/egg, + 5 low nits. xcodebuild SUCCEEDED;
  sim-verified (app runs + MealIcon screenshot). project.yml 106→107 (pbxproj
  regenerated by release-ios.sh at archive time).
- [ ] **Remaining bug-bash findings** — itemized in the report:
  - **2 shopping-skill** — already re-swept earlier (`98376b9`); re-confirm if revisiting.
  - **T5 freemium-not-enforced** — ungated recipe_import/pricing + uncapped assistant
    turns; has product decisions (entitlement unit, assistant gating), monetization-adjacent.
  - **Architecture STRUCTURAL** — FKs on household_id, metadata naming_convention,
    RLS/defense-in-depth, pagination, AI truncation detection, JSON-extractor unification.
    Design-heavy, not line-bug fixes. tier_floor: lead/senior · complexity: mixed.

## Backlog — bug sweep 2026-05-30 (unfixed confirmed findings)

Full report: `.docs/ai/phases/bug-sweep-2026-05-30-report.md`. 14 confirmed
critical/high already fixed (commits `21072f4..5e31ef7`). Remaining:

- [x] **F22 — Apple IAP receipts forgeable (CRITICAL) — FIXED `2c17b0f`** (set `SIMMERSMITH_APPLE_IAP_APP_APPLE_ID` before M5). `app/services/subscriptions.py` `verify_transaction_jws`/`decode_signed_payload` verify against the JWS-embedded leaf key without validating the x5c chain to Apple Root CA - G3. **Fix BEFORE flipping `trial_mode_enabled` off (M5).** Acceptance: a self-signed forged JWS is rejected; a real sandbox receipt verifies. Verify: new pytest with a forged chain. Tier: Opus to scope (decision: `app-store-server-library` vs hand-rolled pinning); pairs with F23/F24 (replay/dedup, `appAccountToken`, webhook freshness).
- [x] **F11 — MCP per-request identity (CRITICAL/latent) — FIXED `6d9336e`** (`stateless_http=True`; ⚠️ smoke-test the Claude.ai connector before deploy). `app/mcp/auth.py` ContextVar frozen at session creation. Read identity from MCP request context / `scope["user"]` instead. Verify: integration test calling two tools with two bearer tokens on one connection asserts each sees its own household. Tier: Opus.
- [x] **F9 — SSE orphaned blocking threads — FIXED `dfa29bd`** (`app/api/assistant.py:370-388`). Replace `asyncio.to_thread(queue.Queue.get)` with `asyncio.Queue` + `call_soon_threadsafe`. Verify: assistant flow streams + no thread leak. Tier: Sonnet/Opus — delicate.
- [x] **F10 — tool-runner partial commit — FIXED `5c9ecfe`** (`app/services/assistant_tools.py:933-942`). `session.rollback()` (or savepoint) before returning `ok=False`. Verify: a tool that raises post-delete leaves the week intact. Tier: Sonnet/Opus — delicate.
- [x] **F26/F27 — ingredient cross-household IDOR — FIXED `561a752`** (global catalog stays collaborative by design) (`app/api/ingredients.py`, `app/services/ingredient_catalog/variation.py`). Needs governance decision (admin-only for `approved` global rows?). Tier: Opus to scope.
- [x] **F28 — recipe-import SSRF — FIXED `e71195b`** (`app/services/recipe_import/parser.py`, `app/schemas/recipe.py`). Resolve + validate A/AAAA vs private ranges; disable/revalidate redirects. Tier: Sonnet.
- [x] **F23/F24 — IAP replay/dedup — FIXED `0879339`** (notificationUUID dedup table, signedDate freshness, monotonic last_transaction_id, terminal-status period freeze, forward-compatible appAccountToken). Remaining follow-up: iOS must set `Product.PurchaseOption.appAccountToken` at purchase to fully activate the rebind check.
- [x] **F20 — `household_id` NOT NULL migration — FIXED `cf421cc`** (migration 0043, batch_alter_table). Deploy note: backfills NULLs from user_id first; on Postgres it's `ALTER ... SET NOT NULL`.
- [x] **F16/F17/F29 — iOS — FIXED `df67196`** (clearLocalCache resets leaked fields; meal feedback routes by displayed week; PushService.reset on sign-out). **⚠️ Swift — needs an iOS build smoke-test (sign-out/switch-account, rate a browsed week's meal) before release.**
- [x] **Medium security pass:** `jwt_secret` strength warning + SSO state aud/iss — FIXED `21b191e`; ingredient-detail/variations IDOR read — FIXED `6a52c1c`. Closed as NOT-real: session-JWT alg pinning (PyJWT pins it; symmetric secret) and whitespace-token free-tier bypass (open-mode == open-auth, same expression).
- [x] **Medium/low pass — Batches A–H (~71 findings) — DONE `0e34ab3..d7ae052`** (2026-05-30 pm). Backend 510 passed/1 skipped, ruff clean; SimmerSmithKit `swift build` clean; iOS app-target changes flagged needs-build. Per-batch breakdown in `current-state.md`. New migration 0046 (`uq_household_members_user`). Remaining deferred items below.
- [x] **Re-swept `skills/simmersmith-shopping/`** — 2026-06-02 (`98376b9`). Fixed 5 bugs (splitter dropping items, osascript comma desync, PyXA list-not-found masked, parser ZeroDivisionError, store-driver unencoded search URLs). 13 tests pass.

### Deferred sweep findings — ALL CLEARED 2026-06-02 (`c7f9178..54f0fc7`)

Product decisions taken: AI/MCP-resolved ingredients are **household-private**
(not global approved); **Kroger pricing dropped** (not hardened). iOS build +
backend suite + live smoke all green.

- [x] **M63 — resolve provisional-row pollution → household-private** `725baf0`. resolve_ingredient gained `household_id`; threaded through MCP resolve, REST resolve, recipe save, AI drafts, reresolve. Existing approved rows reused.
- [x] **M62 — ingredient COUNT N+1 → batched** `c7f9178` (`ingredient_counts_bulk`, 4 GROUP BYs).
- [x] **M8 — nutrition estimate cross-household ref → nulled** `725baf0` (`_scope_nutrition_refs`).
- [x] **M37 — Kroger dropped** `54eb4b1` (backend) + `54f0fc7` (iOS). See current-state for what was removed vs kept.
- [x] **M64 — draft previews no longer persist** `725baf0` (resolve `persist=False`).
- [x] **M66 — SSO nonce** `c7f9178`.
- [x] **M40 — iOS plan-shopping week routing** `54f0fc7` (built clean).

- [x] **iOS Kroger dead-code cleanup — DONE** 2026-06-02 (`369d2e9`). Deleted StoreSelectionView, BarcodeScannerView, GroceryView fetch-prices code, AppState.lookupProductByUPC, the dead Kit API methods + models, and stale Kroger UI (paywall bullet, assistant suggestions, Settings usage row). Kept the generic price display. `xcodebuild` clean; shipped in build 106.

## Infrastructure (complete)

- [x] Backend deployed on Fly.io + Fly Postgres
- [x] Apple/Google auth endpoints + session JWT
- [x] Multi-user data isolation (65 tests + 7 isolation tests)
- [x] Code quality audit + security hardening
- [x] Backend + iOS module decomposition

## R1: Core Flows (complete)

- [x] Sign in with Apple (iOS -> backend -> session JWT)
- [x] AI week planning (prompt -> OpenAI -> 21 meals + recipes)
- [x] Grocery generation (auto from AI draft)
- [x] Recipe import (in-app browser + HTML extraction)
- [x] Recipe UX (ingredient autocomplete, editorial detail view)

## R2: Visual Redesign (complete)

- [x] Design system (SMColor, SMFont, SMSpacing, SMRadius)
- [x] Dark theme forced app-wide
- [x] 3-tab structure (Week, Recipes, Assistant) + Settings as sheet
- [x] Week: today/tomorrow/rest sections, interactive meal cards, week navigation, empty slot quick-add, meal move/swap, recipe linking
- [x] Recipes: curated sections (Tonight's Dinner, This Week, Favorites, Recently Added), list/gallery toggle, meal-type filters, wrapping chips
- [x] Recipe detail: ingredients/steps toggle, compact calorie chips, wrapping metadata
- [x] Assistant: dark chat theme
- [x] Settings: dark sheet with sign-out
- [x] Grocery: dark sheet with Done button
- [x] Sign-in: Apple + Google buttons (Google placeholder)

## R3: TestFlight Prep (complete)

- [x] ExportOptions.plist for App Store Connect upload
- [x] Version bumped to 1.0.0 (build 3)
- [x] Archive + export IPA
- [x] Upload to TestFlight
- [x] Privacy policy URL

## M1: AI Planning Excellence (regressed by the CloudKit cutover; **restored 2026-07-09** by `b9z`)

Make the AI the star of the app. Built on Fly; the planner uses preference signals, meal history,
staples, and feedback to generate personalized plans.

> **What happened, kept as the record.** Two of these were marked `[x]` complete and were **not
> running** on the shipping CloudKit architecture. They were true on Fly and died silently in the
> cutover; two architecture reviews (80 agents, then 114) trusted the checkboxes instead of the
> code, and it took a *product-proposal* fleet — whose critics had to check whether the features
> their proposals built on were real — to notice. Do not read a `[x]` here as evidence a feature
> runs. Both are genuinely restored now, with a runnable end-to-end test (`6bc28a5`).

- [x] **Preference-aware week planning** — restored `6bc28a5`. `WeekGenContextGatherer` derives
      `strongLikes` / `likedCuisines` / `dislikedCuisines` from stored signals.
- [x] History-aware deduplication (pass recent 2-3 weeks of meals, avoid repeats)
- [x] **Feedback loop** — restored `6bc28a5`. Rating a meal writes recipe + cuisine
      `PrivatePreferenceSignal` rows (private plane, per-user scope) that reach the planner.
      Grocery-item feedback is still dead by deliberate scope cut — bead `32i`.
- [x] Staple awareness (tell AI what's in the pantry to leverage)
- [x] Post-generation quality scoring (score_meal_candidate on each recipe)
- [x] Deduplication guardrails (max 3 reuses per recipe per week)

**Still live** (do not conflate): the ingredient avoid/allergy path *is* wired —
`WeekGenContextGatherer.swift:46-60` merges allergies into `hard_avoids` and emits the emphasized
allergy prompt line.

## M2: Store-Specific Grocery Pricing (complete)

Must-have for launch. Kroger API selected as primary integration.

- [x] Research and select grocery pricing API — Kroger API (free, real store prices, 2,750+ stores)
- [x] Kroger API client (OAuth2, product search, location search)
- [x] Live pricing fetch endpoint (POST /api/weeks/{id}/pricing/fetch)
- [x] Store search endpoint (GET /api/stores/search?zip=...)
- [x] Relaxed retailer schema (supports kroger + existing retailers)
- [x] Store selection + configuration in iOS (`StoreSelectionView`)
- [x] Price display in grocery list (per-item + weekly total)
- [x] "Fetch Kroger prices" button in Grocery view
- [ ] Instacart "shop now" integration (secondary, affiliate revenue — deferred)
- [ ] Spoonacular estimated pricing fallback (deferred)

## M3: App Store Submission (in progress)

Complete remaining launch prerequisites and submit.

- [ ] TestFlight validation + bug fixes (build 8 on device, eating-out / timezone / Fetch Prices fixes shipped)
- [x] Google Sign-In SDK integration (GoogleSignIn-iOS SPM, restore-on-launch + signOut wired)
- [ ] App Store metadata (description, keywords, category, screenshots)
- [ ] Submit for App Store review

## M4: Nutrition-Aware AI + Dietary Goals (complete on Fly; **NOT running on CloudKit** — 2026-07-14 audit)

> **Correction (2026-07-14, kept as the record):** on the shipping CloudKit architecture the
> macro pipeline is structurally nil (`WeekRecordMapper` hardcodes nutrition; the client-side
> recompute was never built) — worse, the UI asserts false red "Drift" verdicts when a goal is
> set. Bead `l4i` (hide the lie, then build the deterministic client pass). The checkboxes below
> describe the Fly era only.

> Spec: `.docs/ai/phases/nutrition-goals-spec.md`

Post-launch stickiness milestone. Users set a dietary goal; the AI planner hits it; the app shows per-day and per-week macro progress. Builds on the existing USDA FDC ingredient catalog. Enables the future premium tier.

- [x] Ingredient macros (protein/carbs/fat/fiber) via Alembic migration
- [x] Curated macro seed (~82 common ingredients) + USDA/OFF ingest extended to capture macros
- [x] `DietaryGoal` model + settings UI
- [x] Per-meal / per-day / per-week macro aggregation on `WeekOut`
- [x] Planner prompt + post-generation scoring against the goal (macro-drift flags)
- [x] iOS macro rings on Today hero + each day card + weekly total chip
- [x] Day-breakdown nutrition sheet
- [x] "Rebalance this day" AI CTA when a day drifts ≥±15%

## M5: Freemium + Subscription (deferred — postponed 2026-04-20)

> Spec: `.docs/ai/phases/freemium-subscription-spec.md`

The AI generations + Kroger + macros cost real money to run. Ship StoreKit 2 + server-enforced usage limits so the app can pay for itself.

- [ ] `Subscription` + `UsageCounter` models + Alembic migration
- [ ] `is_pro` / `ensure_action_allowed` / 402-on-limit gate on AI/pricing/rebalance endpoints
- [ ] Apple JWS verification + `POST /api/subscriptions/verify` + App Store Server Notifications v2 webhook
- [ ] StoreKit 2 client + paywall sheet + Settings subscription row
- [ ] App Store Connect products (`simmersmith.pro.monthly`, `.annual`) + TestFlight sandbox validation

## M6: Conversational Planning (complete)

> Spec: `.docs/ai/phases/conversational-planning-spec.md`

Reworked the AI experience from two disconnected surfaces (one-shot sparkle + isolated Assistant chat) into one conversation. The Assistant has tool access to the current week (read + write), the Week page is the execution view of what the Assistant built, and "plan my week" is a dialogue.

- [x] Assistant tool registry + gate reuse (11 tools)
- [x] Mutation tools (add/swap/remove meal, rebalance day, fetch pricing, set dietary goal)
- [x] Incremental `generate_week_plan` (day-by-day commit + `week.updated` per day)
- [x] Week-aware system prompt + `linked_week_id` per thread
- [x] iOS tool-call cards in Assistant + `week.updated` SSE handler
- [x] Week → Assistant entry points (sparkle opens a linked planning thread)
- [x] Per-day "Ask AI" button + active-chat chip on the Week page

Deferred (future polish):
- Anthropic tool-use support (OpenAI direct only for now; Anthropic threads fall back to the envelope-JSON path)
- True per-day AI generation (one call per day) — current implementation keeps a single AI call but applies day-by-day so the client sees progressive state updates

## M7: Assistant Polish + Post-Launch Growth

After M6 is shipped.

### Assistant polish (open from the 2026-04-20 shakedown)
- [x] True token-by-token streaming via OpenAI `stream: true` (was: chunk-on-complete)
- [x] Tolerant `AssistantToolCall` decoder (missing `ok`/`detail` on running events)
- [x] Fix "cancelled" error on pull-to-refresh — dedicated streaming URLSession so it's isolated from the shared session
- [x] Hallucination guardrail — amber "Nothing changed" affordance when the AI narrates an action without firing a tool
- [x] Persist streamed deltas server-side as they arrive (throttled to 500ms)
- [x] Cancel the SSE stream + abort the assistant turn when the user dismisses the sheet mid-stream
- [x] Phase 5 — Anthropic tool-use parity (shipped 2026-04-30 as M19; provider-agnostic adapter)
- [ ] True per-day AI generation (one AI call per day of `generate_week_plan`) — deferred, 7× token cost

### Post-launch growth
- [ ] Household sharing tied to a Pro seat
- [ ] Recipe images (AI-generated or fetched)
- [ ] Remote push notifications from backend (APNs integration)
- [ ] Proactive intelligence (leftover tracking, weekly theme, calendar-aware planning)

## M8: Smart Substitutions (complete)

> Spec: `.docs/ai/phases/smart-substitutions-spec.md`

AI-powered per-ingredient substitutions. Tapping the wand next to any
ingredient in recipe detail opens a sheet that asks the AI for 3-5
alternatives (with a short reason + optional adjusted quantity/unit),
respects the user's active ingredient preferences, and applies the
picked one via the existing recipe upsert flow.

- [x] `POST /api/recipes/{recipe_id}/ai/substitute` endpoint
- [x] `app/services/substitution_ai.py` + strict-JSON response parser
- [x] Preference-aware prompt (avoids re-introducing flagged items)
- [x] iOS `SubstitutionSheetView` + per-ingredient wand affordance
- [x] `applySubstitution` on AppState reusing `saveRecipe` upsert
- [x] "Replace recipe" vs. "Save as variation" choice after picking a
      substitute — variation mode uses the existing `variationDraft()`
      machinery so the new recipe links back via `baseRecipeId`

## M10: Event Plans (complete)

> Spec: `.docs/ai/phases/event-plans-spec.md`

A parallel planning surface for one-off gatherings (holidays,
birthdays, dinner parties). Structured reusable guest list with saved
allergies / dietary notes; AI menu generation that handles mixed
constraints (design for the majority, ensure each constrained guest
has at least one compatible dish per role); separate event grocery
list with merge-into-week support.

- [x] Phase 1 — backend data model + CRUD (5 tables, ownership tests)
- [x] Phase 2 — AI event menu generation w/ `constraint_coverage`
      mapped back to guest_ids
- [x] Phase 3 — event grocery list + merge/unmerge with weekly list
      (idempotent via `merged_into_week_id`)
- [x] Phase 4 — iOS Events tab, create flow, detail view
- [x] Phase 5 — Guest editor sheet (shared from event create; Settings
      entry point deferred as follow-up polish)
- [x] Phase 6 — Merge-to-week UI with current-week detection + undo

## M10.1: Event Polish v2 (complete)

Dogfooding fixes after first real Easter use:

- [x] Backend: `_aggregate_event_rows` skips assignee-brought meals so
      the host's grocery list reflects only what they're shopping for
- [x] iOS: "Guests bringing" subsection on event detail
- [x] iOS: `EventEditSheet` for editing event metadata after creation
- [x] iOS: ellipsis menu on event detail with Edit + Delete + dialog

## M9: Preference-Aware Planner (complete)

Closes the loop on M8. Rather than reacting to disliked ingredients
after they show up, the week planner now avoids them at generation
time. Users can flag ingredients via the wand menu on any recipe or
via Settings → Ingredient Preferences.

- [x] Backend: `choice_mode` accepts `avoid` + `allergy`;
      `gather_planning_context` merges these into `hard_avoids` and
      surfaces allergies on their own emphasized prompt line
- [x] Backend: `score_meal_candidate` flips `blocked=True` for meals
      containing avoid/allergy-flagged ingredients (defense in depth)
- [x] iOS Settings: amber "Avoid" / red "Allergy" pills on the
      preference list; editor hides brand/variation when irrelevant
- [x] iOS Recipe Detail: wand button became a Menu with "Substitute",
      "Never use this in my plans", and "I'm allergic to this"
      — catalog-resolved ingredients only

## M11: Photo-First AI (complete on dev; awaiting deploy + TestFlight 15)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

A product audit revealed that photo / multimodal AI was mentioned three
times in the original product notes and was entirely absent. M11 adds
all four flows in a single milestone, and lays the foundation
(`vision_ai`) for the future cooking-coach work.

- [x] Phase 1 — already shipped. Recipe scan via VisionKit /
      `RecipeImportView`'s existing scaffolding (audit blind spot).
- [x] Phase 2 — `app/services/vision_ai.py` foundation. Strict-JSON
      `identify_ingredient` + `check_cooking_progress` with image
      content blocks for OpenAI + Anthropic. 7 tests.
- [x] Phase 3 — Scan ingredient → identify + uses. Backend route +
      iOS `IngredientScannerView` w/ result card + Find Recipes action.
- [x] Phase 4 — Barcode scan → product lookup. Kroger UPC reverse
      lookup + iOS `BarcodeScannerView` (DataScannerViewController) +
      product card. Entry point in GroceryView.
- [x] Phase 5 — Cooking-progress check. Per-step "Check it" camera
      chip in RecipeDetailView opens `CookCheckSheet` → vision call →
      verdict + tip inline.

## M12: Quick AI Wins (complete; shipped to Fly + TestFlight build 16)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Lightweight follow-on to M11. Each phase ships independently.

- [x] Phase 1 — Pairings on recipe detail. `pairing_ai.py` + iOS
      `RecipePairingsCard` (collapsed by default, lazy-loaded on tap).
- [x] Phase 2 — Difficulty + kid-friendly. Alembic migration adds
      `difficulty_score: int? CHECK 1..5` + `kid_friendly: bool`.
      Opportunistic AI inference on save (best-effort). iOS gets
      filter chips and detail-header pills.
- [x] Phase 3 — User region + in-season produce. `seasonal_ai.py`
      with module-level dict cache keyed by `(region, year, month)`.
      iOS adds `InSeasonStrip` above Week day cards + a Settings
      free-text region field.
- [x] Phase 4 — AI recipe web search. OpenAI Responses API +
      `web_search` tool extracts a real recipe with citation. iOS
      `RecipeWebSearchSheet` previews and hands off to the existing
      recipe editor.

## M13: Cooking Mode (complete on dev; awaiting TestFlight 17)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Hands-free, big-text cook flow. Composes the M11 `cook_check` photo
chip and the existing assistant launch context into a focused
full-screen experience. iOS-only — no backend changes.

- [x] Phase 1 — `CookingModeView` skeleton. Big-text steps,
      progress bar, prev/next/ask-assistant/exit buttons, wake-lock,
      long-press step → existing `CookCheckSheet`. Toolbar pan icon
      + "Start cooking" button at the bottom of the steps section
      on `RecipeDetailView`.
- [x] Phase 2 — TTS step readout. `SpokenStepService`
      (`AVSpeechSynthesizer`) speaks each step on entry; mute toggle
      in the top bar persists via UserDefaults; AVAudioSession
      ducks background music during speech.
- [x] ~~Phase 3 — Voice commands~~ **STUBBED since Build 67** (2026-07-14 audit: mic button
      shows a static "coming soon" alert after a CoreAudio crash disable; `VoiceCommandService`
      has zero call sites and its dormant "stop" lacks the ADR-mandated confirmation — bead `dac`).
      Original Fly-era record: `VoiceCommandService`
      (on-device `SFSpeechRecognizer` + `AVAudioEngine`) recognizes
      next / back / repeat / stop. Auto-restarts every ~50s to dodge
      the ~1-min buffer limit. Live-caption pill, mic toggle,
      confirmation alert before exiting on a heard "stop".
- [x] Phase 4 — Manual quick timers + per-step polish.
      `CookingTimerChip` row (5/10/15/20/Custom), concurrent
      countdowns, haptic + TTS "Timer done." chime. Visible
      "Check it" button per step. "Done" on the last step shows a
      "Nicely done." toast on the recipe detail view.

## M14: AI-generated recipe images (**write-only since Build 81** — 2026-07-14 audit)

> **Correction (2026-07-14):** the Build-81 illustration redesign left `RecipeHeaderImage`
> rendering gradient+icon only — generation/upload/backfill all still work and still spend,
> but no photo ever displays. Owner decision 2026-07-14: restore photo rendering (bead `xwb`).

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Replace the gradient-only header placeholder with one AI-generated
photo per recipe. Phase 1 ships invisible plumbing; Phase 2 wires
generation on save; Phase 3 spreads to list cards + Settings
backfill.

- [x] Phase 1 — Plumbing. `recipe_images` table + serve route +
      iOS `imageURL` field + `RecipeHeaderImage` view replacing the
      gradient block in `RecipeDetailView`.
- [x] Phase 2 — Generation on save. `recipe_image_ai.py` calls
      OpenAI's `/v1/images/generations` (`gpt-image-1`) using the
      existing `SIMMERSMITH_AI_OPENAI_API_KEY`. Best-effort: a
      provider outage never blocks the save.
- [x] Phase 3 — List cards + Settings backfill. `HeroRecipeCard`,
      `CompactRecipeCard`, `RecipeCard`, `RecipeListRow` route through
      a shared `RecipeHeaderImage` view that renders `AsyncImage`
      bytes when present and falls back to the recipe-id-hash
      gradient. `POST /api/recipes/ai/backfill-images` + Settings
      "Generate missing images" button fill in pre-M14 recipes.

## M16: M14 polish — regenerate, manual upload, remove (in flight)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Three small affordances on the recipe detail toolbar so the user
isn't stuck with whatever the AI initially generated.

- [x] Single phase. Three new routes
      (`POST /image/regenerate`, `PUT /image`, `DELETE /image`),
      one shared utility (`PhotoCompression.swift`,
      consolidating the cook-check + memory-photo + image-
      override compression paths), one new sheet
      (`RecipeImageOverrideSheet`), and a Menu integration on
      `RecipeDetailView`. `RecipeHeaderImage` gains an
      `isLoading` overlay so regen shows a spinner.

## M17: Gemini-direct image-gen (complete on dev; awaiting deploy + TestFlight 27)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

The OpenAI image-gen path from M14/M16 gets a sibling Gemini
(`gemini-2.5-flash-image-preview`) path, picked per user via a
Settings toggle stored as a `profile_settings` row. No Alembic
migration. Default stays OpenAI so existing behavior is preserved.

- [x] Single phase. `app/services/recipe_image_ai.py` split into
      `_generate_via_openai` + `_generate_via_gemini` with
      `_resolve_provider(settings, user_settings)` dispatching
      per-call. `is_image_gen_configured` and
      `generate_recipe_image` gain a keyword-only `user_settings`
      param. Three call sites
      (save / backfill / regenerate) load `profile_settings_map`
      and pass it through. iOS Settings adds an OpenAI/Gemini
      Picker; `AppState+Profile.swift` mirrors the existing
      region-save flow.

## M17+ Future image-gen work

- [ ] **Cost telemetry.** Per-provider image-gen counts so we
      can confirm Gemini's cheaper-per-image claim.
- [ ] **Provider-aware prompt tuning.** Both providers currently
      share `_build_prompt`. If Gemini benefits from a different
      shape, split.
- [ ] **Auto-failover.** OpenAI 5xx/timeout → retry once via
      Gemini. Saved for if dogfooding demands it.

## M15: Recipe memories log (in flight)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Replace the static `recipes.memories` text blob with a per-cook
log of time-stamped entries plus optional photo attachments, so a
recipe accrues family history across cooks.

- [x] Phase 1 — Text memories. New `recipe_memories` table with an
      Alembic data-migration that copies any non-empty legacy blob
      into a single seed row per recipe. GET/POST/DELETE routes.
      `RecipeMemoriesSection` replaces the static memories block on
      `RecipeDetailView`; `MemoryComposeSheet` wraps a TextField +
      Save with empty-body validation.
- [x] Phase 2 — Photo attachments. `image_bytes` + `mime_type`
      columns + `GET …/photo` route mirroring the M14
      ETag/immutable-cache pattern. `MemoryComposeSheet` adds a
      `PhotosPicker` row with the same 2048px / JPEG 0.8 ceiling
      `CookCheckSheet` uses; rows render a 60×60 thumbnail when a
      photo exists; tap → full-screen viewer.

## M21: Household sharing (complete on dev; awaiting deploy + TestFlight 32)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Closes the long-standing single-user-per-account gap: spouses /
roommates can now share a Week, Recipe library, Pantry, Events, and
Guests under one household. Per-user data (taste signals, allergies,
push devices, AI provider toggle, timezone) stays user-scoped.

- [x] Phase 1 — Schema. New `households`, `household_members`,
      `household_invitations`, `household_settings` tables. `household_id`
      column on Week / Recipe / Staple / Event / Guest, backfilled from
      one-solo-household-per-user seeded for every existing user.
- [x] Phase 2 — Service rewrite + auth. `CurrentUser` carries
      `household_id` (lazy solo creation on first request). Every
      shared-table query flips from `user_id` to `household_id`.
      Writers populate `household_id` on construct.
- [x] Phase 3 — Invitation API + tests. 5 routes
      (GET/PUT household, POST/DELETE invitations, POST join). Auto-merge
      semantics: joining migrates the joiner's solo content into the
      target household and deletes the empty solo. 12 new tests.
- [x] Phase 4 — iOS surfaces. `HouseholdSnapshot` model + 5 API
      methods + `AppState+Household.swift` + `InvitationSheet`
      (code + ShareLink) + `JoinHouseholdSheet` + `HouseholdSection`
      in Settings between Sync and AI.
- [ ] Phase 5 — Ship. Build bump 31→32, push, fly deploy,
      TestFlight 32, on-device cross-account dogfood.

## M20: M18 follow-up pushes (complete on dev; awaiting commit + deploy + TestFlight 31)

Two missing pieces from M18 push notifications, both small.

- [x] **Cook-mode timer-end local notification.** When the user starts a
      cook-mode timer, schedule a `UNNotificationRequest` so a backgrounded
      timer still fires a banner. Cancel on dismiss or natural fire so
      foreground users don't get a duplicate banner. iOS-only; no backend.
- [x] **AI-finished-thinking push.** Fires after a planning turn that ran
      tools (`generate_week_plan`, etc.). Best-effort `asyncio.create_task`
      from inside the SSE generator after `assistant.completed` is yielded.
      New `push_assistant_done` profile_settings row (default on); third
      Settings toggle. iOS suppresses banners while foregrounded so this
      only surfaces when the user has the app backgrounded mid-turn.
      6 new tests covering the summarizer + per-user gate.

## M19: Anthropic tool-use parity (M7 Phase 5) (complete on dev; awaiting commit + deploy)

> Plan: `~/.claude/plans/plan-out-next-milestone-glowing-matsumoto.md`

Closes the long-standing M6 deferred item: Anthropic users now run the
same 11 tools the OpenAI path runs, instead of falling back to
envelope-JSON parsing. Backend-only milestone — iOS was already
provider-agnostic.

- [x] Single phase. `app/services/assistant_ai.py` gains a
      `ProviderAdapter` ABC + `OpenAIAdapter` + `AnthropicAdapter`.
      `_run_openai_tool_loop` is replaced by `_run_provider_tool_loop`
      driven by an adapter. Dispatch table picks the adapter by
      `target.provider_name`. Anthropic adapter handles the Messages API
      SSE shape (`content_block_start` / `input_json_delta` accumulation
      / `content_block_stop` / `message_delta`/`stop_reason`).
- [x] Tests: 7 new (1 schema parity + 3 Anthropic-loop scenarios + 2
      dispatch routing + 1 import sanity). Existing OpenAI abort test
      updated for the new adapter API. Full suite **242/242**.
- [ ] Commit + `fly deploy` to ship server-side.

## M18: Push notifications (APNs) (Phases 1-4 complete; awaiting deploy + TestFlight 28)

> Spec: `.docs/ai/phases/push-notifications-spec.md`

Backend → device pushes for "tonight's meal is X" (daily, 17:00 local
default) and "you have a Saturday plan to confirm" (Friday 18:00 local
default, only when next week is still draft). Both default ON; the
APNs permission prompt fires automatically once after first sign-in.

- [x] Phase 1 — Backend device registration + APNs sender. `aioapns`
      dep, `push_devices` table (Alembic 0025), `app/services/push_apns.py`,
      `POST/DELETE /api/push/devices`, admin `POST /api/push/test`.
      Token-based APNs auth (`.p8` key shared with Sign In with Apple).
- [x] Phase 2 — Backend scheduler. `apscheduler` dep, in-process
      `AsyncIOScheduler` boots in lifespan when configured. Two interval
      jobs at 5-min cadence: `_tick_tonights_meal` and
      `_tick_saturday_plan`. ZoneInfo-driven local-time matching, hard
      22:00–07:00 quiet-hours skip, in-memory `_sent_today` de-dup.
- [x] Phase 3 — iOS registration + Settings toggles. `PushService`,
      `SimmerSmithAppDelegate`, `AppState+Push.swift`, `NotificationsSection`
      in Settings. `ensurePushBootstrap()` auto-prompts after first
      profile hydration when toggles read enabled.
- [x] Phase 4 — Tests + verification. 18 new tests in `tests/test_push.py`
      including default-on semantics, quiet-hours, toggle-off,
      Saturday-skip-when-confirmed.
- [x] Phase 5 — Production cutover. `fly secrets set` + `fly deploy`
      (Fly v58) + `./scripts/release-ios.sh` cut TestFlight 28. On-device
      validation pending the user installing the build.

## Backlog

> Self-contained items any agent can pick up. Tier hints are advice, not gating.

- [ ] Design the AI preference interview conversation flow. **Tier hint**: needs Opus to scope.
- [ ] Design the freemium gate architecture. **Tier hint**: needs Opus to scope.
- [x] **PrivatePlaneStore (SwiftData/CloudKit) tests crash under macOS `swift test` (signal 5) — pre-existing, masked.**
  - **Scope**: The `SimmerSmithKitTests/PrivatePlaneStoreTests` (every test using `makeSimmerSmithPrivatePlaneContainer`) hard-crash (SIGTRAP) under `swift test` on macOS — CloudKit-capable `@Model` types in an entitled/"privileged" test binary. The `xctest` wrapper prints "Test Suite passed" even on the crash, so `swift test | tail` reports green — this masked the crash for the whole CloudKit-cutover effort. Confirmed pre-existing (crashes on `origin/main`); non-SwiftData Kit tests + all SimmerSmithCloudKit tests pass.
  - **Fix options**: run these tests under an entitled iOS test host (xcodebuild test via the app's test target) instead of `swift test`; OR guard them with a `.disabled`/availability trait when the entitlement isn't present so the suite stops crashing + stops masking. Either way, stop trusting `swift test --package-path SimmerSmithKit | tail` as a green signal.
  - **Verify**: `swift test --package-path SimmerSmithKit` exits 0 with the PrivatePlaneStore tests either passing (entitled host) or explicitly skipped — no `signal code 5`.
  - **tier_floor**: senior · **complexity**: M

## Constraints (updated 2026-07-09)

- AI is the primary interaction model
- Do not silently persist AI-generated content
- Apple-only stack: CloudKit data plane; BYO-key AI; no central server (Fly retiring under SP-D).
  The post-launch credits gateway is a **stateless metering proxy**, not a return to a backend —
  it holds no user content and no household data.
- CloudKit schema is additive-only — recordName policy + field tables are irreversible
- Household = owner + one partner via zone-wide CKShare (MCP dropped; no forced payment).
  The household is NOT the Apple family group — Pro products ship Family-Sharing-off.
- iOS 26.0 deployment floor (intentional — FoundationModels; user-confirmed 2026-07-01)
- **Keyless users are a first-class path, not a degraded one.** Every feature must answer "what
  does a user with no API key see?" — it is also App Review's path. Until the gateway or iOS-27
  AFM lands, that answer is "manual + on-device," and a feature that dead-ends there is a bug.
