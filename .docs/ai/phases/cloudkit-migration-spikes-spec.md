# CloudKit Migration — De-risking Spikes Spec

> Status: **draft, awaiting user review** · Authored 2026-06-15 (Opus)
> Parent decision: rearchitect SimmerSmith toward Apple-native / offline-first,
> shrinking (not eliminating) the central server. This spec covers ONLY the two
> throwaway de-risking spikes that gate the larger migration. It is not the
> migration plan.

## Why this exists

We want to move SimmerSmith's **data plane** to CloudKit and its **AI plane** to
the WWDC26 Foundation Models framework, retiring most of the FastAPI + Postgres +
Fly server. Two assumptions are load-bearing and unproven. If either fails, the
end-state changes materially. Spike before committing months to the data-plane
rewrite (SP-A) or the AI re-tiering (SP-B).

Both spikes are **throwaway** — isolated from the app, deleted after they yield a
verdict. Their only deliverable is a one-page evidence report that picks a
direction.

## Decisions locked (this session, 2026-06-15)

- **Apple-only is accepted.** CloudKit as the data plane forecloses Android/web
  for household data. Deliberate product choice, driver = Apple-native +
  offline-first.
- **Drop the Claude.ai MCP connector** (and its OAuth AS + web SSO). This is what
  lets the residual server shrink toward zero. The existing `app/mcp/`,
  `app/api/oauth.py`, `app/services/{oauth,sso}.py` get retired in SP-D, not
  migrated.
- **No forced payment, no feature gating.** Monetization = AI cost pass-through:
  free on-device/PCC, BYO-key, or our paid AI credits. So there is NO server-side
  freemium/entitlement/usage-counter requirement (the `entitlements.py` /
  `UsageCounter` machinery is dropped, not ported).
- **Spike-first**, targeting the zero-default-server end-state ("Approach 1").

## End-state target (north star for the spikes — NOT in scope to build here)

```
iOS app = the whole product
  DATA   CloudKit private DB  → profile, prefs, dietary goal, assistant transcript
         CloudKit shared DB   → recipes, pantry, weeks, events, aliases, memories
         CloudKit public DB   → ingredient + nutrition catalog (read-mostly)
         (NSPersistentCloudKitContainer / CKSyncEngine for offline-first sync)
  AI     Foundation Models framework, one call site:
           on-device AFM 3 (free) · Private Cloud Compute (free <2M dls) · BYO key
  PLATFORM  StoreKit 2 entitlement · local notifications · EventKit · Vision · voice
  (optional, later) Credits gateway — Sign in with Apple + credit ledger + our key,
                    revenue-funded, only users who buy credits ever touch it
```

Sub-project decomposition (each gets its own spec→plan→build later):
- **SP-A** CloudKit data plane (schema, zones, sharing topology, client-side merge).
- **SP-B** AI tiering via Foundation Models (+ Evaluations harness).
- **SP-C** On-device platform (local-notification scheduling replaces APScheduler;
  StoreKit-only entitlement) — the easy wins.
- **SP-D** Migration + retirement (Postgres → users' iCloud; turn Fly off; one-time
  public-catalog seed tool; retire MCP/OAuth/SSO).
- **SP-E** Credits gateway (optional, only when monetizing).

---

## Spike 1 — CloudKit offline grocery-merge across two devices

**Question:** Can the household grocery smart-merge run client-side over CloudKit
without corrupting under concurrent two-member edits — and on which sync API?

### The crux to surface
Two CloudKit sync APIs, very different conflict behavior:
- `NSPersistentCloudKitContainer` — effortless offline-first, but **last-writer-wins
  with no conflict hook**. Cannot express "keep the tombstone, refresh the auto
  quantity."
- `CKSyncEngine` (iOS 17+) — more work, but **explicit conflict resolution** at sync
  time, which a keyed set-reconciliation needs.

The spike's primary output is a recommendation:
1. *Grocery rides `CKSyncEngine` with custom resolution; everything else can use
   `NSPersistentCloudKitContainer`*, or
2. *Even `CKSyncEngine` can't make this safe → grocery merge stays server-side*
   (a sliver of server survives — changes the "zero-server" claim), or
3. *`NSPersistentCloudKitContainer` LWW is acceptable with strict tombstone
   discipline X*.

### What to build (minimal, throwaway)
- A tiny Swift package / command-or-UI harness with ONE record type, `GroceryItem`,
  carrying the fields that actually drive the merge. Mirror these from the real
  model `app/models/week.py:184` (`class GroceryItem`):
  `normalized_name`, `base_ingredient_id`, `ingredient_variation_id`,
  `resolution_status`, `unit`, `quantity_text`, `total_quantity`, `source_meals`,
  `notes`, `is_user_added`, `is_user_removed`, `quantity_override`, `unit_override`,
  `notes_override`, `is_checked`, `checked_at`, `checked_by_user_id`,
  `event_quantity`, `updated_at`.
- A shared CloudKit zone simulating one household, exercised by **two** container
  instances (two iCloud test accounts / two simulators or devices).
- A Swift port of **just the classification core** of
  `regenerate_grocery_for_week` (`app/services/grocery.py:500`) and its helpers
  `_key_for_item`/`_key_for_row` (`:315`/`:327`), `_is_event_only` (`:354`),
  `_has_user_investment` (`:363`), `_apply_fresh_to_existing` (`:375`). Read those
  before porting; do not re-derive from this spec. The merge key is
  `(base_ingredient_id or normalized_name, locked_variation_id, unit, quantity_text)`.
  Do NOT port pricing, pantry-recurring fold-in, or catalog resolution — out of
  scope.

