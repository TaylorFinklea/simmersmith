# Architecture + product-truth audit — 2026-07-14 (Fable, report)

Owner-directed audit: "find issues, populate the backlog, set direction." Owner priorities captured same day: **depth + stability before submission · ~4-6 weeks · monetization decided after audit · pain = data trust, AI quality, assistant capability, daily friction, slow cold start (write-in).**

## Method

- 5 Sonnet-5 discovery agents (CloudKit data plane / app layer + lifecycle / AI layer / product-truth census (~200 affordances, 8 sub-agents) / quality infra), read-only, structured output with file:line evidence.
- Lead (Fable) direct read of the core: HouseholdSyncEngine, HouseholdLocalStore, HouseholdSession, RepairScheduler(head), AppState, AppState+Recipes boot path, WeekRepository, ToolRegistry, AppState+Assistant, AssistantSystemPrompt + targeted verifies of every P1/P2 claim.
- Adversarial peer panel via `pi -p` (pre-digested, read-only, no tools — the mode with the 5/5 track record; tool-loop dispatch deliberately avoided): **gpt-5.6-terra** (data plane, 111KB packet), **glm-5.2** (lifecycle + tool loop, 145KB), **gpt-5.6-sol** (architecture + direction, max reasoning). All runs scorecard-logged.
- Every filed finding was verified against source by the Lead; refuted claims recorded below so they don't get re-filed.

## Verified findings → beads

P1: `deh` debug Phase-1 check destroys real private-plane data (TestFlight-reachable) · `48y` assistant context-blind + allergy-gate bypass (+grocery_get fallback) · `dkj` stale send-ack erases newer local edit · `e0a` (promoted) cold start = token deleted every launch + `.ready` blocks on full fetch + 10 reloads.

P2: `t6t` cleared fields resurrect on rebase · `f0s` syncAttendees deletes concurrent adds + eventAttendee lacks updatedAt · `91e` migration loaders drop data then stamp receipts (live via factory-reset) · `7in` epoch guards missing on boot-path interiors (folds v89+bnh, both closed) · `7o2` Recipe Pairings dead-Fly (missed by all prior inventories; replacement already built) · `l4i` nutrition UI asserts false red Drift verdicts (macros structurally nil) · `akv` three ported features hidden behind stale gates (nutrition estimate/scanner/substitutions) · `xwb` image affordances burn AI spend, header never renders photos · `iow` cook timers complete silently · `kby` Settings truth sweep (decorative toggle, dead AI Usage, dual notifications cross-cancel) · `eig` (promoted) world-joinable debug share verified.

P3 (selection): `b53` zone/status hardening · `uns` classifyFailure refinements · `2g1` unbounded assistant context · `2uk` truncation detection · `dds` Test-Key error formatter · `57d` stale tool-card names · `blv` seasonalCache cross-account · `44i` try! crash shapes · `8qy` repo full-rescan efficiency · `5fm` release ASC poll · `5f4` empty-state dead-ends · `9ph` events polish · `dac` dead surfaces (Activity/prices/difficulty/voice-stub) · `99b` error routing · `55f`/`6bz` cleanup chores.

Existing beads updated with mechanisms/scope: gd5, yqm, hwi, 44q, 1sz, 990.8, 2d1, zyp, 969, 5eq, vwq, 4ii (3 entry points; recommend hide), 32i (NOT silent — visible nonsense error), lwi (confirmed), fbn (recommend remove), 80s (sort also dead). Promoted: e0a→P1, z69.1/.2/.3→P2 (testability track pulled forward), eig→P2.

## Refuted / do-not-refile

- Fast-path teardown resurrection in `ensureHouseholdSession` — impossible (MainActor-synchronous; GLM). Replaced by the smaller premature-`.ready` wart (in `7in`).
- Same-turn `weeksUpdateMeals` baseline race — refuted: engine executes tool calls sequentially (AssistantEngine.swift:326) and `saveWeekMeals` reloads synchronously.
- "DEAD-FLY calls are silent no-ops" — wrong for the two survivors: `buildRequest` throws `missingServerURL` → visible (nonsense) error. True silent no-ops exist only on already-invisible surfaces.
- GLM's "fresh users never boot" (G1) — wrong (launch calls `ensureHouseholdSession` directly); kept only as the 990.8 entanglement note.
- `deleteCascading` "server doesn't cascade" comment premise — `.deleteSelf` IS server-side cascade; client sweep is UX cover (comment fix in `6bz`).
- 9wr framing: the app itself has ZERO production PUBLIC writes — the grant revoke protects against other clients, still worth the Dashboard op, not code-blocked.

