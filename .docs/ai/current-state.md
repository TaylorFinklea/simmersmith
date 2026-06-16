# Current State

> Updated at the end of every work session. Read this first.

## Active Branch

`main`

## Plan — CloudKit migration de-risking spikes (set 2026-06-15)

Direction: Apple-native / offline-first rearchitecture. Spec
`phases/cloudkit-migration-spikes-spec.md`; decisions in `decisions.md` (2026-06-15).
Spike-first before SP-A (CloudKit data plane) / SP-B (AI tiering).

- [x] **Spike 1 — CloudKit grocery-merge (algorithmic verdict).** DONE 2026-06-15
  via deterministic simulation `spikes/spike1-cloudkit-grocery-merge/` (`swift test`
  8/8). **Verdict: GO — grocery stays client-side ONLY on `CKSyncEngine` + custom
  field-merge resolver; `NSPersistentCloudKitContainer` blanket LWW is UNSAFE**
  (resurrects tombstones, drops event_quantity, clobbers overrides; check-state is
  fine under LWW). → SP-A runs grocery + event↔week on CKSyncEngine; plain data on
  NSPersistentCloudKitContainer. Report: `phases/cloudkit-migration-spikes-report.md`.
  - [?] **Real two-device CloudKit confirmation** — deferred to SP-A (needs a
    provisioned CloudKit container under the dev team). The sim de-risks the
    algorithm; the device test de-risks the integration.
- [x] **Spike 2 — harness built + verified (2026-06-15).** `spikes/spike2-weekgen-quality/`:
  8-context corpus + rubric scorer (allergy=hard-fail, macros ±15%, variety, reuse-cap
  ≤3, dedup, latency) + production-shape ingest + 13 unit tests (`python3 -m unittest
  test_rubric` → 13/13). Backends stubbed.
  - [?] **Run deferred to iOS 27 GA.** Wire the 4 backend stubs (gpt-5.5, Claude,
    AFM 3 on-device, PCC) lifting the real `week_planner._build_system_prompt`, run
    `runner.py`, paste the table. Hard gate: any allergy violation fails that tier.
- Report lands at `phases/cloudkit-migration-spikes-report.md`.

**In progress (chosen 2026-06-15): do the no-beta work FIRST.** This machine is
Xcode 26.0.1 / iOS 26 = first-gen Foundation Models (~3B, on-device-only, no
third-party PCC). Proceeding now with everything runnable on iOS 26: Spike 1
(CloudKit merge — `CKSyncEngine` is iOS 17+, plus a deterministic LWW-semantics
simulation as the fast first signal) and Spike 2's cloud baselines (gpt-5.5 +
Claude) + a conservative first-gen-3B on-device floor. **Deferred to Xcode 27
beta — wait for **iOS 27 GA (fall 2026)**, not the beta: only the AFM 3 (20B) +
third-party-PCC measurement** that the iOS-26 SDK can't run. Everything else
proceeds now.

Other notes: Spike 1 also needs a CloudKit container provisioned under the dev team
(app currently has NO CloudKit entitlement — only applesignin + APNs); a standalone
spike app with its own container is cleanest. Spike 2 cloud baselines need live
OpenAI + Anthropic keys. Spike 1 device setup is a build-time call (two iCloud
accounts ideal, else two containers, document fidelity). Throwaway — deleted after
the report. OpenRouter→FOSS provider lane deferred.

## Plan — SP-A CloudKit data plane (spec written 2026-06-15)

In-place migration to CloudKit/iOS-26 now; AFM3/PCC at GA. Spec
`phases/cloudkit-sp-a-spec.md` (11-agent blueprint, adversarially reviewed, fixes in
§11). **BLOCKING GATE: a CloudKit container provisioned under the dev team** (Phase
0.5 + Phase 2 also need Production schema + two Apple IDs + TestFlight). Phases (each
shippable + Verify):
- [x] **0 — schema + recordName policy + provisioner: DONE + VALIDATED 2026-06-15.**
  Container `iCloud.app.simmersmith.cloud` live. Schema deployed to dev (HouseholdProfile
  + 8 Phase-1 types, confirmed via `cktool export-schema`). **Record CRUD validated
  headlessly** (created + deleted a real HouseholdProfile via the saved USER token).
  Artifacts: `phases/cloudkit-sp-a-phase0-schema.md` (irreversible recordName/index/ref
  decisions), `phases/phase0-schema.ckdb` (cumulative CKDSL), `SimmerSmithCloudKit/
  CloudKitProvisioning` (RecordNames 4 tests + HouseholdZoneProvisioner). cktool works
  here (management+user tokens). Custom-zone round-trip + coexistence run in-app (below).
  Don't promote schema to Production until decisions are final.