### Pass/fail — run each failure mode CONCURRENTLY on two devices, assert none occur
1. **Tombstone resurrection.** Device A removes an auto item (`is_user_removed=True`,
   line 542–544/552–553 keeps it dead); Device B regenerates before A's change
   syncs. → item stays removed after convergence; does not reappear.
2. **`event_quantity` double-count.** `event_quantity` is owned solely by the
   event merge/unmerge pair and regen never writes it (line 558–562). Two devices
   contributing/merging concurrently → final `event_quantity` is correct, not summed
   twice.
3. **Override survival.** Device A sets `quantity_override`; Device B regenerates
   (which skips `total_quantity` when an override is set, `_apply_fresh_to_existing`
   line 383–384). → override survives convergence; not clobbered by LWW.
4. **Check-state convergence.** Both devices toggle `is_checked` on the same item →
   converges to a single coherent value (household-shared check state).

### Deliverable
`.docs/ai/phases/cloudkit-migration-spikes-report.md` Spike-1 section: which sync
API, which of the 4 modes passed/failed, and the SP-A grocery recommendation
(client-side-safe vs. keep-grocery-on-server). Plus a note on whether
`NSPersistentCloudKitContainer` LWW is acceptable for the NON-merge data
(recipes, pantry, prefs) — expected yes.

### Verify
Two-device concurrent test scenario runs and all 4 assertions report
pass/fail deterministically (a documented manual two-device run is acceptable for a
spike; no CI). Report section written with a go/rethink verdict.

### Explicitly out of scope (noted so it isn't lost)
- **Household invite re-keying** (`merge_solo_into`, `households.py`) — a one-shot
  migration, not steady-state concurrency. Folded into SP-A's CKShare
  sharing-topology design, where the join-and-merge flow is redesigned around
  CKShare from day one (no solo-then-merge). Flag if you'd rather probe it here.
- Event↔week merge atomicity — same family as grocery; if Spike 1 says grocery is
  CloudKit-safe, SP-A extends the technique to event merge. If grocery fails,
  event merge fails too and both stay server-side.

---

## Spike 2 — Week-gen quality: AFM 3 / PCC vs gpt-5.5

**Question:** Is on-device AFM 3 (and/or Private Cloud Compute) good enough at the
hardest reasoning task — full-week planning — to be the free default, or is week-gen
a tier that needs a cloud frontier model (BYO-key/credits)?

### What to build (minimal, throwaway)
- Lift the real week-gen prompt and the planning-context shape from
  `app/services/week_planner.py` — `gather_planning_context` (`:78`),
  the generate path `generate_week_plan` (`:582`), and the scorer
  `score_generated_plan` (`:485`). Read these; mirror the prompt and the context
  fields (preferences, hard_avoids, allergies, dietary goal/macros, staples,
  recent-meal history, reuse caps).
- Assemble ~8 representative planning contexts spanning: a couple of dietary
  goals, ≥2 allergy sets, varied preference signals, and a non-empty history (to
  test dedup + reuse caps).
- Run each context through three backends:
  - **Baseline** — gpt-5.5 via the current backend path (the bar to match).
  - **AFM 3 on-device** — Foundation Models framework, guided generation
    (`@Generable`) for the 21-meal structured output.
  - **Private Cloud Compute** — same framework call site, PCC tier, if reachable
    on the test hardware.

### Pass/fail — score each output on a hard rubric
- **Allergy violations** — any violation is a HARD FAIL for that tier.
- **Macro adherence** — per-day kcal/macros vs the goal, ±% drift.
- **Variety** — distinct cuisines/proteins across the week.
- **Reuse-cap** — ≤3 uses per recipe per week (the existing guardrail).
- **History dedup** — avoids repeating the seeded recent meals.
- **Subjective** — "would I cook this week" (1–5).
- **Latency** — wall-clock per week-gen per tier (on-device vs today's ~2 min).

Scoring may reuse `score_generated_plan`, the WWDC26 Evaluations framework, or
gpt-5.5 as a judge — pick the cheapest that gives a defensible comparison.

### Deliverable
`.docs/ai/phases/cloudkit-migration-spikes-report.md` Spike-2 section: a
per-tier × per-criterion table and a go/no-go per tier, e.g. *"AFM 3 passes light
criteria and hits ~90% of gpt-5.5 on week-gen with zero allergy violations → ship
on-device default, PCC as quality upgrade"* vs *"on-device drops allergy
constraints → week-gen requires PCC or cloud; on-device limited to light tasks."*

### Verify
The 8 contexts run through all reachable tiers, the rubric table is populated, and
the report states a per-tier week-gen verdict. (Light tasks — substitution,
pairing, difficulty, seasonal — are assumed on-device-viable from the inventory and
are NOT re-tested here; only week-gen, the hard case, is measured.)

---

## What this spec deliberately does NOT do
- No CloudKit schema/zone/sharing design (that's SP-A, gated on Spike 1).
- No Foundation Models app integration (that's SP-B, gated on Spike 2).
- No data migration, no server retirement, no credits gateway.
- No production code. Both spikes are deleted once the report is written.

## Open questions for the user before building
1. Spike 2 baseline/cloud: test against **gpt-5.5 only**, or also a **Claude** model
   (since BYO-key routes to Claude/Gemini natively)? Default: gpt-5.5 only as the
   bar; note Claude as a follow-up if on-device underperforms.
2. Spike 1 device setup: do you have **two iCloud test accounts / two devices**
   available, or should the harness simulate two peers via two CloudKit containers
   under one account where possible? (Affects fidelity of the concurrency test.)
3. Include household invite re-keying as a third Spike-1 probe, or keep it deferred
   to SP-A (current plan)?