## Stale docs corrected by this audit

- `phases/fly-call-inventory.md` (2026-07-09): 21 live-and-broken → now **2** user-reachable (4ii, 32i); ingredients/memories/link-picker rows fixed by 990.4/990.5/f25b554.
- Roadmap `[x]` marks contradicted by shipping code: M4 macro rings/rebalance (dead — `l4i`), M13-P3 cook-voice (stubbed — `dac`), M14/16/17 image display (write-only — `xwb`), M6/M7 tool-call cards (stale names — `57d`). Roadmap edit accompanies this report.
- `1sz` "zero a11y" claim stale: 46 labels exist; the gap is identifiers/consistency.
- In-code stale comments catalogued in `55f` (ComingSoonView refs, "still calls Fly" gates, AIPageContext "ships to backend", RecipeEditor "Fly-backed" nutrition).

## e0a durable-store design requirements (gpt-5.6-terra, adopted)

- Namespace every checkpoint by container + database scope + account identity + zone owner/name + household + schema version (current `engine-state.json` naming is NOT scoped — T8).
- Load + validate the full mirror BEFORE constructing `CKSyncEngine(automaticallySync: true)`.
- Persist complete CKRecords (system fields/change tags included) + explicit local-delete intent (absence ≠ not-fetched).
- Mirror + token + pending-outbox + migration receipts commit/recover as ONE logical checkpoint; torn checkpoint ⇒ discard both token and mirror for that scope, full refetch. Never an advanced token over an older mirror.
- Treat app mutations as a durable outbox (payload first-class, not only CKSyncEngine pending IDs); preserve explicit field clears in the representation and at the rebase seam (`t6t`).
- Guard sent-acks with per-record mutation generations (`dkj`).
- `clearState` / account switch / sign-out / role adoption atomically clear-or-park mirror+token+outbox; derive `zoneEnsured` from scoped state.
- Repair + migrations activate only after checkpoint-vs-token completeness proof; awaitable old-session fence on role swaps.
- UI: `ready(stale)` → syncing → authoritative states; render the persisted mirror fast, but absence-based creation (`ensureCurrentWeek`), cascades, migration, destructive repair stay gated on authoritative.
- Crash-test both orders (store-before-token / token-before-store), pending save+delete, receipts, account switch, owner↔participant swap, mid-ack edit.

## Keyless walkthrough verdict (census)

One seam (`AIService.resolveConfiguration`) with clean typed errors; no hangs or silent AI no-ops anywhere reachable. Manual planning/recipes (JSON-LD import, OCR)/grocery/events are real keyless value — the 4.2 story holds. Reviewer-visible lies to fix pre-submission: Plan Shopping (3 entry points), grocery feedback swipe, false Drift ring (if a goal is set). Keyless users currently get ZERO AI (light on-device tier is dead scaffolding, gateway unbuilt) — the "manual + on-device" constraint answer is currently just "manual".

## Peer-panel scoring (logged in ~/.claude/model-scorecard.md + model-bench.jsonl)

glm-5.2 5/5 (2 confirms + 1 correct refutation + 4 new) · gpt-5.6-terra 5/5 (2 new P1s + e0a requirements) · gpt-5.6-sol logged on return · Sonnet-5 discovery agents: A/B/C/D/E all returned structured, file:line-grounded output; D self-verified its top claims before reporting.

## Un-swept / residual (honesty)

EventRepository tail helpers; streamWithTools Anthropic/OpenModels bodies (device gate 3sf covers); AssistantPromptsView internals; ASC product config + fly.dev liveness (not statically verifiable); all census classifications are static traces — device gates (6uj a97 nli cnx mmi f5e auc cel) remain the runtime proof.