- [x] 0.5 — coexistence spike. **DONE + VERDICT LIVE 2026-06-15.** Harness
  `SimmerSmithCloudKit/CoexistenceSpike` (NSPCKC private mirror + manual CloudKit
  zone/record/subscription — the CKSyncEngine primitives — in one container), run via the
  in-app **CloudKit checks** DEBUG panel on the iPad sim signed into Taylor's iCloud.
  **Both ✅** — NSPCKC store loaded + note written (count=1) AND manual CloudKit zone+record
  round-trip + subscription succeeded in the same container, no token/zone/notification
  clash. **VERDICT: Phase 1 uses NSPersistentCloudKitContainer** (NSPCKC + a custom
  CKSyncEngine-style stack coexist → don't need CKSyncEngine-everywhere). Same panel's
  Phase 0 custom-zone round-trip also returned ✅ `round-trip name = Phase 0 Test`. ⚠️ Build
  SIGNED for sim CloudKit (NOT `CODE_SIGNING_ALLOWED=NO` — strips entitlements → hard-crash;
  see decisions). CKShare cross-account half (2nd account = savanne's iCloud, on the iPhone 16
  sim) is separate + manual at Phase 2 — can't automate iCloud sign-in / share-accept.
- [~] 1 — per-user PRIVATE plane. **Schema DONE + validated headlessly** (8 types
  live in dev: ProfileSetting/DietaryGoal/PreferenceSignal/IngredientPreference/
  AssistantThread/AssistantMessage/MigrationReceipt). **MECHANISM DECIDED (Phase 0.5):
  NSPersistentCloudKitContainer** — auto-manages CD_-prefixed schema + LWW for the bulk
  per-user types; the hand-authored types/recordName policy/resolver are reserved for the
  grocery-merge types (Phase 4) on a custom stack, which 0.5 proved can coexist. Next: wire
  NSPCKC into the app target. cktool schema ops work headlessly (management token); record
  ops need a user token.
- [ ] 2 — household zone + CKShare + plain CRUD (+ audit prune).
- [ ] 3 — CKAsset imagery.
- [ ] 4 — field-merge resolver + sticky grocery (ports grocery.py verbatim; real 2-device test). HIGHEST RISK.
- [ ] 5 — event↔week cross-aggregate merge.
- [ ] 6 — PUBLIC catalog read (coupled to SP-E curator infra).
- [ ] 7 — migration import + cutover (MigrationReceipt sentinel).
- [ ] 8 — AI seam + on-device platform handoff.
- [ ] 9 — migration cutover close (status ledger; gates SP-D).

Residual decisions (§11): ownership-transfer (pin-to-owner rec.) · dormant-user
sunset · SP-E curator soon vs frozen PUBLIC seed.

**Pre-built ahead of provisioning (DONE 2026-06-15):** `SimmerSmithCloudKit/` SwiftPM
package — **GroceryMerge** (Phase 4 core: `FieldMergeResolver` + `ConflictRepair`,
generalizes Spike 1; incl. the M68 semantic-dedupe + EventGroceryItem repoint) and
**AIProviderKit** (Phase 8 core: `ProviderRouter` + `KeyStore` + `AIClient`, real
backends stubbed for SP-B). `swift test` → **25/25**. CloudKit-free, not yet wired
into the app target. Remaining SP-A work is the container-gated Phases 0-9 (the
CKSyncEngine/CKShare/NSPCKC adapters + real-device tests).

## Last session (2026-06-13) — ultracode bug bash + T1 household-scoping cluster fixed

Ran a 149-agent ultracode workflow (23 bug-finders + 11 architecture agents,
every finding adversarially verified): **55 confirmed bugs** (19 high / 16 med /
20 low) + **62 architecture findings**, 10 refuted. Full report:
`.docs/ai/phases/bugbash-2026-06-13-report.md` (committed `cdc6bd9`).

Then fixed the **T1 cluster** — the unfinished M21 household pivot (`user_id`
used where `household_id` belongs). One commit `694ea92`:
- **migration 0047** — weeks/staples UNIQUE re-keyed to `household_id`. Postgres
  drops+recreates the named constraint; SQLite adds a unique **index** (Alembic
  batch can't reflect the inline constraint name — no naming_convention). Python-
  side dedup first. Up/down/up round-trips clean.
- **create_or_get_week** — savepoint + IntegrityError recovery so two members
  planning the same week converge instead of 500ing (#23).
- **update_profile** scoped to the caller; won't wipe a housemate's staples,
  skips names a housemate owns (#14). **pantry rename** household dedup (#49).
- **feedback rebuild** joins Week → scoped to household (#16). **MCP
  assistant_respond** resolves household_id for get_recipe (#21). **push
  scheduler** week lookups household-scoped (#24). **week_planner** passes
  household_id to staple_names/list_weeks (#34/#35).
- 11 new tests (`tests/test_t1_household_scoping.py`); **full suite 511 passed**,
  ruff clean.

**Live AI regression (real OpenAI key, local uvicorn):** week-plan generation
produced a valid 21-meal plan in 118s; `gather_planning_context` now feeds pantry
staples into the prompt (was empty pre-fix). ✅ AI works, T1 change verified live.
⚠️ **Surfaced (pre-existing, not T1): `ai_timeout_seconds=120` is too tight for
gpt-5.5 week-gen** — 118s direct, so the HTTP route exceeds 120s and returns a
**bare 500** (a non-RuntimeError httpx.ReadTimeout escapes `except RuntimeError`;
arch finding T7). **→ Fixed same session in T7 (below).**

### T7 — observability + error-handling cluster fixed — `d772f9e`

Closed the arch-T7 gap that *swallowed* today's 500:
- **`configure_logging()`** (dictConfig, root INFO→stdout) so app `logger.info/
  debug` reach `flyctl logs` (were dropped at default WARNING). New
  `SIMMERSMITH_LOG_LEVEL`. The intentional `_RequestLogMiddleware` print() stays.
- **Global handlers** (`main.py`): unhandled Exception → logged (method+path+
  traceback) + generic 500 (no leak); `OperationalError` → 503 + Retry-After.
  Deep `/api/health/ready` (SELECT 1).
- **`AIProviderError(RuntimeError)`** — `_call_ai_provider` wraps httpx timeout/
  HTTP/parse failures (raw logged, clean message); generate route maps it → 503
  before RuntimeError→422. Bumped `ai_timeout_seconds` 120→300.
- 7 new tests (`tests/test_t7_error_handling.py`); **suite 518 passed**, ruff clean.
- **Live-verified**: a forced 1s timeout → `generate` returns **503** with a clean
  body AND logs `week-plan AI call failed (openai/gpt-5.5): The read operation
  timed out` (was a bare 500 + swallowed traceback). Readiness probe returns ready.

### T6 — crashes / dead features fixed — `f770815`

Four crash/dead-feature bugs:
- **#18** rebalance-day endpoint deleted via `WeekMealIngredient.meal_id` (FK is
  `week_meal_id`) → AttributeError → 500, feature dead. Fixed the column.
  **Live-verified**: added 2 meals to a day, rebalanced → **200** with a real AI
  day (deleted the old meals via the fixed column, no crash).
- **#3** cancelled turn persisted `status='cancelled'`, not in
  `AssistantMessageOut.status` Literal → GET thread 500'd. Added `'cancelled'` to
  the Literal (iOS `AIAssistantSheetView:331` already renders it; DB col is free
  String).
- **#33** recipe-import `parse_quantity_text` built `Fraction("1/0")` →
  ZeroDivisionError → 500. Guard ZeroDivisionError/ValueError → token stays name.
- **#1** kid-friendly preset `VariationRule(("onion"), …)` was a string not a
  1-tuple → every `rule.terms` walk iterated chars o/n/i/o/n and re.sub-corrupted
  every step/ingredient. Added the trailing comma.
- 5 new tests (`tests/test_t6_crashes.py`); **suite 523 passed**, ruff clean.

### T4 — event↔week grocery merge lifecycle fixed — `9446002`

Five interconnected merge-lifecycle bugs (the buggiest subsystem):
- **#9** deleting a merged event left stale event_quantity + zombie event-only
  rows on the week → `delete_event` unmerges from `linked_week` first.
- **#10** re-dating an auto-merged event never moved its grocery (
  `_resolve_target_week` short-circuited on `linked_week_id`) → `apply_auto_merge_policy`
  unmerges from the stale week when `event_date` moves off it, then re-resolves.
- **#11** editing a manually-merged potluck (`auto_merge_grocery=False`) silently
  dropped the merge → new **`events.manually_merged`** flag (migration 0048) pins
  a user merge; policy keeps it + never auto-unmerges; `regenerate` uses
  `keep_link=True` so the pinned week survives a rebuild.
- **#37** renaming after merge stranded event-only rows (unmerge matched the
  mutable `event:{name}` marker) → detection is now name-agnostic (`event:`
  prefix); the displayed marker stays the name.
- **#38** AI menu regen collided `sort_order` with preserved manual meals →
  offset the supplied 0-based order by `start_index`.
- 6 new tests (`tests/test_t4_event_grocery.py`); **suite 528 passed**, ruff clean.
  Live-verified the event create/patch/merge/delete routes + migration up/down/up.

### Backend backlog sweep — 19 findings via 11-lane workflow — `2c84c05`, `478f9b8`, `bd4a9fb`

Cleared the **remaining backend bug-bash findings** (T3 IDOR + backend mediums/lows
+ T7 follow-ups) with an 11-lane file-disjoint workflow (implement → adversarial
review), then integrated. Report still `.docs/ai/phases/bugbash-2026-06-13-report.md`.
- **Security (`2c84c05`):** subscription /verify IDOR (409 on cross-user receipt),
  webhook last_transaction_id guard (no Pro-after-refund), preference/feedback IDOR
  ownership checks, recipe-image content-type allow-list + nosniff, SSRF CGNAT,
  web-SSO IntegrityError recovery, vision_ai provider wrapping.
- **Correctness (`478f9b8`):** catalog merge-all-preferences + archived-variation
  guard, /resolve commit, split_summary sentence-split, apply_ai_draft WeekMealSide
  delete, recipe-save image savepoint, pantry week_start cadence, import_pricing
  up-front validation, rebalance AI-before-delete (data-loss), score_macro_drift
  resolves recipe ingredients, APNs 410 by status code.
- **Assistant/T7 (`bd4a9fb`):** page_context.week_id ownership validation; streaming
  + non-streaming provider errors wrapped (no bare 500); SSE + persisted
  AssistantMessage.error sanitized (thread-detail URL-leak closed).
- **Adversarial review caught 5 real bugs** before commit (split-summary inline
  markers, pantry pre-existing-test break, SSO over-sanitization, planner test
  monkeypatch target, assistant stored-error leak) — all fixed in integration.
- **92 new tests** (11 `tests/test_batch_*.py` + 2 updated); **full suite 592 passed**,
  ruff clean. **Live AI verified:** week-gen 200 + 21 meals + macro-drift note now
  populates; assistant streaming turn completed with content.

### iOS bug-bash findings (16) fixed + build 107 — `9b50280`

All 16 iOS findings (the `ios-*` slices) implemented, **xcodebuild BUILD SUCCEEDED**
(iPhone 16 sim), and **sim-verified live**: app launches + connects to a local
backend; **MealIcon #2/#3 confirmed in a screenshot** (Grilled Steak → meat icon
not coffee, Eggplant Parmesan → generic not egg, Iced Tea → coffee, Scrambled Eggs
→ egg); `/terms` route returns 200.
- HIGH: #13 FAB targets an open slot + in-place replace (no overwrite data loss),
  #12 aliases preserve input + surface error, #16 reminders mapping saved in a
  defer (no duplicate reminders).
- MED: #14 UTC weekday name, #6 events delete error surfaced, #7 paywall Terms →
  new `/terms` EULA page (app/main.py) + Privacy link, #8 stale-JWS cleared, #10
  draft step off-by-one, #15 push token persisted after registration.
- LOW: #1 guest re-sort, #4 CookCheck clamped index, #5 comma-decimal qty, #9
  revoked transaction drops entitlement, #11 bulk-delete by recipeId.
- `project.yml` 106→107. ⚠️ The `.xcodeproj/project.pbxproj` is NOT regenerated —
  `scripts/release-ios.sh` / xcodegen regenerates it at TestFlight time (the sim
  build I verified used 106; the bump applies on the next archive).

**Remaining from the bug bash (NOT done):**
- **2 shopping-skill findings** — already re-swept in a prior session (commit
  `98376b9`); the bash's 2 were against pre-sweep code. Re-confirm if revisiting.
- **T5 freemium-not-enforced** — has product decisions (entitlement unit, assistant
  gating); monetization-adjacent, deferred.
- **Architecture STRUCTURAL findings** (FKs on household_id, metadata naming_convention,
  RLS/defense-in-depth, pagination, AI truncation detection, JSON-extractor unification)
  — design-heavy, not line-bug fixes; tackle as focused efforts.

## Last session (2026-06-02 pm) — SHIPPED: deploy + TestFlight + cleanup

Pushed the whole bug sweep (39 commits) to `origin/main`, then shipped it.

- **Backend deployed to Fly** (`fly deploy`, app version 115). Migrations 0043–0046 applied. **Smoke-tested prod**: health 200, **MCP connector serving** (POST /mcp → 401 OAuth gate, NOT 500 — F11 stateless transport works in prod), RFC 8414/9728 metadata 200, dropped Kroger routes (`/stores/search`, `/products/lookup-upc`) 404. ⚠️ **One thing still on you: reconnect the Claude.ai MCP connector once** to confirm the full OAuth round-trip (server-side is confirmed healthy).
- **iOS Kroger dead-code cleanup** `369d2e9` — deleted StoreSelectionView, BarcodeScannerView, GroceryView fetch-prices code, AppState.lookupProductByUPC, dead Kit methods/models, and stale Kroger UI. Kept the generic price display. `swift build` + `xcodebuild` clean.
- **iOS build 106 → TestFlight** `bsuual4o7` — archived + uploaded ("Upload succeeded"). project.yml bumped 105→106 (`369d2e9`).
- **Re-swept `skills/simmersmith-shopping/`** `98376b9` — fixed 5 bugs (splitter dropping items, osascript comma desync, PyXA list-not-found masked, parser ZeroDivisionError, store-driver unencoded URLs). 13 tests pass (was 8).

Commits this session: `369d2e9`, `98376b9` + docs (the 39 sweep commits `08dcdb6..67af999` were pushed at the start).

**Deferred (still open):** M5 monetization activation (App Store Connect product config + flip `trial_mode_enabled` off — F22 IAP now hardened, but still set `SIMMERSMITH_APPLE_IAP_APP_APPLE_ID` + iOS `appAccountToken` first). Not done per your call.

## Earlier 2026-06-02 — cleared the 7 deferred sweep findings + e2e

Burned through the 7 previously-deferred findings (product decisions taken via
AskUserQuestion), then verified end-to-end. Commits `c7f9178..54f0fc7`.

**Done + verified:**
- **M62** `c7f9178` — ingredient-list COUNT N+1 → one GROUP BY per source (`ingredient_counts_bulk`).
- **M66** `c7f9178` — SSO OIDC nonce: minted in state JWT, sent in authorize URL, required in id_token echo (legacy state degrades, doesn't break).
- **M8/M63/M64** `725baf0` — **product decision: AI/MCP-resolved ingredients are now household-private** (`household_only`), not global `approved`; existing approved rows still reused. Draft/import previews resolve `persist=False` (no throwaway rows). Nutrition estimate nulls cross-household private refs. New `tests/test_catalog_scoping.py`.
- **M37** `54eb4b1` (backend) + `54f0fc7` (iOS) — **product decision: drop Kroger.** Deleted `kroger.py`, `stores.py`, `products.py`, `fetch_kroger_pricing` + `/pricing/fetch`, the assistant `fetch_pricing` tool, config keys, Kroger tests. Kept generic manual-pricing (import route, RetailerPrice/PricingRun, MCP pricing tools) + `ACTION_PRICING_FETCH` (now unincremented, avoids profile/test churn). iOS: removed the Settings "Preferred Store" link + GroceryView "Fetch Kroger prices" row (rest self-hides since `kroger_location_id` is now unsettable).
- **M40** `54f0fc7` (iOS) — plan-shopping threads the displayed week through PlanShoppingSheet → `quickAddPlanItem` with slot routing (`insertGroceryItemInWeek`).

**E2E (2026-06-02) — done by agent, comprehensive:**
- iOS **BUILD SUCCEEDED** (Xcode 26, sim) — all iOS changes compile.
- Backend suite 500/1-skip.
- **Real-AI regression** (local uvicorn + real OPENAI key): ran 3 live assistant turns — tool loop executed (`add_meal`) and meals **persisted** to weeks; recipe AI suggestion-draft works. Confirms the `fetch_pricing`-tool removal + catalog/drafts changes didn't break AI.
- **Catalog scoping via real API**: saving a recipe minted a **`household_only`** row for a novel ingredient and **reused the global `approved`** row for "chicken breast" — exactly the M63 decision, no fragmentation.
- **M40 verified LIVE in the simulator** (idb-driven UI + backend request inspection): browsing a non-current week and tapping "plan" issued `GET /weeks/<next-week-id>/grocery/plan-shopping` (not the current week's id) — the exact cross-week bug, fixed. Plan-shopping on the current week hit the current week's id. ✅
- **M37 in-app**: Grocery tab has no "Fetch Kroger prices" row; removed `/stores/search`, `/products/lookup-upc`, `/pricing/fetch` all 404; manual `/pricing/import` kept.
- Sim-driving notes: the app defaults `serverURLDraft` to production and `idb` text-entry into SwiftUI fields is unreliable + `cfprefsd` caches direct plist writes — the reliable local-backend override is `xcrun simctl spawn <udid> defaults write app.simmersmith.ios simmersmith.serverURL http://localhost:8080` + an open-mode backend (no token) + an ATS arbitrary-loads patch on the built `.app` (build-artifact only; NOT in source). Worth an XCUITest harness for repeatable iOS UI e2e.

**iOS Kroger dead-code cleanup (follow-up, needs-build):** the entry points are gone but `StoreSelectionView`, `GroceryView.fetchPricesRow`, the barcode-scanner UPC lookup, and the dead `searchStores`/`fetchPricing`/`lookupProductByUPC` API methods + Store models remain unreachable-but-present. Delete in a dedicated build-capable pass. (Supersedes the earlier-committed M48 searchStores percent-encode — that function is now dead.)

## Earlier session (2026-05-30 pm) — medium/low sweep findings (Batches A–H)

Implemented the ~71 medium/low findings from the 2026-05-30 sweep, grouped
into 8 themed commits `0e34ab3..d7ae052`. Verify-before-implement throughout
(re-scoped each finding against current code; debunked false positives).
Backend: full suite **510 passed, 1 skipped**, ruff clean. SimmerSmithKit:
`swift build` clean. App-target iOS changes flagged **needs-build** (no Xcode here).

- **A** `0e34ab3` auth/admin: compare_digest bytes, JWT alg pin, /me, settings validation (M1,M2,M3,M13,M17,M18,M32)
- **B** `2c1986d` auth/iap: email_verified gate, webhook freshness window, sandbox gate (M16,M25,M28,M58,M67)
- **C** `c0ca607` data-integrity: FK width, value bounds, model/migration drift, recipe unlink (M52,M53,M54,M33)
- **D** `dd45553` data-integrity logic: transcript, pantry, dedupe, scoping (M9,M31,M34,M35,M50,M56,M68,M70,M71)
- **E** `649cf2a` error-handling/validation: provider 502, body caps, error sanitizing, admin encoding (M4,M5,M6,M36,M39,M51,M61)
- **F** `7fb78a8` robustness: SSE disconnect-abort, task-ref leak, startup dedup, scheduler session-per-user, config (M7,M10,M11,M12,M19,M20,M21,M22,M24,M38)
- **G** `d1e0e6a` concurrency: first-sign-in 500 + dup-household recovery (M15, migration 0046 `uq_household_members_user`), atomic usage upsert (M27), invitation `with_for_update` (M30)
- **H** `d7ae052` iOS: Keychain atomic write + status logging (M44/M45), reminder UTC→local day fix (M47), zip percent-encode (M48), silent build-88 migration + syncPhase bypass (M42/M43), removed shipped assistant TODO (M41)

**Deferred (with notes — need dedicated focused passes, NOT tail-of-session):**
- **M8** (low) nutrition-catalog reference-value leak — broad household_id threading; mirror `_require_visible_base_ingredient`.
- **M63** (med) `resolve_ingredient` provisional-row pollution — REAL committing path is the MCP `ingredients_resolve` tool (REST doesn't commit); keep household_id optional to preserve 5 internal callers.
- **M62** (med) ingredient-list COUNT N+1 (`search.py:191`, `ingredients.py:183`) — must preserve exact count field names/values.
- **M37** (med) Kroger per-item blocking pricing — item-cap + per-call + wall-clock budget (config-tunable); not live (no Kroger creds).
- **M64** (low) draft-preview routes persist provisional catalog rows — scope fix to preview routes only; real-save persistence is intentional.
- **M66** (low) SSO missing `nonce` — OIDC defense-in-depth; `verify_state` return-shape change ripples to `oauth.py:532` + `test_sso.py`. Send-nonce must land before require-nonce or Apple breaks.
- **M40** (low, iOS) PlanShoppingSheet reads `currentWeek` while browsing a non-current week → cross-week quick-add. Correct fix threads `weekID` through WeekView/GroceryView/PlanShoppingSheet/quickAddPlanItem with slot-routing + changes the sheet's added-item tracking; needs build+test.

**False positives confirmed (no change):** M13 session-JWT alg (PyJWT pins it), M26 entitlements bypass, M58/M67 "account takeover" half (matches on `sub`, not email).

**iOS needs-build gate:** Batch H app-target files (NotificationManager, AppState+Grocery/+Assistant) compile-checked only by inspection. Build + smoke-test before TestFlight. `project.pbxproj` still carries the pre-existing 104→105 regen (unstaged, not mine).

**Carried pre-deploy gates (unchanged):** (1) smoke-test Claude.ai MCP connector (F11 stateless); (2) set `SIMMERSMITH_APPLE_IAP_APP_APPLE_ID` + iOS must set `appAccountToken` at purchase before flipping trial-mode off (F23/F24).

## Earlier 2026-05-30 — multi-agent bug sweep + critical/high fixes

Full-codebase bug sweep (20 parallel reviewers → 101 findings →
adversarial verification). Report: `.docs/ai/phases/bug-sweep-2026-05-30-report.md`.

**Fixed + committed this session (14 findings, 6 commits `21072f4..5e31ef7`, 462 tests green):**
- F6 household `claim_invitation` multi-member data loss (CRIT-class data loss)
- F4/F5/F7 event-grocery staples scoping + double-count + `event_date` wipe
- F8 admin `workers_dev = false` (Access bypass)
- F1/F2/F3/F21 OAuth consent-page XSS + open-redirect + state injection
- F12/F15/F18 export + recipe cross-household IDOR
- F13/F14 MCP ingredient tools always-erroring; F25 recipes household scoping; F19 Anthropic max_tokens truncation

**Follow-up batch — ALSO fixed + committed (user-approved):**
- **F22 (CRIT)** IAP forgery → official `app-store-server-library` chain validation vs bundled Apple Root CA-G3 (`2c17b0f`). Added `SIMMERSMITH_APPLE_IAP_APP_APPLE_ID` (set before Production). Forged-receipt test.
- **F11 (CRIT)** MCP identity → `stateless_http=True` (`6d9336e`). **⚠️ smoke-test the Claude.ai connector before deploy** (couldn't test from sandbox; one-line revert if it regresses).
- F9 SSE asyncio.Queue (`dfa29bd`); F10 tool-runner rollback (`5c9ecfe`); F28 SSRF DNS/redirect (`e71195b`); F26/F27 ingredient cross-household IDOR (`561a752`, global catalog stays collaborative by design); 6 more MCP `current_user` tool bugs incl. `recipes_list` (`ce5d449`).

**Backlog burn-down (2026-05-30, second pass) — ALL remaining bug-sweep backlog cleared:**
- **F23/F24** IAP replay/dedup → `0879339` (notificationUUID dedup table, signedDate freshness, monotonic last_transaction_id, terminal-status period freeze, forward-compatible appAccountToken). Follow-up: iOS must set `appAccountToken` at purchase to fully activate the rebind check.
- **F20** household_id NOT NULL → `cf421cc` (migration 0043).
- **F16/F17/F29** iOS → `df67196` (⚠️ needs iOS build smoke-test).
- Medium security: jwt_secret strength warning + SSO state aud/iss → `21b191e`; ingredient-detail/variations IDOR read → `6a52c1c`.
- Closed as NOT-real (verified): session-JWT alg pinning (PyJWT pins it), whitespace-token free-tier bypass (open-mode == open-auth).

**Two pre-deploy gates remain:** (1) smoke-test the Claude.ai MCP connector (F11 stateless transport); (2) set `SIMMERSMITH_APPLE_IAP_APP_APPLE_ID` before Production IAP / flipping trial mode off. Plus the iOS smoke-test above. ~35 medium / ~37 low findings from the original sweep remain catalogued in the report (races, perf, etc.) for future passes.

Fix commits this session: `git log 21072f4^..df67196` (bug sweep + full backlog).

**Still uncommitted (pre-existing, not from this session):**
`SimmerSmith.xcodeproj/project.pbxproj` (104→105 xcodegen regen, pairs with 08dcdb6 `project.yml` bump). Plus scratch workflow files `.docs/ai/_*.js` (safe to delete).

## Shipped (2026-05-22 → 2026-05-23, build 104 — superseded by 105)

iOS build 104 archived + uploaded to TestFlight via
`scripts/release-ios.sh`. Fixes the iOS half of Bug 2 (AI Assistant
"added X" but day renders empty). Three changes:

- **`browsedWeek` hoisted from `WeekView.@State` to `AppState`.**
  The assistant SSE `case "week.updated"` handler used to do
  `currentWeek = updated.week` unconditionally — corrupting "this
  week" whenever the assistant mutated a non-current week (e.g.
  planning "next week" from the week-picker browsed view) and
  leaving `browsedWeek` (the actually-displayed snapshot) stale.
  New helper `applyAssistantWeekUpdate(_:)` routes by `weekId` to
  whichever slot matches; drops payloads for weeks neither slot
  is tracking (the next fetch picks them up server-side).
- **Pull-to-refresh refetches the displayed week.** `.refreshable`
  and the FAB `.refresh` action now `fetchWeekByStart(displayedWeekStart)`
  when browsing a non-current week instead of always hitting
  `/api/weeks/current`. The user-reported repro (refresh on next
  week → no meals visible despite AI committing them) is gone.
- **Swallow benign cancellation errors.** `AppState.isExpectedCancellation(_:)`
  detects `CancellationError` + `URLError.cancelled`; `refreshWeek`
  and `refreshAssistantThreads` skip them instead of writing
  `lastErrorMessage = "cancelled"`. Removes the "cancelled" red
  banner that appeared on the Week tab after sheet dismissal.

Files: `SimmerSmith/SimmerSmith/App/AppState.swift`,
`AppState+Assistant.swift`, `AppState+Weeks.swift`,
`Features/Week/WeekView.swift`, `SimmerSmith/project.yml`
(`CURRENT_PROJECT_VERSION: 93 → 104`), and the regenerated
`.xcodeproj/project.pbxproj`. xcodebuild Debug build clean. TestFlight
upload succeeded.

## In-flight (2026-05-22, server build 103 — deployed)

Diagnosed two user-reported bugs from iOS build 93 / production v108
(Fly app `simmersmith`):

- **Bug 1 — swap meals → HTTP 500 on `PUT /api/weeks/{id}/meals`.**
  Root cause: Postgres checks `uq_week_day_slot(week_id, day_name,
  slot)` per-statement, so the two-row "exchange day_name+slot"
  payload from the iOS drag-to-swap UI trips a transient duplicate
  on the first UPDATE that `update_week_meals` issues. The handler
  raises `IntegrityError` before any response starts; Uvicorn sends
  500. **Fix landed locally, not deployed yet** — Taylor still
  needs to commit + `flyctl deploy`:
  - `alembic/versions/20260522_0042_defer_week_meal_slot_unique.py`
    (new) — drop + re-add `uq_week_day_slot` with `DEFERRABLE
    INITIALLY DEFERRED`. Postgres only; SQLite no-ops the clause.
  - `app/models/week.py` — mirror the deferred flags on the
    `UniqueConstraint` so SQLAlchemy metadata matches.
  - `tests/test_week_meal_swap.py` (new) — one model-declaration
    unit test (passes everywhere) and one end-to-end swap PUT test
    (skipped on SQLite, the test DB; only meaningful on Postgres).
  - Full suite: **450 passed, 1 skipped, 0 failures** in 2m58s.

- **Bug 2 — AI Assistant "Added X" but day renders empty (Mon,
  then Tue repro).** **Backend confirmed correct; this is an iOS
  refresh bug, no backend change needed.**
  - Monday turn (thread `2eba493c-…`, `2026-05-22 21:15`): 3
    add_meal calls committed cleanly to Week
    `a93444c7-…` (`week_start=2026-05-25`) with the right
    `day_name=Monday`, `meal_date=2026-05-25`, and slots.
  - Tuesday turn (thread `743cea90-…`, `2026-05-23 00:50`): 3
    add_meal calls also `status=completed, ok=True`, also
    committed to the same Week row (now 6 meals). The iOS UI
    showed a red **"cancelled"** banner anyway and rendered
    Tuesday empty even after pull-to-refresh.
  - Log forensics for the post-cancel refresh: iOS hit
    `GET /api/weeks`, `GET /api/weeks/current`, `POST /api/weeks`
    (get-or-create), `GET /api/weeks/b3bd4ae0-…/exports` — but
    **never `GET /api/weeks/a93444c7-…`** (the May-25 week being
    displayed). The iOS pull-to-refresh path doesn't refetch the
    currently-displayed week's full payload, which is why even an
    explicit refresh leaves the new meals invisible.
  - Battery in the cancelled screenshot was 18%; iOS likely
    aggressively suspended the SSE stream, and the client labelled
    the turn cancelled despite the server completing normally.
  - **iOS-side follow-up backlog** (no server work):
    1. Pull-to-refresh on a week view must `GET /api/weeks/{id}`
       for the *displayed* week id, not just `/api/weeks/current`.
    2. Treat "cancelled" as UI hint; do NOT discard
       `assistant.tool_result` patches that already arrived
       in-band with `ok=True`.
    3. On Assistant-sheet dismiss, force a `GET /api/weeks/{id}`
       refresh of the surrounding week view.
  - **Optional backend robustness (deferred):** emit a final
    `assistant.turn.completed` event carrying
    `{week_ids_modified: [...]}` so iOS can cheaply refetch the
    right weeks on any SSE drop. Not required for the fix.

Uncommitted at session end (`app/main.py`, `app/mcp/__init__.py`
from the earlier MCP-mount work plus the four Bug-1 files above).

## Deployment Status (as of 2026-05-19)

All six commits below are pushed to `origin/main` AND deployed to
Fly via `flyctl deploy --remote-only -a simmersmith`. Production
smoke checks pass (metadata endpoint serves RFC 8414, OAuth gate
returns 401 on `/mcp/` without bearer, new household + SSO routes
respond with the expected 401/404 shapes).

```
96fb0cf  feat(image-gen):  build 101 — OpenAI 5xx/429/network → Gemini failover
ac09141  docs(roadmap):    record builds 98-100 + correct stale M7 Phase 5 entry
b7aa239  feat(household):  build 100 — M21 follow-ups (owner transfer + member removal)
2069139  feat(recipe-search): build 99 — Anthropic web search provider parity
9c40832  feat(oauth):      build 98 — M24.1 Apple/Google web SSO on /oauth/authorize
7145da4  feat(shopping):   M23.1 framework — capture subcommand + driver scaffolds
2d932e2  feat(mcp):        build 97 — M24 Remote OAuth MCP server (deployed 2026-05-15)
1964ed5  fix(ai):          build 96 — strip temperature/max_tokens for gpt-5.5+ chat (deployed 2026-05-15)
```

448 / 448 pytest pass; ruff clean. Test suite ran twice to confirm
post-build-101.

### What's auto-active (no further action)

- **Build 96** — gpt-5.5 chat completions fixed; AI Assistant /
  vision / week-gen all back to working.
- **Build 97** — Remote MCP at `simmersmith.fly.dev/mcp` accepts
  OAuth-authorized clients (Taylor verified via Claude.ai).
- **Build 99** — Anthropic web search available to any user; flip
  on per-user via `profile_settings.recipe_search_provider="anthropic"`
  or admin-wide via `SIMMERSMITH_AI_RECIPE_SEARCH_PROVIDER=anthropic`
  Fly secret. Default remains `"openai"`.
- **Build 100** — `POST /api/household/transfer-owner` and
  `DELETE /api/household/members/{user_id}` live. iOS surface to
  expose them in Settings → Household is a separate client task.
- **Build 101** — Image-gen failover engages automatically for any
  user whose server has BOTH `ai_openai_api_key` and
  `ai_gemini_api_key` configured. No client work required; ops can
  grep for `OpenAI image gen failed transiently` to find failovers
  in production logs.

### What's live-but-awaiting-user action

- **Build 98 SSO buttons** — `/oauth/authorize` HTML renders Apple
  + Google buttons only when the corresponding env vars are set.
  Currently rendering bearer-paste fallback only. Activation
  requires:
  1. Apple Developer Portal: register a Service ID, enable Sign in
     with Apple on it, set return URL
     `https://simmersmith.fly.dev/oauth/sso/apple/callback`,
     generate `.p8` key with Sign in with Apple capability, note
     Team ID + Key ID + Service ID.
  2. Google Cloud Console: create OAuth 2.0 Web Client (NOT iOS),
     authorized redirect URI
     `https://simmersmith.fly.dev/oauth/sso/google/callback`, note
     client_id + client_secret.
  3. `flyctl secrets set` six vars:
     `SIMMERSMITH_APPLE_WEB_SERVICE_ID`, `SIMMERSMITH_APPLE_WEB_TEAM_ID`,
     `SIMMERSMITH_APPLE_WEB_KEY_ID`, `SIMMERSMITH_APPLE_WEB_PRIVATE_KEY`
     (the .p8 PEM content, multi-line), `SIMMERSMITH_GOOGLE_WEB_CLIENT_ID`,
     `SIMMERSMITH_GOOGLE_WEB_CLIENT_SECRET`. flyctl auto-restarts;
     no separate deploy.
  4. Verify in Claude.ai: disconnect/reconnect the MCP, the
     authorize page should now show both buttons.
- **M23.1 cart-automation selector capture** — framework shipped
  in `7145da4` is ready. Activation steps for Taylor:
  1. `uv run --project ~/.claude/skills/simmersmith-shopping python -m simmersmith_shopping login --store sams_club`
  2. `uv run … capture --store sams_club` (walks through one
     search + one ADD, dumps ranked candidates to
     `~/.config/simmersmith-shopping/captures/sams_club-<UTC>/`)
  3. Open `candidates.txt`, transcribe selectors into
     `_SELECTORS` in `skills/simmersmith-shopping/src/simmersmith_shopping/stores/sams_club.py`
  4. Repeat for Instacart.
  Until then, splitter routes around both stores cleanly (logs
  a one-time hint per process).

### Notable findings to keep on the radar

- **M7 Phase 5** was listed under "Deferred" in the roadmap but
  is already done as M19 (`assistant_ai._run_provider_tool_loop`
  + `AnthropicAdapter`). Roadmap corrected in `ac09141`.
- **M5 freemium / subscription** — built across backend + iOS;
  gated by `trial_mode_enabled` ("free Pro for everyone").
  Activation needs App Store Connect product config, .storekit
  testing config, sandbox purchase validation, and the
  flip-trial-mode-off decision. Treat as a live candidate.
- **F401 baseline cleaned up** — `app/` was at 8 pre-existing
  ruff F401 errors, now 0. Tests directory still has some
  pre-existing F401/F811 noise in untouched files.

## Last Session Summary

**Date**: 2026-05-23 — build 105: MCP household fix + assistant SSE heartbeat

Two distinct reliability fixes shipped together — the connector and the
in-app Assistant were both intermittently broken; both deployed today.

**1. MCP `_current_user(session)` household resolution (5 files).** Every
authed MCP tool call had been failing in production with
`CurrentUser.__init__() missing 1 required positional argument:
'household_id'`. M21 made `household_id` required on `CurrentUser`; the
REST FastAPI dependency was updated, but `app/mcp/{profile,weeks,
ingredients,recipes}.py` were not — each constructed `CurrentUser(id=…)`
sans household. The fix centralizes resolution in a new
`app/mcp/_helpers._current_user(session)` helper that mirrors
`get_current_user`'s id+household resolution (lazy-creating a solo
household if missing). All four MCP tool modules switched to it; the
duplicated local `_mcp_user()` helpers are gone. New
`tests/test_mcp_helpers.py` locks in the contract — first MCP-layer test
in the suite, the surface had zero coverage which is exactly why the bug
shipped.

**2. Assistant SSE heartbeat (`app/api/assistant.py` +
`AppState[+Assistant].swift`).** The in-app Assistant felt like it
"thought forever" on `Plan this week` even though the week actually got
populated server-side. Root cause: `generate_week_plan` is one large AI
call (30–60s) with no intermediate events, and the SSE loop yielded
nothing during the idle wait — Fly's HTTP edge eventually idle-closed
the stream, so the iOS client never received the `assistant.completed`
event. Fix: emit `assistant.heartbeat` every 5s while the queue is idle
(new `STREAM_HEARTBEAT_INTERVAL_SECONDS = 5.0`). Just receiving the
event keeps the stream alive (unknown SSE events are ignored
gracefully); the body carries `{message_id, elapsed_seconds}` so the
iOS spinner can be annotated later. iOS side has the decoder + the
switch case wired; `applyAssistantHeartbeat` is intentionally a no-op
with a `TODO(you)` describing three valid UX options (do nothing, track
elapsed-seconds per thread, stamp the in-flight message) — the
keepalive is the actual fix; richer UX is a follow-up choice.

**Status**: both fixes deployed to Fly (build 105). Connector verified;
Assistant spinner-hang regression verified by user. Committed this
session as one logical unit (5 MCP files, 1 assistant API, 2 iOS, 1
new test file, plus this doc) — see `git log` for the hash.

---

**Date**: 2026-05-22 — Remote MCP connector fixed end-to-end + Web SSO activated

The OAuth-gated remote MCP server (`simmersmith.fly.dev/mcp`) had
**never** successfully served an authenticated request since it
shipped (build 97). Claude desktop's connector failed with
"Couldn't connect / Authorization with the MCP server failed".
Root-caused and fixed across three deploys this session; user
confirmed the connector now connects.

**THE bug — mounted sub-app lifespan never ran.** `app/main.py`
mounts the MCP app via `app.mount("/mcp", ...)`. The MCP
`streamable_http_app()` carries a lifespan that starts the
StreamableHTTP **session manager** — but Starlette does NOT run
the lifespan of a *mounted* sub-app. So the session manager was
never started in production, and every authenticated `/mcp`
request returned **HTTP 500**. OAuth itself worked the whole time
(the DB showed every token exchange succeeding). Fix: the FastAPI
`lifespan` now wraps its `yield` in
`async with _mcp_app.router.lifespan_context(_mcp_app):`.
Verified: a server-side `/mcp` `initialize` probe flipped 500 → 200.

**Two earlier fixes this session (real bugs, but not the blocker):**
- **RFC 9728 discovery 404.** The `/mcp` 401 advertised
  `resource_metadata` at the root path, but the MCP SDK only
  served it under the `/mcp` mount prefix. Added an explicit
  `GET /.well-known/oauth-protected-resource/mcp` route in
  `app/api/oauth.py` (+ a test in `tests/test_oauth.py`).
- **OAuth time budgets too short.** `AUTHORIZE_REQUEST_TTL_SECONDS`
  300 → 1800 (`app/services/oauth.py`) and `_STATE_TTL_SECONDS`
  600 → 1800 (`app/services/sso.py`) — the 300s window was sized
  for a token paste, not a human SSO round-trip.

**Also added:** comprehensive diagnostic logging on every OAuth
endpoint in `app/api/oauth.py` — the surface previously logged
nothing, which made this debug painful. Kept as permanent
observability.

**Web SSO (Build 98) is ACTIVE.** All six `SIMMERSMITH_APPLE_WEB_*` /
`SIMMERSMITH_GOOGLE_WEB_*` Fly secrets are set. Google SSO verified
end-to-end; Apple credential chain verified via a direct
token-exchange probe (`.p8` / Key ID `7W4M2A3LWZ` / Team ID
`K7CBQW6MPG` / Service ID `app.simmersmith.web`). The `.p8` is at
repo-root `AuthKey_7W4M2A3LWZ.p8` (gitignored, chmod 600).

**Status**: all three connector fixes deployed and verified.
Committed in two commits — `7d426de` (build 102: lifespan fix,
RFC 9728 route, TTLs, OAuth logging) and `e682b01` (test-infra:
migration 0040 SQLite fix + two build-102 follow-ups). `uv.lock`
left untracked — an unintended `uv run` side effect, not committed.

**Test suite restored to green — `449 passed`.** The pytest suite
had been un-runnable on SQLite since build 95: migration
`20260512_0040` used a plain `op.alter_column(..., nullable=True)`
emitting Postgres-only `ALTER COLUMN ... DROP NOT NULL`, and the
conftest rebuilds a fresh SQLite DB per test, so every test errored
at setup (the "448/448 pass" claims for builds 96–101 could not
have held). Fixed by wrapping the alter in `op.batch_alter_table`
(Postgres still emits a plain ALTER; prod already past 0040, so no
prod impact). Making the suite runnable surfaced two bugs in build
102, both fixed in `e682b01`: (a) the new MCP-lifespan wiring in
`app/main.py` re-entered the single-use `StreamableHTTPSessionManager`
once per TestClient → `RuntimeError` — added a once-per-process
guard; (b) the build-102 test in `tests/test_oauth.py` was inserted
mid-method, orphaning two assertions — restored them.

---

**Date**: 2026-05-18 — build 101 (image-gen failover: OpenAI 5xx → Gemini)

Reliability improvement: when the resolved primary image provider
is OpenAI and OpenAI returns a transient failure (5xx, 429, or
network-level httpx error), we retry once via Gemini if a Gemini
key is configured. Failover is one-directional — Gemini-first
users (who picked Gemini explicitly) do NOT fall back to OpenAI on
a Gemini transient.

- `RecipeImageTransientError(RecipeImageError)` subclass added.
  Callers' existing `except RecipeImageError` handlers keep
  working (subclass relationship preserves backward compat); the
  failover dispatcher catches the transient subclass specifically
  so permanent 4xx errors (400 bad prompt, 401 bad key) still
  surface as before.
- `_TRANSIENT_STATUS_CODES = {408, 429, 500, 502, 503, 504}`
  drives the classification. Parametrized test locks the set in:
  removing a code from the set without updating the test would
  fail loudly.
- `_generate_via_openai` reclassified: 5xx/429 → `RecipeImageTransientError`,
  other 4xx → `RecipeImageError`, `httpx.HTTPError` → transient
  (network-level failures are always transient).
- `generate_recipe_image` catches transient from the OpenAI path
  and retries via Gemini when configured, logging the failover
  via `logger.warning` so ops can grep for it. The returned
  `provider` tuple field reports the actual provider that
  succeeded so admin telemetry (record_image_gen) attributes the
  call correctly.

13 new pytest cases cover: successful-OpenAI doesn't touch Gemini,
Gemini-first user routes directly to Gemini, transient triggers
failover, every transient status code in the set triggers failover
(parametrized), permanent error surfaces unchanged, no-Gemini-key
surfaces the original transient, Gemini-first transient stays at
Gemini (no backward failover), and the returned `provider` field
reports Gemini when failover happened.

448 / 448 pytest pass (was 435 + 13 new). Ruff clean on the
changed files.

**Files changed**: `app/services/recipe_image_ai.py` (+transient
subclass, +failover dispatcher, ~50 lines net), `tests/test_recipe_image_failover.py`
(NEW, ~200 lines, 13 cases).

**Blockers**: None. Activation is automatic for any user whose
account has both keys configured (server-level Fly secrets or
per-user override). No client work required.

---

**Date**: 2026-05-18 — build 100 (M21 household follow-ups: owner transfer + member removal)

Filled the two remaining gaps in M21 household ops: transferring
ownership and removing members (leave + kick).

- `app/services/households.py`: 4 new exception classes
  (`MembershipError`, `NotAMemberError`, `OwnerCannotLeaveError`,
  `OnlyOwnerCanRemoveError`) mapped 1:1 to HTTP statuses in the API
  layer, plus two new service functions:
  - `transfer_ownership(session, *, household_id, current_owner_user_id, new_owner_user_id)` —
    validates the current owner actually holds the role + the target
    is a member + they aren't the same user; swaps roles.
  - `remove_member(session, *, household_id, requesting_user_id, target_user_id)` —
    single function handles both "leave" (when requester == target)
    and "kick" (owner-initiated). Owner cannot be removed via this
    path (must transfer first). Removed user gets a fresh empty solo
    via the existing idempotent `create_solo_household`.
- `app/api/household.py`: 2 new endpoints
  (`POST /api/household/transfer-owner`, `DELETE /api/household/members/{user_id}`),
  service-error → HTTP mapping (403 / 404 / 409 / 400), router
  docstring + module-level endpoint list refreshed.
- `app/schemas/household.py` + `app/schemas/__init__.py`:
  `TransferOwnerRequest` shape added and re-exported. Side cleanup:
  the seven household schemas that had been missing from `__all__`
  since M21 are now listed — pre-existing F401 warnings resolved.
- `app/services/drafts.py`: drive-by removal of one truly unused
  import (`regenerate_grocery_for_week`) that came up in ruff's
  baseline.
- `tests/test_household_member_ops.py` (NEW): 17 cases covering
  transfer happy path + the 4 transfer-rejection paths (non-owner
  caller, non-member target, self-transfer, post-transfer the new
  owner can mint invitations / old owner cannot), leave happy path
  + owner-can't-leave guards + leaver-gets-fresh-solo, kick happy
  path + kicked-user-can-rejoin + non-owner-can't-kick +
  kick-non-member-404 + owner-cannot-be-removed-by-member, and
  invariants (single owner, member count drops by one on leave).

435 pytest pass (was 418 + 17 new). Ruff clean on all changed
files; `app/` directory globally goes from 8 F401 baseline errors
to 0.

**Files changed**: `app/services/households.py` (+helpers + 4
exceptions, ~120 lines), `app/api/household.py` (+2 routes, ~75
lines), `app/schemas/household.py` (+1 model), `app/schemas/__init__.py`
(+7 entries to `__all__`), `app/services/drafts.py` (-1 dead
import), `tests/test_household_member_ops.py` (NEW, ~230 lines).

**Blockers**: None — endpoints are live as soon as build 100 ships.
iOS surface to expose these in Settings → Household is a separate
client-side work item.

---

**Date**: 2026-05-18 — build 99 (Anthropic web search support for recipe finder)

The recipe finder (M12 Phase 4) was OpenAI-only. This build adds
Anthropic Messages API + `web_search_20250305` tool as a peer
provider so users with Anthropic keys (or who simply prefer Claude
for recipe discovery) get parity.

- `app/services/recipe_search_ai.py`: factored `_resolve_openai_target`
  into `_resolve_provider` + `_resolve_target`, mirroring the
  `recipe_image_ai._resolve_provider` precedent (user setting
  `recipe_search_provider` > global `ai_recipe_search_provider` >
  `"openai"` default). Split the wire-format code into
  `_search_openai` (Responses API) + `_search_anthropic` (Messages
  API), each returning raw text; the JSON parse + `_AIRecipe`
  validation happens once after dispatch so both providers share
  the same schema-mismatch error path.
- `app/config.py`: new `ai_recipe_search_provider` (default
  `"openai"`) so the admin can flip the global default without
  every user re-configuring.
- Anthropic payload parser skips intermediate `server_tool_use` +
  `web_search_tool_result` blocks and concatenates the final `text`
  block(s).
- `app/api/discovery.py`: route docstring refreshed to reflect
  dual-provider reality; the endpoint surface is unchanged because
  it already passes `profile_settings_map` through and reads
  `recipe_search_provider` from there automatically.
- `tests/test_recipe_search_ai.py` (NEW): 13 tests cover the
  provider router (user > global > default precedence), OpenAI wire
  format + Responses payload parsing (including the flat
  `output_text` collapsed shape), Anthropic wire format + Messages
  payload parsing (incl. the tool-block-skip path), missing-API-key
  errors that name the provider in their message, and the empty-
  query / invalid-JSON / schema-mismatch error paths.

418 / 418 pytest pass (was 405 + 13 new). Ruff clean on the changed
files.

**Files changed**: `app/services/recipe_search_ai.py` (rewrite,
~330 lines), `app/config.py` (+1 field), `app/api/discovery.py`
(docstring refresh), `tests/test_recipe_search_ai.py` (NEW, ~310
lines, 13 cases).

**Blockers**: None. To opt into Anthropic per-user, an iOS or
preferences-API client writes `recipe_search_provider=anthropic`
to the user's `profile_settings` row (same shape as
`image_provider`). Admins can flip the global default with
`SIMMERSMITH_AI_RECIPE_SEARCH_PROVIDER=anthropic` Fly secret.

---

**Date**: 2026-05-15 — build 98 (M24.1 Apple/Google web SSO on /oauth/authorize)

Replaces the V1 bearer-token-paste user-auth on the OAuth authorize
page with real Apple Sign In for Web + Google Sign In for Web.
OAuth surface (metadata, DCR, code exchange, JWT, PKCE) is
unchanged — only the human-authentication step on /oauth/authorize
gains two new redirect-flow paths.

- `app/services/sso.py` (NEW): state JWT mint/verify (HS256, 10min
  TTL, provider-scoped), provider authorize-URL builders, Apple
  ES256 `client_secret` minting per token-exchange (no long-lived
  secret stored), code-exchange against Apple + Google token
  endpoints, web-flavored id_token verifiers (different aud claim
  than iOS), find-or-create user helpers reusing same `apple_sub` /
  `google_sub` columns as iOS auth so signing in via web matches
  the existing iOS account.
- `app/api/oauth.py`: 4 new endpoints (`GET /oauth/sso/{apple,google}/start`,
  callbacks at `POST /oauth/sso/apple/callback` for Apple's
  `form_post` mode and `GET /oauth/sso/google/callback`). Authorize
  page HTML now renders Apple + Google buttons (each gated by env
  presence — buttons hide when its config isn't set) plus a
  collapsible "Use a SimmerSmith API token instead" fallback.
- `app/config.py`: 6 new env vars — `apple_web_service_id`,
  `apple_web_team_id`, `apple_web_key_id`, `apple_web_private_key`,
  `google_web_client_id`, `google_web_client_secret`. All optional;
  empty = button hidden.
- `tests/test_sso.py` (NEW): 21 tests covering enablement gates,
  state-JWT roundtrip + tamper / expiry / provider-mismatch
  rejection, Apple client_secret minting (decoded against the
  test's own ES256 public key), authorize page button-presence
  conditional on env, start endpoints' redirect-to-provider, and
  callback rejection of garbage state JWTs.

Find-or-create defaults to OPEN signup (matches existing iOS
`auth_apple`/`auth_google` precedent — anyone who can prove
ownership of an Apple/Google account gets a User row). Lock-down
flag is a one-line follow-up if needed.

405 / 405 pytest pass (was 384 + 21 new). Ruff clean.

**Files changed**: `app/config.py` (+6 fields), `app/services/sso.py`
(NEW, ~280 lines), `app/api/oauth.py` (+4 endpoints, +SSO buttons
+ collapsible fallback + module docstring rewrite),
`tests/test_sso.py` (NEW, ~320 lines, 21 cases).

**Blockers**: SSO buttons hide until Taylor configures the portals:
1. **Apple Developer Portal**: register a Service ID (separate from
   App ID), enable Sign In with Apple on it, set return URL to
   `https://simmersmith.fly.dev/oauth/sso/apple/callback`, generate
   a `.p8` private key with Sign In with Apple capability, note
   the Team ID + Key ID.
2. **Google Cloud Console**: create new OAuth 2.0 Web Client (NOT
   iOS), authorized redirect URI
   `https://simmersmith.fly.dev/oauth/sso/google/callback`, note
   client_id + client_secret.
3. Set 6 Fly secrets:
   `flyctl secrets set SIMMERSMITH_APPLE_WEB_SERVICE_ID=… SIMMERSMITH_APPLE_WEB_TEAM_ID=… SIMMERSMITH_APPLE_WEB_KEY_ID=… SIMMERSMITH_APPLE_WEB_PRIVATE_KEY="$(cat AuthKey_…p8)" SIMMERSMITH_GOOGLE_WEB_CLIENT_ID=… SIMMERSMITH_GOOGLE_WEB_CLIENT_SECRET=… -a simmersmith`
4. `fly deploy --remote-only -a simmersmith`.
5. Reconnect Claude.ai to `https://simmersmith.fly.dev/mcp` and
   pick "Sign in with Apple" on the authorize page.

---

**Date**: 2026-05-15 — M23.1 cart-automation framework (capture
subcommand + driver scaffolds + selector-rot docs)

Framework half of M23.1 is now in `skills/simmersmith-shopping/`,
ready for the manual selector-authoring pass that requires Taylor's
live login at Sam's Club + Instacart.

- New `capture` subcommand in `cli.py`. Resumes the same persistent
  Playwright profile the `login` subcommand seeded, walks the user
  through one search + one ADD interaction, snapshots rendered HTML
  at each step, and writes a ranked selector-candidate file. Output
  lands in `~/.config/simmersmith-shopping/captures/<slug>-<UTC>/`
  with `search.html`, `product.html`, and `candidates.txt`. The
  candidates file is sorted by attribute stability (`data-testid` >
  `data-automation-id` > `data-test` > `aria-label` > `role` >
  `name`) and headers each grep hint for the three selectors that
  matter most: `search_input`, `product_card`, `add_to_cart`.
- New `locate(page, selectors, key, store=…, where=…)` helper in
  `stores/base.py` that wraps every selector use in a domain
  `SelectorMissing` error naming the failed `_SELECTORS` key. Aldi +
  Walmart refactored to use it; the existing two drivers and the
  two new scaffolds all surface identical diagnostic messages on
  selector rot. Meets M23.1 spec acceptance criterion #3.
- Sam's Club + Instacart drivers go from stub to scaffold. The
  search/add code path mirrors Aldi exactly; only `_SELECTORS` is
  empty, behind a `_hint_needs_capture()` log-once guard so the
  splitter cleanly routes around them today. Once `_SELECTORS` is
  populated (per the in-file docstring workflow), the same code
  path goes live without touching the orchestrator.
- `SKILL.md` gets a "When a driver breaks" section documenting the
  capture-then-edit-selectors loop so selector rot is repairable
  without re-reading the spec. Includes the priority order, the
  three canonical grep patterns, and the per-driver workflow.

8 existing pytest cases (parser + splitter) still pass; ruff clean
on the changed files. End-to-end activation requires the manual
capture pass — explicit user-side instructions in the M23.1 handoff
notes below.

**Files changed**: `skills/simmersmith-shopping/src/simmersmith_shopping/cli.py`
(+capture command, +candidate parser), `stores/base.py` (+locate
helper, +SelectorMissing), `stores/aldi.py` + `stores/walmart.py`
(refactored to use locate), `stores/sams_club.py` + `stores/instacart.py`
(stub → scaffold), `SKILL.md` (+selector-rot section).

**Blockers**: M23.1 selector-authoring requires Taylor to:
1. Run `python -m simmersmith_shopping login --store sams_club`,
   sign in, confirm the right club is selected, close window.
2. Run `python -m simmersmith_shopping capture --store sams_club`
   and walk through one search + one ADD.
3. Open the resulting `candidates.txt` and transcribe selectors
   into `_SELECTORS` in `stores/sams_club.py`.
4. Repeat for Instacart.

---

**Date**: 2026-05-15 — Builds 96 + 97 (gpt-5.5 chat fix + M24 Remote OAuth MCP)

Shipped two backend builds in one session:

**Build 96 — fix(ai): strip temperature/max_tokens on gpt-5.5+ chat
completions.** Build 93 flipped the default OpenAI model to
`gpt-5.5` but every chat/completions caller (`assistant_ai`,
`vision_ai`, `week_planner`) still shipped `temperature: 0.x` — the
new reasoning-class models return HTTP 400 on any non-default
temperature. Production symptom: AI Assistant + week generation +
vision flows all dead with `Client error '400 Bad Request' for url
'https://api.openai.com/v1/chat/completions'`. Fix:
`provider_models.openai_chat_body(model, base)` drops `temperature`
and renames `max_tokens` → `max_completion_tokens` when the model
matches the reasoning-class prefix list (`o1`, `o3`, `o4`,
`gpt-5.5`); standard models pass through unchanged. 4 call sites
refactored; 16 new unit tests. Pre-existing AI services (event,
pairing, recipe-difficulty, recipe-drafting, seasonal) flow
through the fixed `run_direct_provider` so they're covered
transitively.

**Build 97 — feat(mcp): M24 Remote OAuth MCP server.** Hosts the
existing 55-tool `app/mcp/` surface at `simmersmith.fly.dev/mcp`
behind OAuth 2.1 + PKCE. New surface:

- `OAuthClient` + `OAuthAuthorizeRequest` tables (alembic 0041).
- `app/services/oauth.py` — auth-code minting, PKCE verification
  (S256 only), single-use code semantics, stateless JWT access
  tokens (aud="mcp", 30-day TTL, signed with the existing
  `SIMMERSMITH_JWT_SECRET`).
- `app/api/oauth.py` — `/.well-known/oauth-authorization-server`
  (RFC 8414 metadata), `/oauth/register` (RFC 7591 DCR),
  `/oauth/authorize` (HTML approval page), `/oauth/token` (code
  exchange).
- `app/mcp/auth.py::JWTTokenVerifier` — validates bearer tokens,
  sets per-request `_current_user_id_var` ContextVar.
- `app/mcp/__init__.py::build_http_app()` — returns a FastMCP
  streamable-HTTP ASGI app with the JWT verifier wired up. Mounted
  on FastAPI in `app/main.py` at `/mcp`.
- User-scoping refactor: every `_settings().local_user_id` and
  `get_settings().local_user_id` call across `app/mcp/{assistant,
  weeks,recipes,ingredients,profile}.py` rewritten to
  `_current_user_id()`. Falls through to `local_user_id` when the
  ContextVar is unset, so the existing stdio MCP path
  (`scripts/run_simmersmith_mcp.py`) keeps working without
  authentication.

V1 user-auth limitation: the `/oauth/authorize` HTML page asks for
the user's `SIMMERSMITH_API_TOKEN` (matches `settings.api_token` →
approves as `settings.local_user_id`). Works for Taylor. Apple /
Google web sign-in for true multi-user is M24.1 — the OAuth
surface itself doesn't change; only the authorize page's HTML.

17 new OAuth tests cover metadata shape, DCR round-trip, authorize
input validation, end-to-end flow, PKCE verifier mismatch, code
replay, unapproved-code rejection, session-JWT-replay rejection
(aud="mcp" enforcement), expired-token rejection, wrong-secret
rejection. Full pytest sweep: 384 passing (was 367 + 17 new).
`ruff check` clean on all new files.

**Files changed** (build 96 + 97 combined): 18 new / modified
under `app/`, `tests/`. New `alembic/versions/20260515_0041_*`.
`AGENTS.md` MCP-surface line corrected (47 → 55 tools, OAuth host
mention). Two updated commits: `1964ed5` (build 96), `9b712b1`
(docs sync), build 97 in this commit.

**Validation**: 384 / 384 pytest pass. `ruff check` clean on
changed files. App imports cleanly via `python -c "from app.main
import app"`. Stdio MCP unchanged. End-to-end UAT requires a Fly
deploy + a Claude.ai user adding `https://simmersmith.fly.dev/mcp`
as an MCP server — that's the next step.

**Blockers**: None code-side. UAT depends on user-driven deploy +
Claude.ai connection attempt.

---

**Date**: 2026-05-14 — Builds 66–95 catch-up (handoff docs were 30 builds stale)

The handoff docs fell out of sync between build 65 (2026-05-06) and
build 95 (2026-05-13). This entry consolidates the span. iOS is on
build 93 (TestFlight); admin builds 94–95 deployed to Fly +
Cloudflare on 2026-05-13. Backend: 351 tests passing.

**Fusion redesign — finished the rollout (builds 76–79)**
- Build 76: per-tab configurable primary FAB (TopBarSettings),
  TopBarSparkleButton, SmithToolbar paper-on-cream treatment with a
  hand-drawn ember rule across every screen, Forge search promoted
  to a top-bar icon, Settings simmer·smith wordmark, new anvil+
  spatula logo (AppIcon.appiconset + BrandMark.imageset).
- Build 78: secondary-screen sweep — 40+ sheets/views get the paper
  toolbar + ember buttons; app icon auto-crops to the alpha bbox so
  the mark fills the tile.
- Build 79: FuHero on the last three tabs (Grocery/Pantry/Events),
  15 Settings sections to lowercase Caveat handwritten headers,
  CookingMode HammeredGrain canvas overlay.

**Dogfood-driven fixes (builds 80–92)** — Taylor + Savanne on
TestFlight; most of this span is feedback triage.
- Build 80: BGAppRefresh sync now respects cancellation — root-cause
  fix for SIGKILL background crashes (Reminders sync ran past iOS's
  30s budget).
- Build 81: Savanne pass — future-week hero labels, AI sparkle pill
  on recipe cards, Dessert filter, InSeasonStrip moved to Grocery,
  and AI-generated recipe photos replaced with category-derived
  gradient + SF Symbol illustrations (imageUrl path preserved on the
  model for a possible future toggle).
- Builds 82–85: hand-drawn recipe icon library (28 Path-composed
  glyphs), per-recipe picker, server-side `icon_key` column (alembic
  0037) + iOS sync + one-shot local→server migration.
- Build 86: re-mounted the AI overlay as a sheet host (per-day
  sparkles were dead after build 76 dropped the floating FAB), Forge
  filters narrow the Recently Added rail, horizontal swipe across
  the Week hero changes weeks.
- Build 87: grocery "Plan Shopping" flow replaces the auto-populated
  list (Taylor flagged the cleanup tax) — `auto_grocery_from_meals`
  setting (default off), plan-shopping projection endpoint,
  quick-add, clear-auto, per-item `store_label` (alembic 0038).
- Build 88: resolver no longer clobbers a server match back to
  "unresolved" from the inbound payload; `reresolve` service +
  endpoint + iOS one-shot backfill; swipe-to-pantry on grocery +
  plan-shopping rows.
- Build 89: day-of-month numerals use the UTC calendar (CDT users
  saw them a day behind).
- Build 90: Week FAB opens the contextual popup AI sheet scoped to
  the displayed week instead of switching to the Smith tab.
- Build 91: Reminders Connect/Disconnect buttons replace the toggle
  (fixes the picker-sheet teardown race); picker hoisted to
  SettingsView body level.
- Build 92: "Hide completed" grocery filter (per-device, only shows
  when ≥1 item is checked).

**Admin portal + usage visibility (builds 93–95)**
- Build 93: default OpenAI model → gpt-5.5; `increment_usage` now
  accrues for every user (pro/trial included — visibility only,
  paywall bypass unchanged); user-facing "ai usage (this month)"
  section in iOS Settings.
- Build 94 (admin v1): `server_settings` table (alembic 0039) for
  operator-tunable knobs; `/api/admin/usage`, `/users`, `/settings`
  endpoints; SvelteKit admin site at admin.simmersmith.app behind
  Cloudflare Access + a bearer-gated FastAPI inner layer.
- Build 95 (admin v2): `/api/admin/users/{id}` detail endpoint,
  `POST .../subscription` manual grant-Pro / revoke, editable
  `usage_cost_usd` cost-rate map, `apple_original_transaction_id`
  made nullable + `admin_note` column (alembic 0040) so admin grants
  share the `subscriptions` table; admin site `/users/[id]` page +
  cost columns.

**Validation**: 351 backend tests passing. iOS build 93 on
TestFlight. Admin builds 94–95 live on Fly + Cloudflare (deployed
2026-05-13). `project.yml` `CURRENT_PROJECT_VERSION` → 93.

**Blockers**: None.

**Note for planning**: the roadmap still lists M5 (Freemium +
Subscription) as "deferred — none done", but the subscription /
entitlements / usage-counter / paywall infrastructure clearly exists
(`app/models/billing.py`, `app/services/entitlements.py` +
`subscriptions.py`, iOS `Features/Paywall/PaywallSheet.swift` +
`AppState+Subscription.swift`, StoreKit linked). M5's real status
needs reconciling — flagged for the next milestone-planning pass.

---

**Date**: 2026-05-06 — Build 65 (Cooking IA + Forge list fix + RecipeDetail calorie move)

User signed off on RecipeDetail visuals from build 64. Asked for
three things in build 65:
1. Move calorie / nutrition out of the RecipeDetail hero metadata
   strip (it was duplicating the dashed stat row's purpose).
2. Bring the Cooking screen into Fusion.
3. Fix the Forge list rows — they were still rendering with solid
   `Divider()` between rows and a system-style section header,
   even though the cards themselves were restyled in build 58.

`Features/Recipes/RecipeDetailView.swift`:
- `metadataPills` no longer includes the calorie chip, servings,
  prep, or cook (already in the stat row hero). Strip is now just
  the longer-tail metadata: usage summary, override flags,
  difficulty, kid-friendly.
- `nutritionSection` invocation moved out of the top region (was
  right after the scale picker) and down to after the
  ingredients/steps content. Full breakdown is still inline (not
  hidden behind a sheet) but no longer competes with title + stats
  + tags for top-of-screen attention.

`Features/Recipes/RecipesView.swift`:
- `recipeListStack` and the editorial `Recently Added` list now
  use `HandRule` between rows (was solid `Divider()` with system
  divider tint). List page reads as paper notebook now.
- `sectionHeader` redesigned: lowercase Caveat handwritten 20pt
  bold + ember HandUnderline, matches the Week tab's "the week"
  pattern. Editorial sections (Tonight's Dinner / This Week /
  Favorites / Recently Added / All Recipes) read as chapters in
  the same notebook.
- Selection-mode checkmark icons retinted ember/inkFaint (was
  primary/textTertiary).

`Features/Cooking/CookingModeView.swift`:
- `topBar` rewritten:
  - Three-column header: ✕ close left, `◆ AT THE FORGE` mono
    ember center (2.4pt tracking), `NN/NN` mono step counter right.
  - Voice / mute toggles move to a small row underneath, ember
    when active, ash when off.
  - Progress hairline at the bottom of the bar is now a 1.5pt
    ember rule with a soft ember shadow — replaces the system
    `ProgressView`. Reads as the hot-iron seam from the mockup.
- `bottomBar` rewritten:
  - "Ask the smith" pill in the middle (Caveat handwritten with
    ember sparkles icon, ember capsule outline, low visual weight).
  - Bottom row: `← back` / `step N` Caveat handwritten on the left
    (ember-soft when disabled), big slightly-rotated ember CTA on
    the right (`next →` / `done →` in Caveat 20pt bold on ember
    background with ember shadow glow).
- Step area, step number, ember-glow shadow, italic-serif
  instruction, hammered-iron grain — all unchanged from build 58.

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 64 → 65.

Pending IA builds (queue continues):
- Build 66: Grocery — pantry washi callout, store-color outlined
  Caveat tabs, dashed rules.
- Build 67: Smith — chat surface with washi-taped draft cards.

---

**Date**: 2026-05-06 — Build 64 (Fusion RecipeDetail IA)

User signed off on Forge filter collapse and asked to keep moving.
Build 64 brings the recipe detail screen into the Fusion notebook
aesthetic.

`Features/Recipes/RecipeDetailView.swift`:
- `headerSection` rewritten. Was a 200pt-tall background image with
  the title overlaid in the bottom-left corner. Now centered
  composition: mono `recipe` (or `archived recipe`) eyebrow → 38pt
  italic-serif title → Caveat sub-line built from
  `recipe.subtitleFragments` → **circular** `RecipeHeaderImage`
  (200×200) inside a 1.5pt ink stroke with an ember-dot annotation
  (with glow shadow) at the top-right → dashed-rule stat row.
- New `recipeStatRow(_:)` helper: italic-serif numerals + Caveat
  unit labels (`minutes`, `plates`, `ingredient[s]`), framed top
  + bottom by dashed hairlines. Falls back to `—` when a number
  isn't available.
- `metadataPill(icon:text:)` restyled to outlined Caveat — no fill,
  Caveat handwritten label, ember icon, 0.8pt rule capsule border.
  The wrapping pill row below the stat row reads as paper margin
  tags now instead of dark chips.
- `ingredientsSection` rewritten. Was an SMCard slab with solid
  Divider lines and primary-amber quantity text. Now:
  - Caveat ember "ingredients" header with HandUnderline + mono
    "X in pantry" right eyebrow showing the pantry-match count.
  - Each row: HandCheck on the left (filled with ember when the
    ingredient matches a pantry item), Spectral name + italic
    Spectral prep, italic-serif quantity + Caveat unit on the right,
    AI ember-tinted "wand.and.stars" Menu (substitute / avoid /
    allergy) preserved unchanged.
  - HandRules between rows (no solid Divider).
- New `isInPantry(_:)` helper does a case-insensitive name
  comparison against `PantryItem.normalizedName` (or stapleName as
  fallback). Not catalog-precise — that needs server-side
  resolution — but a real signal for the common case
  (`"milk"` matches pantry "milk").

`DesignSystem/Components/FusionPrimitives.swift`:
- New `DashedRule` view — thin dashed hairline used on the
  RecipeDetail stat row top + bottom. GeometryReader-backed Path
  stroke so it scales to its container width.

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 63 → 64.

Pending IA builds (queue continues):
- Build 65: Cooking — ◆ AT THE FORGE top bar, riveted timer plate,
  Caveat ember CTAs.
- Build 66: Grocery — pantry washi callout, store-color outlined
  Caveat tabs, dashed rules.
- Build 67: Smith — chat surface with washi-taped draft cards.

---

**Date**: 2026-05-06 — Build 63 (Fusion Forge IA · filter collapse)

User signed off on the Week tab + meal action sheet, asked to move
to the next tab. Build 63 collapses the 5 inline filter rows on
RecipesView into:

1. System `.searchable` in the Liquid Glass nav bar (replaces the
   custom `searchBar` view + isSearchFocused state).
2. A single `mealTypeFilterPills` row at the top of scroll —
   restyled as Fusion outlined Caveat chips with alternating ±0.6°
   rotations.
3. A new `RecipeFilterSheet` (paper-backed bottom sheet) presented
   from a Filters toolbar button. Holds difficulty, quick (≤30 min)
   toggle, and cleanup filters as outlined Caveat chip rows
   separated by HandRules. Reset / Done in the toolbar.
4. An inline "active filters" Caveat ember summary row appears
   under the meal-type chips when ≥1 advanced filter is active —
   shows e.g. `easy · quick (≤30 min)` followed by an `xmark.circle`
   to clear all in one tap.
5. Filter button on the toolbar gets an ember count badge when
   filters are active.

`Features/Recipes/RecipesView.swift`:
- Body: removed inline `searchBar`, `difficultyFilterPills`,
  `quickFilterPill`, `cleanupFilterPills`. Added `mealTypeFilterPills`
  + conditional `activeFiltersSummary` between the FuHero and the
  results.
- Removed dead view definitions (`searchBar`, `difficultyFilterPills`,
  `quickFilterPill`, `cleanupFilterPills`) — ~110L deleted.
- New `@State showingFilterSheet`, new helpers `filterBadgeCount`
  + `activeFiltersSummary`.
- `mealTypeFilterPills` now renders inside a horizontal ScrollView
  using `FuOutlinedPill` so chips can overflow on smaller devices.
- Added `.searchable(text: $searchText, placement:
  .navigationBarDrawer(displayMode: .automatic), prompt: …)` —
  Liquid Glass search.
- Added `.sheet(isPresented: $showingFilterSheet) { RecipeFilterSheet(...) }`.
- Toolbar gains a `line.3.horizontal.decrease.circle` Filters
  button with an ember count badge offset to the top-right.

`Features/Recipes/RecipeFilterSheet.swift` (new, ~165L):
- NavigationStack with a paper-backed scroll, a washi-taped index-
  card title plate ("narrow the forge" + active count eyebrow),
  three outlined-Caveat-chip sections (difficulty / speed / cleanup)
  separated by HandRules. Native toolbar Reset / Done. `.medium`
  + `.large` presentation detents.
- Bound to RecipesView's @State so dismissing keeps selections;
  Reset clears them.
- Local `DifficultyFilter.shortLabel` extension converts "Any
  difficulty" → "any" etc. so chips fit on one row.

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 62 → 63.

Pending IA builds (queue continues):
- Build 64: RecipeDetail.
- Build 65: Cooking.
- Build 66: Grocery.
- Build 67: Smith.

---

**Date**: 2026-05-06 — Build 62 (Fusion meal action sheet)

User flagged the meal-tap menu as the next surface to bring into
the Fusion aesthetic. The native `.confirmationDialog` was working
fine functionally but read as iOS-system rather than paper-on-paper.

New `Features/Week/MealActionSheet.swift` (~210L):
- `.sheet(item: $selectedMealForAction)` replaces the
  `.confirmationDialog`. Native sheet chrome (drag indicator,
  swipe-down-to-dismiss, presentation detents) preserved per the
  user's instruction to keep system UI affordances.
- Header: `FuIndexCard` with washi-tape strip, Caveat eyebrow
  (`<day> · <slot>`), italic Instrument Serif meal name (24pt),
  optional "✓ done" Caveat ember chip when approved.
- Action rows in 5 groups separated by `HandRule`:
  1. Recipe (when `meal.recipeId != nil`): view recipe (primary
     ember), rate this meal.
  2. Edit (always): edit name, edit notes, manage sides.
  3. Move / Link: move to…; link to recipe + create recipe with
     the smith (primary ember) when no recipe is linked.
  4. Status: approve/unapprove, ate out tonight, save leftovers
     to freezer.
  5. Destructive: remove (red).
- Each row = SF Symbol icon (24pt column) + Spectral 16pt label.
  `ActionRole` enum drives icon/text tint: `normal` (inkSoft +
  ink), `primary` (ember + ink + ember `→` arrow on the right),
  `destructive` (red on red).
- Sheet owns no model state; every action is a closure callback
  back to `WeekView` so the existing per-action machinery (rename
  text + state, AI create, eating-out, etc.) keeps working
  unchanged.
- `WeekView` body: confirmationDialog block (~58L) replaced with
  a single `.sheet(item:)` that passes 12 callbacks into
  `MealActionSheet`. Net read: cleaner, more direct.

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 61 → 62.

Pending IA builds (queue continues, all renumbered):
- Build 63: Forge (Recipes) — collapse 5 filter rows to one chip.
- Build 64: RecipeDetail.
- Build 65: Cooking.
- Build 66: Grocery.
- Build 67: Smith.

---

**Date**: 2026-05-06 — Build 61 (Week · bigger day pillar + past-day collapse)

User feedback on build 60: bump up the day pillar visual weight,
collapse past days by default to clear vertical real estate, allow
expanding any past day on tap.

`Features/Week/WeekView.swift`:
- New `@State expandedPastDays: Set<String>` keyed by
  `DayKey.server(date)` tracks which historical days the user has
  toggled open.
- New `isPastDay(_:)` helper using YYYY-MM-DD string comparison
  (timezone-safe) — true for any date strictly before today's
  local calendar day.
- `daySection` redesigned:
  - Pillar grew from 13pt name / 22pt numeral / 36pt wide
    → 17pt handwritten bold name / 38pt italic-serif numeral /
    54pt wide. Spine grew 2pt → 3pt on today.
  - Past days collapse to: pillar + summary line in italic
    Spectral ("3 meals · 2 done") + chevron-down toggle. Tap
    to expand → full slots render with smooth ease-in-out.
  - Today + future days always render slots (chevron not shown).
  - AI sparkle + MacroRing affordances move to today/future-only
    rows; past collapsed rows just show the chevron.
- New `pastDaySummary(meals:)` helper builds the collapsed-row
  one-liner: "no meals planned" / "1 meal" / "3 meals · 2 done"
  / "3 meals · all done".

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 60 → 61.

Pending IA builds (queue continues, all renumbered):
- Build 62: Forge (Recipes) — collapse 5 filter rows to one chip.
- Build 63: RecipeDetail.
- Build 64: Cooking.
- Build 65: Grocery.
- Build 66: Smith.

---

**Date**: 2026-05-06 — Build 60 (Fusion Week IA · multi-slot restored)

Build 59 was over-aggressive — it collapsed Week to one meal per day
and dropped the In-Season strip + snack affordances. User flagged
that the day rows must keep all configured slots (breakfast / lunch
/ dinner / etc.), the snack add affordance must come back, the
In-Season strip belongs at the top of the Week tab, and every empty
slot needs a quick-add. Build 60 walks the over-aggression back
while keeping the Fusion paper styling.

`Features/Week/WeekView.swift`:
- Body: FuHero → **InSeasonStrip** (back) → Tonight TodayMealCard
  → `daysSection` (multi-slot, restored from build 59's
  weekRosterSection).
- `daysSection` header: handwritten "the week" + ember underline
  (was `Text("This Week")` in subheadline). Weekly calorie pill
  retained but restyled (ember/risoGreen instead of orange/green
  filled capsule).
- `daySection`: leading 2pt ember spine on today (was full-row
  background tint), day pillar (handwritten 3-letter + italic
  serif numeral), AI per-day sparkle button restyled to ember
  outline. MacroRing per-day retained. Each day separated by
  `HandRule` (was nothing).
- `renderSlots(...style: .compact)` keeps the existing
  `CompactMealCard` per filled slot — already restyled in build
  58.
- `emptySlotButton`: paper tile with dashed-stroke rule border,
  Caveat slot label, italic-serif "plan a meal" placeholder,
  ember `+` on the right (was dark-card filled with system body
  font).
- `addSnackAffordance`: small ember Caveat "+ snack" affordance
  back (build 59 dropped it).
- The toolbar Menu (week picker, approve-all, jump-to-week) from
  build 59 stays — it's the right place for chrome that doesn't
  belong on the scroll surface.

Verification: `xcodebuild build` succeeds. No backend / schema /
test changes. `project.yml` `CURRENT_PROJECT_VERSION` 59 → 60.

Pending IA builds (queue continues):
- Build 61: Forge (Recipes) — collapse 5 filter rows to one chip row.
- Build 62: RecipeDetail — circular hero, dashed stats, my notes,
  in-pantry HandCheck on ingredients.
- Build 63: Cooking — ◆ AT THE FORGE top bar, riveted timer plate,
  Caveat ember CTAs.
- Build 64: Grocery — pantry washi callout, store-color outlined
  Caveat tabs, dashed rules.
- Build 65: Smith — chat surface with washi-taped draft cards.

---

**Date**: 2026-05-06 — Build 59 (Fusion IA · Week roster restructure)

First of a multi-build IA pass after build 58 (which was skin-only)
landed. User flagged that the mockup spec implies real layout
changes, not just a palette + typography swap. Plan: ship one IA
restructure per build, in priority order, smoke-test between.

Build 59 covers Week:
- `Features/Week/WeekView.swift`:
  - Body simplified to: FuHero → Tonight TodayMealCard →
    `weekRosterSection`. The previous inline `weekPicker`,
    `InSeasonStrip`, `approveAllBar`, and `groceryBar` are
    removed from the scroll surface.
  - New `weekToolbarMenu` (top-leading) collapses week
    navigation (prev / next / jump-to-week list / snap-to-current)
    and the bulk approve-all action into a single Menu under the
    `simmer·smith` wordmark + chevron. The InSeasonStrip + grocery
    bar are dropped — InSeason discovery moves to a future build,
    Grocery is its own tab anyway.
  - New `weekRosterSection` renders one row per day (handwritten
    day name + italic-serif numeral pillar + featured-meal title
    + Caveat sub-line + ✓ done OR cook minutes on the right).
    Today gets a 2pt ember vertical spine on the left edge.
    `HandRule` separates rows. Tap a row → existing meal action
    sheet (or quick-add if the slot is empty).
  - New helpers: `featuredMeal(in:)` (prefers dinner →
    first-non-snack → first), `rosterSubline(for:)` (sides → notes
    first-line → empty), `rosterCookMinutes(for:)` (recipe prep+cook,
    nil if 0/0), `defaultSlotName()`, `approveAllMeals(_:)`.
- The old `daysSection` / `daySection` / `addSnackAffordance` /
  `rebalanceBanner` / `approveAllBar` / `groceryBar` / `weekPicker`
  helpers stay in the file but are no longer called. Left in place
  for now in case Savanne wants the macro ring / per-day calorie
  banner / approve-all bar back; will be deleted once dogfood
  confirms the sparser IA holds.

Verification: `xcodebuild build` succeeds. No backend, no schema,
no test changes. `project.yml` `CURRENT_PROJECT_VERSION` 58 → 59.

Pending IA builds (queued):
- Build 60: Forge (Recipes) — collapse 5 filter rows to one chip row.
- Build 61: RecipeDetail — circular hero, dashed stats, my notes,
  in-pantry HandCheck on ingredients.
- Build 62: Cooking — ◆ AT THE FORGE top bar, riveted timer plate,
  Caveat ember CTAs.
- Build 63: Grocery — pantry washi callout, store-color outlined
  Caveat tabs, dashed rules.
- Build 64: Smith — chat surface with washi-taped draft cards.

---

**Date**: 2026-05-06 — Build 58 (Fusion redesign · The Smith's Notebook)

Visual redesign to direction E1 from Claude Design's mockup deck —
"Fusion · The Smith's Notebook (subtle Forge)". Linen-paper analog
as the base, ember (`#E8541C`) replacing amber as the accent, hot
iron treatment used sparingly on cooking + CTAs. Light-paper primary
following system color scheme; forge dark when iOS is in Dark Mode.
Native iOS Liquid Glass tab/nav bars and system buttons (Settings
gear, sheet ×, alert actions, etc.) preserved per user instruction —
the restyle applies to in-content surfaces only.

**Tokens** (`SimmerSmith/SimmerSmith/DesignSystem/Theme.swift`):
- Full rewrite. New `Color(light:dark:)` initializer wraps
  `UIColor { trait in … }` so every token resolves dynamically
  against `UITraitCollection.userInterfaceStyle`. iOS handles the
  light/dark switch; no `@Environment(\.colorScheme)` plumbing in
  views.
- New tokens: `paper`, `paperAlt`, `plate`, `ink`, `inkSoft`,
  `inkFaint`, `rule`, `ember`, `emberHot`, `bronze`, `risoBlue`,
  `risoGreen`, `risoYellow`. Stable public names (`primary`,
  `accent`, `surface`, `textPrimary`, etc.) are now type aliases
  pointing at the new tokens (`primary = ember`, `surface = paper`,
  etc.) — that's why the 59 consumer files didn't all need
  touching for the palette swap.
- `SMFont` adds Fusion-native helpers: `serifDisplay(_:)` (Instrument
  Serif Italic), `serifTitle(_:)` (Instrument Serif Regular),
  `bodySerif(_:)` / `bodySerifItalic(_:)` (Spectral),
  `handwritten(_:bold:)` (Caveat), `stencil(_:bold:)` (Oswald),
  `monoLabel(_:)` (system .monospaced uppercase). Existing
  semantic aliases (`display`, `headline`, `subheadline`, `body`,
  `caption`, `label`) are bound to these new families.
- `SMRadius` flattened: 2/4/8/12 (was 8/12/16/20). Fusion is
  rectilinear paper-on-paper.
- **Fonts bundled** — 6 .ttf files (~1.3MB) at
  `SimmerSmith/SimmerSmith/Resources/Fonts/` (Instrument Serif
  Regular+Italic static, Spectral Regular+Italic static, Caveat
  variable, Oswald variable), registered via `UIAppFonts` in
  `Info.plist`, picked up automatically by xcodegen's recursive
  source walk. OFL attribution at `Resources/Fonts/LICENSE.txt`.
  PostScript names verified via `fc-scan`; the Caveat bold path
  uses `CaveatRoman-Bold` (the variable font ships its bold
  instance under that PostScript group, not as `Caveat-Bold`).

**Drawing primitives** (new
`SimmerSmith/SimmerSmith/DesignSystem/Components/FusionPrimitives.swift`,
~470L):
- `HandRule`, `HandUnderline`, `HandCheck` — squiggle Path views
  for paper-style dividers, hero underlines, and ingredient ticks.
- `Rivet`, `RivetCorners`, `.rivetCorners(...)` — riveted brass /
  iron corners on hero cards.
- `PaperGrain`, `PaperBackground`, `.paperBackground()` — linen
  dot-noise overlay; the standard root background of every Fusion
  screen body.
- `FuMark` — anvil + ember brand mark drawn in SwiftUI Canvas (no
  static asset). Themes with the system; ember glows in Dark Mode.
- `FuWordmark` — `simmer·smith` in Instrument Serif italic with
  ember dot, replaces the static `BrandLockup.imageset`.
- `FuHero` — in-content hero header (mono eyebrow + 38pt italic
  serif title + ember hand-drawn underline). System nav bar stays
  Liquid Glass on top; the FuHero is the visual anchor inside the
  scroll content.
- `FuPlate`, `FuIndexCard`, `FuWashiTape` — riveted forge plate,
  paper index card with optional washi-tape strip, washi tape
  primitive.
- `FuEmberCTA`, `FuOutlinedPill`, `FuEyebrow`, `FuRecipeNumber` —
  Caveat ember CTA, outlined-Caveat pill, mono uppercase eyebrow,
  `№003` recipe number badge.

**Components** (14 files in `DesignSystem/Components/`, public APIs
unchanged): paper backgrounds, 0.5pt rule borders, rectangular (not
rounded) edges, italic-serif titles, Caveat sub-lines, ember accents.
- `SMCard`: paperAlt fill, 0.5pt rule, soft shadow in light only.
- `CuisinePill`: outlined Caveat (no fill), slight rotation.
- `TimeBadge`: italic-serif numeral + Caveat unit.
- `RecipeCard` / `CompactRecipeCard`: paperAlt tile, mono `№NNN`
  badge, italic-serif title; alternating slight rotations on the
  grid version.
- `HeroRecipeCard`: large italic-serif title, hand-drawn ember
  underline.
- `RecipeListRow`: italic-serif title, Caveat meta, ember sparkle
  + ember heart (replacing the AI-purple sparkle).
- `MacroRing`: ink/ember/risoGreen/bronze macro accents (was
  primary/aiPurple/orange).
- `CompactMealCard`: paperAlt tile, italic-serif name, Caveat slot
  label; sides chips become outlined.
- `TodayMealCard`: index-card paper treatment with washi-tape +
  rivet corners + ◆ AT THE FORGE eyebrow + "fire up →" Caveat ember.
- `MealSlotRow`: Caveat slot, italic-serif name, italic placeholder.
- `DayCard`: italic-serif day name + ember underline; rows separated
  by hand rules (was solid divider).
- `AIFloatingButton`: solid ember disk with ember glow.

**Feature views** (in-content only — chrome stays native):
- `WeekView` (1381L): "this week" `FuHero` at top of scroll +
  `paperBackground()`. Today card + day cards inherit the new
  component look automatically.
- `RecipesView` (1071L): "the **forge**" hero with ember accent on
  "forge"; nav title flipped to "Forge"; `paperBackground()`.
- `RecipeDetailView` (1267L): `paperBackground()`; loading + empty
  states get italic-serif copy + ember tint. Removed
  `toolbarBackground(SMColor.surface, …)` so Liquid Glass takes
  over the nav bar.
- `GroceryView` + `PantryView`: `paperBackground()`; native List
  + Liquid Glass nav unchanged.
- `CookingModeView` (362L): forced forge dark regardless of system
  mode (`.preferredColorScheme(.dark)`), lamp-lit iron background
  + ember radial glow seeping from the bottom, **96pt Oswald
  stencil step number with ember glow** as the marquee element,
  Spectral 26pt italic instruction text.
- `AssistantView` (502L): nav title flipped to "Smith"; empty
  state replaced with `FuMark` + Caveat ember "at the anvil"
  eyebrow + italic-serif "draft a meal." headline.
- `EventsView` + `EventDetailView`: `paperBackground()`; removed
  `toolbarBackground(SMColor.surface, …)` so Liquid Glass takes
  over.
- `SignInView`: linen paper with ember radial glow from below,
  `FuMark` + `FuWordmark` brand lockup, "every recipe forged by
  hand." Caveat ember eyebrow, italic-serif "Cook with fire." hero,
  Spectral italic body copy, hand-drawn ember underline. Native
  Sign In with Apple + Google buttons retained.
- `SettingsView` (1358L): kept fully native `Form` per user
  instruction; `paperBackground()` swap. Settings gear stays
  native.
- `SubstitutionSheetView`: removed `toolbarBackground(...)`.

**Tab bar** (`MainTabView`):
- Recipes → **Forge**, Assistant → **Smith**. Other labels
  unchanged (Week / Grocery / Events).
- `.tint(SMColor.primary)` → `.tint(SMColor.ember)` (same value,
  clearer call site).
- Native SF Symbol icons preserved (calendar / book / cart /
  party.popper / sparkles).
- Liquid Glass tab bar chrome untouched per user instruction.

**Brand assets**:
- `AccentColor.colorset/Contents.json`: pointed at ember
  (`#E8541C`) so any unstyled native control inherits the new
  accent.
- `BrandMark.imageset` and `BrandLockup.imageset` retained on disk
  for legacy reference; onboarding now renders the wordmark in
  code via `FuWordmark`.

**Project / verification**:
- `SimmerSmith/project.yml`: `CURRENT_PROJECT_VERSION` 57 → 58.
- 325 backend tests pass (`pytest -q`).
- 26 SimmerSmithKit tests pass (`swift test`).
- `SimmerSmithTests` unit suite passes.
- `xcodebuild build` succeeds.
- 6 `SimmerSmithUITests` failures are pre-existing — they expect a
  ConnectionSetup form that only shows for signed-out users; the
  simulator has persisted Apple/Google sign-in. Not a regression.
- `testTabBarShowsAllMainTabs` passes after the Forge/Smith
  relabel.

**Out of scope** (explicit deferrals):
- App icon redesign (HANDOFF flagged the existing mark-only icon
  as off-center).
- Custom MealArt vector illustrations per cuisine — recipe photos
  / gradient placeholders retained.
- Heavy Forge variant (E2).
- Animation polish, transitions, motion.
- Localization audit for the new lowercase brand voice.

**Font sourcing — resolved**:
- User authorized fetching from `github.com/google/fonts`. Six
  .ttf files pulled directly from the official Google Fonts
  upstream repository (OFL-licensed, AGPL-compatible) and bundled
  into the app at `SimmerSmith/SimmerSmith/Resources/Fonts/`.
  Total bundle weight: ~1.3MB. Caveat + Oswald shipped as the
  upstream variable fonts; Instrument Serif + Spectral as static
  Regular + Italic instances.

---

**Date**: 2026-05-06 — Build 57 ship (quick meal tag + freezer pantry kind)

Two pieces of dogfood feedback bundled into one ship: a `quick`
meal tag for ≤30-minute weeknight recipes, and a freezer kind on
pantry items with leftover-from-meal capture + a "Use Soon"
staleness filter. One build, single dogfood pass.

**Backend** (one migration: `staples.frozen_at TIMESTAMPTZ NULL`):
- `app/models/profile.py`: `Staple.frozen_at: datetime | None`.
  NULL = regular pantry item; set = freezer item placed at this
  timestamp. No new model; the discriminator is the timestamp
  itself.
- `alembic/versions/20260506_0036_staple_frozen_at.py`: trivial
  `add_column` migration. No backfill — every existing row is
  implicitly non-frozen.
- `app/schemas/profile.py`: `PantryItemOut`/`AddRequest`/`PatchRequest`
  carry `frozen_at`. PATCH gets a `clear_frozen_at: bool` flag for
  un-freeze.
- `app/api/pantry.py`: `_payload` emits `frozen_at`. Add route now
  forwards `payload.categories` to the service (was a build-56 bug
  — categories were dropped when only the list field was sent on
  POST). Add route also forwards `frozen_at`.
- `app/services/pantry.py`: `add_pantry_item` / `update_pantry_item`
  accept `frozen_at`. Update path honors `clear_frozen_at` to wipe.
- `app/services/recipe_drafting.py`: prompt now instructs the AI
  to add `"quick"` to `tags` when `prep_minutes + cook_minutes ≤
  30`. Refine prompt re-evaluates after a tweak so a user request
  like "scale this down" can either earn or drop the tag.
- New tests: `tests/test_pantry.py` round-trips `frozen_at` +
  `clear_frozen_at`. `tests/test_recipe_quick_tag.py` verifies the
  prompt carries the rule, refine re-evaluates, and the API
  preserves the tag end-to-end. **325/325 pass** (was 321).

**iOS**:
- `SimmerSmithKit/.../Models/SimmerSmithModels.swift`: `PantryItem`
  gains `frozenAt: Date?` + helpers (`isFrozen`,
  `daysSinceFrozen`, `isStaleFreezerItem` ≥30d).
- API client `PantryItemAddBody.frozenAt`,
  `PantryItemPatchBody.frozenAt` + `clearFrozenAt` (the explicit
  un-freeze flag).
- `Features/Recipes/RecipesView.swift`: new "Quick (≤30 min)"
  filter pill alongside difficulty + cleanup. Predicate
  `tags.contains("quick") || (prep+cook ≤ 30)` with a `0+0=0`
  guard so untimed recipes don't false-positive.
- `Features/Week/RecipePickerSheet.swift`: same Quick chip on the
  week meal picker so a user picking dinner at 6pm can narrow
  fast.
- `Features/Grocery/PantryItemEditorSheet.swift`: new "Freezer
  item" toggle + date picker for `frozenAt`. Toggling on
  pre-selects the Freezer category chip. PATCH path emits the
  field that changed (`frozenAt` or `clearFrozenAt`).
- `Features/Grocery/PantryView.swift`: segmented filter (All /
  Pantry / Freezer / Use Soon). Freezer view sorts FIFO. Use Soon
  surfaces items frozen ≥30 days. Inline orange "Use soon" badge
  + a "Frozen Nd ago" line on every freezer row.
- `Features/Week/SaveLeftoversToFreezerSheet.swift` (new): small
  form opened from the meal action sheet ("Save leftovers to
  freezer"). Prefills `<recipe name> leftovers`, today's date,
  saves a freezer pantry item with `categories=["Freezer"]`.
  Always available — no gating on a mark-cooked flow.

**Build bump**: 56 → 57.

**Out of scope (deferred):** `WeekMeal.status` / mark-cooked flow,
quantity-on-hand for freezer items, per-item stale window
override, home-screen / assistant nudge for stale items, freezer
inventory in the AI meal planner.

### Earlier session (build 56 — pantry UX upgrade)

**Date**: 2026-05-05 — Build 56 ship (pantry UX: ingredient autocomplete + multi-select categories)

**Build 56** addresses dogfood feedback on the pantry editor: too
much free-text typing, no awareness of the existing ingredient
catalog, single-string category that didn't match real-world
multi-section items.

**Backend** (no migration — comma-joined storage on existing
`Staple.category` column):
- `app/services/pantry.py`: new `serialize_categories` and
  `parse_categories` helpers handle the round-trip between the
  list-shaped API surface and the legacy single-string column.
  `add_pantry_item` / `update_pantry_item` accept a `categories`
  list (wins over the legacy `category` string).
- `app/schemas/profile.py`: `PantryItemOut` now carries both
  `category: str` (back-compat) and `categories: list[str]`.
  `PantryItemAddRequest` + `PantryItemPatchRequest` accept the
  new list field.
- `app/api/pantry.py`: `_payload` derives `categories` from the
  stored string for every read.
- New test in `tests/test_pantry.py` round-trips the list +
  exercises the helpers' edge cases. 321/321 pass.
- `app/api/weeks.py`: imported missing `Settings` alongside
  `get_settings` (silent pyright fix; runtime worked because of
  `from __future__ import annotations`).

**iOS**:
- `SimmerSmithKit/.../Models/SimmerSmithModels.swift`: `PantryItem`
  gains `categories: [String]` + a `displayCategories` accessor
  that falls back to splitting the legacy single string. Custom
  decoder handles older cached payloads.
- API client `PantryItemAddBody` + `PantryItemPatchBody` carry the
  new `categories` field.
- `PantryItemEditorSheet`:
  - Name field now searches the household ingredient catalog after
    300 ms debounce. Tapping a suggestion prefills name + auto-
    selects the catalog row's category. Free-text input still
    works for one-off pantry items.
  - Replaced the single-line category field with a chip multi-
    picker. Defaults: Produce / Dairy / Meat / Seafood / Pantry /
    Freezer / Beverages / Condiments / Baking / Snacks / Spices.
    Merged with categories already in use across the household so
    custom values stick around. Inline "Add custom" affordance.

**Build bump**: 55 → 56. Backend has no migration — pure column
serialization change.

### Earlier session (build 55 / Fly v80 — multi-select + FAB removal)

**Build 55** absorbs build-54 dogfood UX feedback (FAB overlapping
recipe rows, no bulk-delete) AND lands the originally-planned
review-first refactor: web search, recipe variation, and recipe
companion drafts now route through `RecipeDraftReviewSheet` so they
inherit the refine loop introduced in build 53.

**iOS**:
- `Features/Recipes/RecipesView.swift`:
  - Removed the `AIFloatingButton` overlay; "AI suggestion" moved
    into the existing top-right `+` menu (next to "New recipe").
  - New "Select recipes" item in the same menu enters multi-select
    mode. Toolbar swaps to "Done" + "N selected"; rows render with
    a checkbox; bulk-action bar pinned to the bottom shows
    "Delete N" with a destructive confirmation dialog.
  - Web-search results now route through `RecipeDraftReviewSheet`
    (refine + edit before save).
- `Features/Recipes/RecipeDetailView.swift`: AI variation drafts +
  companion drafts both route through `RecipeDraftReviewSheet`.
  Same refine loop the side / event-meal / quick-add flows have.
- Bulk delete reuses `appState.deleteRecipe` per row + surfaces
  partial failures via `lastErrorMessage`. Selection persists for
  the failed entries so the user can retry.

**Build bump**: 54 → 55. No backend changes (pure iOS surfaces).

**Pause for dogfood after build 55.** Build 56 candidates:
- Assistant `recipe_draft` envelope routing through review sheet.
- More bulk operations (favorite, archive, move to week).
- Polish from 55 dogfood findings.

### Earlier session (build 54 / Fly v80 — M29 dogfood fixes + AI cleanup filters)

**Build 54** addresses TestFlight 53 feedback (intermittent "invalid
JSON" on AI gen, slow Save, no way to find AI-generated slop, stuck
Delete) and adds the AI cleanup-filter UI. Originally planned scope
(routing existing review-first surfaces through `RecipeDraftReviewSheet`)
deferred to build 55 since they don't auto-save anyway — feedback
items took priority.

**Backend**:
- `app/services/recipe_drafting.py`: new `_provider_call_with_json_retry`
  helper. Both `generate_recipe_draft_for_dish` and
  `refine_recipe_draft` now retry once on `JSONDecodeError` with a
  tightened "Return ONLY the JSON object — no markdown fences"
  reminder before raising 502. Catches the dogfood case where the
  LLM occasionally wraps its response in fences.
- New test `test_refine_route_retries_invalid_json_once` in
  `tests/test_recipe_draft_refine.py`. 320/320 pass.

**iOS**:
- `AppState+Recipes.swift`: `saveRecipe` no longer awaits the
  metadata refresh — that's now a fire-and-forget Task. Halves
  the perceived latency of the Save tap. `deleteRecipe` now pulls
  a fresh server list right after the 204 lands so a stale local
  cache can't show a deleted recipe.
- `RecipeDraftReviewSheet.swift`: tap-to-Save dismisses the sheet
  IMMEDIATELY and runs the save chain in a follow-up Task. Errors
  surface via `appState.lastErrorMessage`.
- `DesignSystem/Components/RecipeListRow.swift`: AI badge
  (sparkles, purple) on rows whose `source` starts with `ai`.
- `Features/Recipes/RecipesView.swift`: new `cleanupFilterPills`
  row with 4 chips: All / AI-generated / Never used / Unused 30+
  days. When active, swaps editorial sections for a flat list
  sorted least-recently-used first. New `RecipeCleanupFilter` enum.

**Build bump**: 53 → 54.

**Pause for dogfood after build 54.** Build 55 will route the
remaining review-first surfaces (web search, recipe variation,
recipe companion) through `RecipeDraftReviewSheet` to give them
the refine loop, plus assistant `recipe_draft` envelope refactor
+ polish from 54 dogfood findings.

### Earlier session (build 53 / Fly v79 — M29 review-before-commit + side AI gen)

**Build 53** opens the M29 milestone (3-build cadence). Solves the
"AI slop" problem: pre-build-53 the event-meal AI gen and quick-add
AI gen both auto-saved every draft into the recipes library, so a
user iterating 3-5 times to get the right recipe ended up with 3-5
abandoned recipes. Build 53 introduces a single review funnel +
adds the previously-missing side-recipe AI generation.

**Backend**:
- New `app/services/recipe_drafting.py` — `generate_recipe_draft_for_dish`
  (generic per-dish helper, used by event + side routes) and
  `refine_recipe_draft` (the engine of the iOS refine loop). Reuses
  M27 `unit_system_directive` + assistant_ai's `extract_json_object`
  + `run_direct_provider`. **No DB writes anywhere in the loop.**
- New `POST /api/recipes/draft/refine` route in `app/api/recipes.py`.
  Body: `{draft, prompt, context_hint}` → returns refined `RecipePayload`.
- New `POST /api/weeks/{w}/meals/{m}/sides/{s}/ai-recipe` in
  `app/api/weeks.py`. Returns a draft scaled to the parent meal's
  servings.
- `event_ai.generate_recipe_for_meal` slimmed to a thin wrapper
  around the shared helper so the per-dish event flow goes through
  the same plumbing.
- Tests: `tests/test_recipe_draft_refine.py` (3 cases) +
  `tests/test_side_ai_recipe.py` (2 cases). Existing event-recipe
  test patched to also stub `recipe_drafting.run_direct_provider`.
  321/321 backend tests pass.

**iOS**:
- New `Features/Recipes/RecipeDraftReviewSheet.swift` — the single
  funnel. Init takes `initialDraft` + `refineContextHint` + `onSave`
  + optional `onDiscard`. Surfaces a draft summary, a "Refine with
  AI" prompt+button (with iteration counter footer "refined N
  times · nothing saved yet"), an "Edit by hand" path that opens
  `RecipeEditorView`, and Save/Discard buttons. Save is the ONLY
  persistence path.
- `EventMealEditorSheet.swift` — `generateRecipeWithAI` no longer
  auto-saves. Sets a `pendingDraft` state and presents the review
  sheet; `onSave` runs the existing PATCH-event-meal link.
- `AIRecipeCreateSheet.swift` (Week quick-add AI) — rewritten as a
  thin generation shell that hands off to the review sheet. Save
  button removed; the review sheet's onSave forwards to the
  caller's `onSaved`.
- `MealSidesSheet.swift` (the inline `SideEditorSheet`) — new
  "Generate recipe with AI" section in the side editor. Hint
  TextField + button → calls
  `apiClient.generateSideRecipeDraft` → review sheet → on save,
  PATCHes the side's `recipeId`. Closes the M26 follow-up gap.
- New API client methods: `generateSideRecipeDraft`,
  `refineRecipeDraft`. New AppState helper `refineRecipeDraft`.
- `RecipeDraft` declared `Identifiable` (id derived from recipeId
  ?? name) so `.sheet(item:)` works for in-flight drafts.

**Build bump**: 52 → 53.

**Pause for dogfood after build 53.** Build 54 will route the
existing review-first surfaces (web search, variation drafts,
companion drafts) through `RecipeDraftReviewSheet` to give them
the refine loop. Build 55 wires the assistant `recipe_draft`
envelope through the same funnel + polish from 53/54 dogfood.

### Earlier session (build 52 / Fly v78 — M28 phase 2 event pantry supplements)

**Build 52** completes the M28 pantry feature. Phase 1 (build 51)
added the recurring fold-in. Phase 2 lets events request
supplemental quantities of pantry items beyond normal household
stock — e.g. "we usually keep 5 dozen eggs, but this party needs
100 extra."

- `alembic/versions/20260505_0035_event_pantry_supplements.py`:
  new `event_pantry_supplements` table with FK cascades from both
  `events` and `staples`. Unique on `(event_id, pantry_item_id)`
  so one supplement per pantry item per event.
- `EventPantrySupplement` model + `Event.pantry_supplements`
  relationship.
- `app/services/event_supplements.py` (new): CRUD by id with the
  duplicate-by-pantry-item guard.
- `app/services/event_grocery.py:_aggregate_event_rows` extended:
  bypasses the staple filter for supplements (the whole point —
  the user explicitly said "extra of this pantry item"),
  attributes via `source_meals="pantry-supplement:<id>"`.
- `app/api/events.py`: GET/POST/PATCH/DELETE supplement routes.
  Each mutation re-runs `regenerate_event_grocery` +
  `apply_auto_merge_policy` so the linked week's grocery list
  reflects the change as `event_quantity`.
- `EventOut` schema + presenter expose `pantry_supplements`.
- 6 new backend tests in `tests/test_event_supplements.py`. 314
  total backend tests pass.

**iOS**:
- `EventPantrySupplement` model + `Event.pantrySupplements`.
- 3 new API client methods (add/patch/delete) returning the
  refreshed Event.
- AppState helpers in `AppState+Events.swift`.
- `EventDetailView` gets a "Pantry supplements" section between
  Menu and Guests-bringing.
- `EventPantrySupplementSheet` for add/edit/delete; pantry item
  picker excludes items that already have a supplement on the
  event.

**End-to-end behavior**: user has Eggs in pantry with a 60-ct
weekly recurring. Adds an event "Easter Brunch" with a +100 eggs
supplement. The week's grocery list shows a single Eggs row:
`total_quantity = 60` (recurring restock) + `event_quantity =
100` (supplement) — user sees `160 ct` total with a "+100 from
Easter Brunch" attribution.

**Build bump**: 51 → 52.

### Earlier session (build 51 / Fly v77 — M28 phase 1 pantry extension)

**Build 51** extends the existing `staples` table into a full pantry
concept. Pre-M28, staples already filtered from meal-driven grocery
aggregation ("we always have eggs, don't add them to grocery just
because a meal needs them"). M28 adds two more capabilities:

- **Typical purchase quantity**: informational metadata on how the
  household buys an item (e.g. "50 lb bag of flour"). Surfaced on
  the pantry editor; doesn't change grocery quantities.
- **Recurring auto-add**: each pantry item can carry an optional
  cadence (`weekly` / `biweekly` / `monthly`) + quantity + unit.
  When set, `apply_pantry_recurrings` folds it into the week's
  grocery list as a `user_added` row. The function is idempotent
  (matches by `pantry:recurring:<id>` source marker) and respects
  the cadence gap via `last_applied_at`. It also runs at the tail
  of `regenerate_grocery_for_week` so any regen brings recurrings
  current.

**Backend**:
- `alembic/versions/20260505_0034_pantry_columns.py` adds 7
  columns to `staples`: `typical_quantity`, `typical_unit`,
  `recurring_quantity`, `recurring_unit`, `recurring_cadence`,
  `category`, `last_applied_at`.
- `app/models/profile.py:Staple` gets the new fields + a docstring
  rebrand explaining the pantry vs. pure-staple split.
- `app/services/pantry.py` (new): `add_pantry_item`,
  `update_pantry_item`, `delete_pantry_item`,
  `apply_pantry_recurrings`, `_is_due` cadence resolver.
- `app/api/pantry.py` (new): GET/POST/PATCH/DELETE `/api/pantry`
  + `POST /api/pantry/apply/{week_id}`. PATCH-by-id flow keeps
  recurring metadata across partial saves; the legacy
  `PUT /api/profile` staple flow still works for simple edits.
- `app/services/grocery.py:regenerate_grocery_for_week` now calls
  `apply_pantry_recurrings` after smart-merge.
- Tests: `tests/test_pantry.py` (6 cases — recurring lands,
  idempotent, cadence gap, regen integration, partial update,
  staple-filter regression). 308/308 backend pass.

**iOS**:
- `PantryItem` model in SimmerSmithKit + 5 API client methods.
- `AppState.pantryItems` state + `AppState+Pantry.swift` helpers
  (load/add/patch/delete + applyToCurrentWeek).
- `Features/Grocery/PantryView.swift` reachable from Grocery →
  ⋯ menu → "Pantry". Lists items with cadence badges, supports
  swipe-to-delete + manual "Apply recurrings to this week"
  button.
- `Features/Grocery/PantryItemEditorSheet.swift` — name +
  category + active toggle + typical-purchase qty/unit +
  recurring cadence picker + recurring qty/unit + notes.

**Build bump**: 50 → 51.

**Out of scope for phase 1, follows in phase 2**: event
supplemental override (e.g. event needs 100 eggs, supplement the
recurring pantry stock by N for that event).

### Earlier session (build 50 / Fly v76 — M27 unit-system localization)

**Build 50** adds a per-user `unit_system` profile setting (`us` |
`metric`, default `us`) that constrains every recipe-producing AI
prompt to one unit system. Drift was unconstrained before — the AI
mixed cups + grams in the same recipe.

- `app/services/ai.py` — `unit_system()` + `unit_system_directive()`
  helpers. The directive is a top-of-prompt instruction
  (`UNIT SYSTEM — US CUSTOMARY ONLY` / `UNIT SYSTEM — METRIC ONLY`)
  that enumerates the allowed units (cups/tbsp/oz/lb/°F vs g/ml/°C)
  and tells the AI to convert from imported sources before
  responding.
- Injected into the high-traffic recipe surfaces:
  - `week_planner._build_system_prompt` (whole-week plan)
  - `event_ai._build_prompt` (whole-event menu)
  - `event_ai._build_per_dish_prompt` (M26 Phase 4 per-dish)
  - `recipe_search_ai._build_input` (find a recipe via web search)
  - `substitution_ai._build_prompt`
  - `assistant_ai.build_planning_system_prompt` + `build_assistant_prompt`
- `app/services/bootstrap.py:DEFAULT_PROFILE_SETTINGS` adds
  `unit_system: "us"` so every new household starts on US customary
  by default; legacy users without the row inherit `"us"`.
- iOS: `AppState.unitSystemDraft` + `saveUnitSystem` / `syncUnitSystemDraft`
  helpers (M17 image-provider pattern). Settings → AI → Recipe
  units picker writes via `PUT /api/profile`.
- Tests: `tests/test_unit_system.py` (6 cases — defaults, normalize,
  directive content, week-planner injection, per-dish injection).
  302/302 backend pass.

**Build bump**: 49 → 50. Backend has no migrations — pure prompt
+ profile-setting change. Fly deploy + TestFlight build 50 follow.

### Earlier session (build 49 / Fly v75 — M26 Savanne dogfood, all 5 phases)

**Build 49** bundles M26 phases 1–5 in one TestFlight slice:

- **Phase 1 — Meal-card word wrap**: dropped `.lineLimit` on
  `CompactMealCard` + `TodayMealCard` recipe-name text; HStack
  switched to `alignment: .top` so slot label + checkmark stay
  pinned to the first line of a wrapped title.
- **Phase 2 — Sides on a meal**: new `week_meal_sides` table
  (migration `0032`); `WeekMealSide` model + cascade-delete
  relationship; `app/services/sides.py` (add/update/delete + auto
  grocery regen); REST endpoints under
  `/api/weeks/{w}/meals/{m}/sides`. Grocery aggregation in
  `build_grocery_rows_for_week` walks each meal's sides and folds
  recipe-linked sides into the grocery list scaled by the parent
  meal's `scale_multiplier`. iOS: `WeekMealSide` model, API client
  methods, `MealSidesSheet` reachable from the meal action sheet's
  "Manage Sides" item, side pills below the recipe name on both
  card variants. 5 new tests passing.
- **Phase 3 — Per-household shorthand dictionary**: new
  `household_term_aliases` table (migration `0033`);
  `app/services/aliases.py` (case-normalized term, household-scoped
  upsert); `app/api/aliases.py` GET/POST/DELETE; `gather_planning_context`
  + `_planning_context_text` inject the alias map as a "treat term
  X as expansion Y" preamble in both planner and assistant prompts.
  iOS: `HouseholdTermAlias` model, API client, AppState helpers,
  `HouseholdAliasesView` reachable from Settings → AI → Custom
  terms. 6 new tests passing.
- **Phase 4 — Event dish recipe linking + AI gen**:
  `event_ai.generate_recipe_for_meal` per-dish helper extracted
  from the existing menu pipeline; new `POST /api/events/{e}/meals/{m}/ai-recipe`
  returns a `RecipePayload` draft (no DB persist — human-in-loop).
  iOS: `generateEventMealRecipe` API method, "Generate recipe with
  AI" section in `EventMealEditorSheet` that calls the route, saves
  the draft as a Recipe, links it to the event meal. 3 new tests
  passing.
- **Phase 5 — AI dry-run confirm for swaps**: `_run_swap_meal` no
  longer mutates — returns a structured `proposed_change` payload
  in `AssistantToolResult.data`. Two new tools `confirm_swap_meal`
  (applies) and `cancel_swap_meal` (no-op ack). Tool descriptions
  teach the LLM the propose-then-confirm pattern. iOS: new
  `ProposedChangeCard` rendered inside `AssistantToolCallCard` when
  the tool result carries a `proposed_change` payload — Was/Becomes
  diff with Confirm/Cancel buttons that send follow-up assistant
  messages so the LLM dispatches the apply/cancel tool. 3 new
  tests passing.

**Test status**: backend `pytest -q` 296/296 (290 pre-M26 + 5 sides
+ 6 aliases + 3 event recipe + 3 dry-run minus 1 retired). iOS
build green on `Seedkeep iPhone` simulator.

**Build bump**: `CURRENT_PROJECT_VERSION` 48 → 49. Backend has new
migrations `0032` (week_meal_sides) + `0033` (household_term_aliases)
ready for `fly deploy`.

### Earlier sessions (build 35 → 48: M22.5 / M23 / M24 / M25)

**M22.5 + diagnostics hotfix** addresses build-35 dogfood:

- **M22.5 — sync feedback now actually surfaces**: the
  `reminderListIdentifier`, `lastReminderSyncAt`,
  `lastReminderSyncSummary` were UserDefaults-backed computed
  properties on `AppState`. `@Observable` only tracks stored
  properties, so SwiftUI never re-rendered when those changed —
  Settings → Grocery looked frozen after every Sync now tap. Moved
  to true stored properties on `AppState`, hydrated in
  `loadCachedData()` via new `loadReminderState()`, and persist
  to UserDefaults as a side effect.
- **API error context**: when the server returns 4xx/5xx, the iOS
  error now appends `[404 /api/path]` so a generic `"Not Found"`
  banner tells us which endpoint actually 404'd. (Build 35 surfaced
  a bare `"Not Found"` with no path; impossible to debug.)
- **Stale-error clear on Sync now**: tapping the manual sync button
  clears `lastErrorMessage` so a previous unrelated error doesn't
  masquerade as a sync failure.
- **Build 35 → 36**, TestFlight upload follows.

### Earlier same day (build 35)

**M22.3 + M22.4 + M23 hotfix** addresses dogfood feedback:

- **M22.3 — Reminders sync visibility**:
  - Each reminder now commits individually (`commit: true` per save).
    The previous batched `commit: false` + final `eventStore.commit()`
    pattern silently lost writes on iOS 26 in dogfood (sync said
    success, list stayed empty).
  - `upsertReminders` returns `(created, updated)` counts.
  - `syncGroceryToReminders` logs a human-readable summary via
    `lastReminderSyncSummary` ("Synced 12 items (12 created, 0
    updated).") and surfaces failures via `lastErrorMessage`.
  - Settings → Grocery now shows the summary plus a manual "Sync now"
    button so the user can retry without flipping the toggle.
- **M22.4 — auto-merge toggle hoisted**:
  - The toggle was inside `grocerySection` which only rendered when
    the event already had grocery items. Moved into a standalone
    `autoMergeRow` that's always visible on event detail (between
    attendees and Generate menu).
- **M23 hotfix — uv-native skill, no `.venv` ceremony**:
  - SKILL.md + README.md updated to use
    `uv run --project ~/.claude/skills/simmersmith-shopping ...`. uv
    reads `pyproject.toml` and manages the env transparently; no
    activation, no `.venv/bin/python`.
  - `cli.py` auto-installs Playwright Chromium on first browser-
    driving call so users don't need to remember `playwright install`.
  - `setup.sh` is now optional (just pre-warms cache + symlinks).
  - PyXA optional dep dropped — its PyPI release is stale; osascript
    fallback works on every Mac without extras.
- **Build 34 → 35**, deploy + TestFlight follows.

### Earlier same day (M22.1 + M22.2 + M23 ship — build 34)

**M22.1 + M22.2 limitation fixes + M23 skill scaffolding** shipped:

- **M22.1 — background Reminders sync**: new
  `SimmerSmith/Services/BackgroundSyncService.swift` registers a
  `BGAppRefreshTaskRequest` (identifier `app.simmersmith.ios.grocerySync`).
  iOS now wakes the app periodically to pull Reminders deltas back to
  the server even while it's backgrounded. `Info.plist` gains
  `BGTaskSchedulerPermittedIdentifiers` and `fetch` + `processing`
  background modes.
- **M22.2 — track event_quantity separately**: new
  `grocery_items.event_quantity` column +
  `alembic/versions/20260503_0029_grocery_event_quantity.py`.
  `merge_event_into_week` now writes the event delta into
  `event_quantity` instead of bumping `total_quantity`. Smart-merge
  regen can refresh `total_quantity` (week-meal portion) without
  disturbing the event contribution. iOS's `effectiveQuantity` sums
  the two for display. `_match_keys` now indexes by both base-id and
  normalized-name so a catalog-resolved week row still matches a
  name-only event row. New backend test
  `test_event_merge_uses_event_quantity_column`. 272 backend tests pass.
- **M23 — cart-automation skill scaffolding**:
  `skills/simmersmith-shopping/`. Full Python package:
  - `SKILL.md` + `README.md` for Claude Code discovery + setup.
  - `setup.sh` creates `.venv`, installs deps, runs `playwright
    install`, symlinks into `~/.claude/skills/`.
  - `parser.py` — permissive `<qty> <unit> <name>` parser handling
    fractions ("1 1/2 cups") and multi-word units ("fl oz").
  - `reminders.py` — PyXA + osascript fallback for reading the
    SimmerSmith Reminders list.
  - `splitter.py` — greedy + 2-store-combination heuristic
    minimizing cost subject to per-store delivery minimums and a
    configurable max-stops cap.
  - `stores/aldi.py` + `stores/walmart.py` — concrete Playwright
    drivers with real selectors. `stores/sams_club.py` +
    `stores/instacart.py` — login-only stubs the user fills in
    after the first interactive login captures cookies.
  - `cli.py` — orchestrator with `login --store X` (interactive
    cookie capture), `--dry-run` (synthesize prices for splitter
    verification), and the full Reminders → split → cart-fill
    pipeline.
  - 8 smoke tests pass (parser + splitter, no Playwright deps).
- **Build 33 → 34**, deploy + TestFlight to follow.

### Earlier same day (M22 ship)

**M22 Grocery list polish + Apple Reminders sync** shipped end-to-end:
- Phase 1 — schema + smart-merge regen + 5 mutation routes + 11 new
  backend tests (271 total pass).
  - `grocery_items` extended with 8 mutability fields
    (`is_user_added`, `is_user_removed`, `quantity_override`,
    `unit_override`, `notes_override`, `is_checked`, `checked_at`,
    `checked_by_user_id`) and `events.auto_merge_grocery`.
  - Smart-merge regeneration replaces the old wipe-rebuild — user
    edits, household-shared check state, and event-merge attribution
    survive meal changes.
  - 5 new routes under `/api/weeks/{id}/grocery/...`:
    POST `/items`, PATCH `/items/{id}`, POST/DELETE `/items/{id}/check`,
    GET `/grocery?since=ISO8601` (delta endpoint for Reminders sync).
  - Per-event `auto_merge_grocery` toggle wired through
    `apply_auto_merge_policy` so events fold into the week
    automatically when the toggle is on.
- Phase 2 — iOS surfaces.
  - SimmerSmithKit: `GroceryItem` extended with mutability fields +
    `effectiveQuantity/Unit/Notes` accessors. New `GroceryListDelta`
    response model. `Event` carries `autoMergeGrocery`.
  - 6 new API client methods + Sendable patch-body builders.
  - `AppState+Grocery.swift` (add/edit/remove/restore + local
    mirror helpers) and `AppState+Reminders.swift` (push and pull
    direction sync).
  - `RemindersService.swift` + `GroceryReminderMapping.swift`
    (per-device JSON store of grocery_item_id ↔ EKReminder
    calendarItemIdentifier).
  - 5th tab wired (`AppState.MainTab.grocery` was scaffolded but
    unwired before M22). `GroceryTabView` + editable `GroceryView`
    (swipe to remove, tap to edit, "+" toolbar to add).
  - `AddGroceryItemSheet`, `GroceryItemEditSheet`,
    `ReminderListPickerSheet`.
  - Settings → Grocery section with two-way sync toggle + list
    picker. EventDetailView has the auto-merge toggle.
  - `Info.plist` adds `NSRemindersUsageDescription` +
    `NSRemindersFullAccessUsageDescription`. No new entitlement.
  - Sign-out clears the per-device Reminders mappings via
    `clearReminderMappings()` from `resetConnection`.
- Phase 3 — durable design notes for the future M23 cart-automation
  skill (Aldi / Walmart / Sam's Club / Instacart) appended to
  `.docs/ai/decisions.md`. Roadmap updated.
- Phase 4 — `CURRENT_PROJECT_VERSION` 32 → 33. Commit + Fly deploy +
  TestFlight build 33 to follow.

**Test status**: backend `pytest -q` 271/271 (260 pre-M22 + 11 new
grocery edits). SimmerSmithKit `swift test` 26/26. iOS build green
on `generic/platform=iOS Simulator`.

### Previous session (2026-05-01)

**M21 Household sharing** shipped end-to-end across 5 phases:
- Phase 1 (commit `edf9a0f`) — schema: `households`, `household_members`,
  `household_invitations`, `household_settings` tables. `household_id`
  column on Week / Recipe / Staple / Event / Guest, backfilled.
- Phase 2 (commit `eff6e8f`) — service rewrite + auth: `CurrentUser`
  carries `household_id` (lazy-create for legacy users); every shared-
  table query flips from `user_id` to `household_id`; writers populate
  `household_id` on construct; per-user data (DietaryGoal,
  IngredientPreference, PushDevice, etc.) intentionally stays user-scoped.
- Phase 3 (commit `c50c6ce`) — invitation API + tests: 5 routes (GET
  household, PUT name, POST/DELETE invitations, POST join). Auto-merge
  on join: joiner's solo content (recipes, weeks, staples, events,
  guests) is re-pointed to the target household; the empty solo is
  deleted. 12 new tests covering owner-only checks, expiry, single-use
  consume, cross-member visibility, per-user push isolation.
- Phase 4 (commit `0dbe4a4`) — iOS surfaces: `HouseholdSnapshot` model +
  5 API client methods + `AppState+Household.swift` + new
  `InvitationSheet` (display + ShareLink) + `JoinHouseholdSheet` +
  `HouseholdSection` in Settings (between Sync and AI). Owner sees
  editable name + member list + invite button + active codes with
  Revoke. Solo households see "Join a household".
- Phase 5 — build bump 31→32, push, deploy, TestFlight 32. (in flight)

**Test status**: backend `pytest -q` 260/260 (248 pre-M21 + 12 new
household-API tests). SimmerSmithKit `swift test` 26/26. iOS build
green on `generic/platform=iOS Simulator`.

### Previous session (2026-04-30)

Three milestones shipped end-to-end:

- **M17.1 Image-gen cost telemetry** — per-call `image_gen_usage` rows,
  30-day Settings rollup, admin `GET /api/admin/image-usage` behind the
  legacy bearer. Backend deployed to Fly v58. Commit `13e2a97`.
- **M18 Push Notifications** — APNs device registration + in-process
  APScheduler + iOS Settings toggles (default ON). User set the four
  `SIMMERSMITH_APNS_*` Fly secrets using the existing
  `AuthKey_46NXHV5UB8.p8` Apple Developer key (covers both APNs and Sign
  In with Apple). Backend deployed to Fly v58. TestFlight build 28
  uploaded; on-device validation pending. Commit `86f738c`.
- **M19 / M7 Phase 5 Anthropic tool-use** — Refactored
  `_run_openai_tool_loop` into a provider-agnostic
  `_run_provider_tool_loop` driven by a `ProviderAdapter` ABC with
  `OpenAIAdapter` and `AnthropicAdapter` implementations. Anthropic
  planning threads now run the same 11 tools the OpenAI path runs;
  `assistant.tool_call`, `assistant.tool_result`, and `week.updated`
  SSE events fire identically. 7 new tests (1 schema parity + 6
  Anthropic-loop). Uncommitted at session end.

### What landed this session (M18, Phases 1-4)

**Backend**
- `pyproject.toml` — added `aioapns>=3.2`, `apscheduler>=3.10`
- `app/config.py` — added 6 APNs/scheduler settings
- `app/models/push.py` (new) — `PushDevice` SQLAlchemy model
- `app/models/__init__.py` — exported `PushDevice`
- `alembic/versions/20260430_0025_push_devices.py` (new) — `push_devices` table
- `app/services/push_apns.py` (new) — `APNsSender`, `send_push`, `is_apns_configured`
- `app/services/push_scheduler.py` (new) — `start_scheduler`, `_tick_tonights_meal`,
  `_tick_saturday_plan` with injected `now_local` callable for tests
- `app/services/bootstrap.py` — added 4 push default rows to `DEFAULT_PROFILE_SETTINGS`
- `app/services/ai.py` — added `apns_device_token` to `AI_SECRET_KEYS`
- `app/api/push.py` (new) — `POST /push/devices`, `DELETE /push/devices/{token}`,
  `POST /push/test`
- `app/main.py` — wired push router + scheduler lifespan

**Tests** (`tests/test_push.py`, +18)
- Device register/upsert/unregister round-trips
- `send_push` honours `disabled_at`, marks 410 Unregistered
- Scheduler fires at matching time, skips outside window, respects quiet hours
- Toggle-off (`value=='0'`) suppresses push
- Default-on semantics (no rows = enabled)
- Saturday tick skips approved week, fires for draft/no-week

**iOS**
- `SimmerSmith/SimmerSmith/Services/PushService.swift` (new) — APNs registration + notification dispatch
- `SimmerSmith/SimmerSmith/App/SimmerSmithAppDelegate.swift` (new) — UIApplicationDelegate adapter
- `SimmerSmith/SimmerSmith/App/SimmerSmithApp.swift` — `@UIApplicationDelegateAdaptor`
- `SimmerSmith/SimmerSmith/App/AppState+Push.swift` (new) — push drafts + `savePushPreference` + `ensurePushBootstrap`
- `SimmerSmith/SimmerSmith/App/AppState.swift` — wired `ensurePushBootstrap()` after `syncImageProviderDraft`
- `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift` — `NotificationsSection` added
- `SimmerSmith/project.yml` — `CURRENT_PROJECT_VERSION` 27 → 28
- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift` — `registerPushDevice` + `unregisterPushDevice`

**Infra**
- `tests/conftest.py` — `SIMMERSMITH_PUSH_SCHEDULER_ENABLED=false` so APScheduler never spawns in pytest

### Production state (mid-session)

- **Fly secrets**: All four `SIMMERSMITH_APNS_*` vars set this session
  (`TEAM_ID=K7CBQW6MPG`, `KEY_ID=46NXHV5UB8`, `PRIVATE_KEY_PEM` from the
  existing `AuthKey_46NXHV5UB8.p8`, `TOPIC=app.simmersmith.ios`).
- **Backend image deployed**: Fly v58 carries M17 + M18 + M17.1. M19
  uncommitted, undeployed at session end.
- **TestFlight**: build 28 uploaded (M18 surface). On-device validation
  of M18 push toggles + auto-permission-prompt + `POST /api/push/test`
  is pending the user installing build 28.

### Build status

- Backend: pytest **242/242** pass (29 new this session: 18 push +
  20 telemetry + 1 schema parity + 6 Anthropic + minus 16 covered by
  existing tests' updates). Ruff clean on all touched files.
- Swift tests: 26/26 pass.
- iOS build: green on `generic/platform=iOS Simulator`.

### Previous session

M17 (Gemini-direct image-gen per-user toggle) shipped end-to-end in
commit `51d6120`. M16, M15 detail in earlier sessions.

## Blockers

Three loose ends, all user-driven:
1. **M19 uncommitted** — `app/services/assistant_ai.py`,
   `tests/test_assistant_anthropic_tools.py`,
   `tests/test_assistant_tools.py`, plus a few doc updates. Commit +
   `fly deploy` when ready (no migration, no iOS work).
2. **TestFlight 28 device validation** for M18 push notifications —
   install + sign in + accept the auto-fired permission prompt + run
   the `POST /api/push/test` curl smoke test.
3. **Anthropic dogfooding for M19** — Settings → AI provider toggle
   → switch to Anthropic → planning thread tool-use parity check.
