# CloudKit Migration — De-risking Spikes Report

> Spec: `cloudkit-migration-spikes-spec.md`. Evidence for the SP-A / SP-B
> go/rethink decisions. Updated as each spike lands.

## Spike 1 — CloudKit offline grocery-merge across two devices

**Status: algorithmic verdict DONE (2026-06-15) via deterministic simulation.
Real two-device CloudKit confirmation deferred to SP-A.**

### Question
Can the household grocery smart-merge run client-side over CloudKit without
corrupting under concurrent two-member edits — and on which sync API?

### Method
Throwaway SwiftPM package `spikes/spike1-cloudkit-grocery-merge/` (runs headlessly
via `swift test`, Xcode 26 / Swift 6.2). It models the one property that decides
safety — **how two replicas' concurrent edits to the same record resolve** — under
both CloudKit sync APIs:

- `.lastWriterWins` — `NSPersistentCloudKitContainer`: whole-record LWW, no hook.
- `.fieldMerge` — `CKSyncEngine` + a proposed `groceryResolver` that merges
  field-by-field.

The real `regenerate_grocery_for_week` classification (app/services/grocery.py:500)
and its helpers (`_key_for_item`, `_is_event_only`, `_has_user_investment`,
`_apply_fresh_to_existing`) are ported to Swift and run on each replica's local
store. Two replicas share a monotonic logical clock; a `SyncFabric` resolves pushes
against a shared "server" record set. Each of the four failure modes runs the same
concurrent scenario under both sync models.

### Results — `swift test`, 8/8 pass

| Failure mode | `NSPersistentCloudKitContainer` (LWW) | `CKSyncEngine` (field-merge) |
|---|---|---|
| **Tombstone resurrection** | ✗ removed item comes back; **order-dependent** (resurrects if regen writes last, survives if remove writes last → nondeterministic) | ✓ stays removed regardless of interleaving |
| **`event_quantity` loss** | ✗ a stale regen drops the event contribution (nil overwrites the merged value) | ✓ contribution preserved |
| **User override clobbered** | ✗ concurrent regen wipes `quantity_override` | ✓ override preserved |
| **Check-state convergence** | ✓ converges (plain LWW is correct for a single value) | ✓ (n/a — no special handling needed) |

### Verdict — **GO, with a required API choice**
The grocery smart-merge **can** stay client-side on CloudKit — **but only on
`CKSyncEngine` with a custom field-merge resolver** for the sticky fields
(`is_user_removed`, `*_override`, `event_quantity`). `NSPersistentCloudKitContainer`'s
blanket last-writer-wins is **unsafe** for grocery: it silently resurrects
tombstones, drops event contributions, and clobbers user overrides under exactly
the concurrent-household-edit pattern this app has. No server slice is required for
grocery *if* SP-A adopts `CKSyncEngine` for the grocery zone.

The corollary is the cost: SP-A must run the **grocery (and, by the same family,
event↔week merge) data on `CKSyncEngine`** — the more manual, lower-level API —
while plain-value data (recipes, pantry, preferences, check-state) can ride the
easier `NSPersistentCloudKitContainer`. The app's sync layer is therefore *two
mechanisms*, not one.

### Fidelity caveat (honest scope)
This is a **deterministic model of CloudKit's documented conflict semantics**
(record-level LWW vs app-driven field merge), not a run against live CloudKit. It
faithfully exercises the property under test — whether the merge algorithm's
invariants survive each resolution model — and the verdict is robust because it
turns on well-documented API behavior. It does **not** cover real-CloudKit
wrinkles: zone-level change tokens, `CKShare` participant semantics, partial-batch
failures, and server-vs-client clock skew. **SP-A must still confirm with a real
two-device `CKSyncEngine` run** (needs a provisioned CloudKit container under the
dev team) before committing the production merge. The model de-risks the
*algorithm*; the device test de-risks the *integration*.

### Out of scope (per spec)
Household invite re-keying (`merge_solo_into`) — designed in SP-A around `CKShare`
(no solo-then-merge). Event↔week merge — same sticky-field family as grocery; if
the field-merge approach holds on real devices, SP-A extends `groceryResolver`'s
technique to it.

---

## Spike 2 — Week-gen quality: AFM 3 / PCC vs gpt-5.5 + Claude

**Status: harness BUILT + verified (2026-06-15); RUN deferred to iOS 27 GA.**

Per the 2026-06-15 decision the whole A/B run waits for iOS 27 GA (this machine's
Xcode 26 / iOS 26 ships only first-gen Foundation Models, not AFM 3 20B / third-party
PCC). What's ready now in `spikes/spike2-weekgen-quality/`:

- **8-context corpus** (`corpus.py`) — 2 dietary goals, ≥2 allergy sets, varied
  preferences, a history-heavy case for reuse/dedup stress.
- **Rubric scorer** (`rubric.py`) — allergy violations (hard fail), avoid hits,
  reuse-cap ≤3, history dedup, variety, ±15% macro drift, latency. Mirrors the
  production checks (`score_meal_candidate`, `score_macro_drift`).
- **Production-shape ingest** (`backends.plan_from_json`) so cloud JSON and the
  GA Swift on-device tool feed one scorer.
- **13 unit tests** (`test_rubric.py`, `python3 -m unittest test_rubric` → 13/13).

Deferred to GA: wire the 4 backend stubs (gpt-5.5, Claude, AFM 3 on-device, PCC),
lifting the real prompt from `week_planner.py::_build_system_prompt`, then run
`runner.py` and paste the comparison table here.

### Verdict
TBD at GA. Hard gate: any allergy violation fails that tier for week-gen.
