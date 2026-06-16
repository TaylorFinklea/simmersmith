# SP-A Phase 4-remainder + Phase 5 — event↔week merge (corrected spec)

Status: design corrected via the Sonnet/Haiku design+review workflow (2026-06-16). The first
draft had multiple BLOCKING bugs the multi-lens review caught; this spec is the corrected,
implementation-ready version. Raw blueprints + full reviews: `cloudkit-sp-a-phase5-blueprints.md`.

## Corrected facts (the review's blocking findings → their resolutions)

1. **Two DISTINCT deletion semantics — do not conflate.**
   - `dedupe_week_grocery` losers → **TOMBSTONE** (`isUserRemoved=true`, encode+save). Already
     done in `ConflictRepair.dedupeGrocery`.
   - `unmerge_event_from_week` event-only self-deletes (`event_grocery.py:519 session.delete`) →
     **HARD DELETE** (`store.removeRecord` + `.deleteRecord`). Tombstoning these accumulates zombie
     rows. The unmerge result struct must signal hard-delete, separate from dedupe's tombstone.
2. **`apply_auto_merge_policy` branch logic (event_grocery.py:456-472):** the unmerge is gated on
   `linked_week_id AND event_date is not None AND linked is not None AND NOT(event_date in week range)`.
   After that conditional unmerge, `_resolve_target_week` + `merge_event_into_week` run
   **UNCONDITIONALLY** (no `eventDate non-nil` gate — adding one breaks idempotent re-merge for a
   dateless event). Branch 3 (`auto_merge_grocery=False`) unmerges only when `linked_week_id` set.
   `manually_merged` pinned events are NEVER auto-unmerged.
3. **EventGroceryItem field semantics (no collision if you don't expand for the merger):**
   - Swift `EventGroceryItem.eventQuantity` = THIS event row's contribution. The existing
     `FieldMergeResolver.merge(EventGroceryItem)` (merge eventQuantity via `mergeEventQuantity` +
     `mergedInto*` via `preferLive`) is CORRECT as-is — the merger needs **no value-type expansion**.
   - The expansion (`totalQuantity` + ingredient fields) is needed ONLY by the `merge_event_into_week`
     PORT (to create/aggregate week `GroceryItem`s from event rows). Prod `total_quantity` (the event
     row's own aggregate) ≠ week `GroceryItem.eventQuantity` (cross-event accumulator). Keep them named
     distinctly to avoid the silent semantic bug the review flagged.
4. **GroceryItem is missing `weekID`** — the value type has no week scope, so the post-batch repair
   can't get the week's sibling set. Add `weekID: String` to `GroceryItem` + codec, and a store
   scan/index by weekID. (Needed before the repair pass; not needed for the EventGroceryItem merger.)
5. **Event sticky merge — reuse the 2b record shape, don't double-model.** Event is already a 2b
   typed record (LWW, `manuallyMerged INT64`, `updatedAt TIMESTAMP`). For Phase 5 it needs the
   `manuallyMerged` pin merged. The `EventSyncMerger` reads the 2b fields and maps `updatedAt`
   (TIMESTAMP) → `SyncClock` for `FieldMergeResolver.merge(Event)`. Do NOT add a second Event codec
   with logical clocks (the review's date-fragility concern) — reuse the 2b TIMESTAMP fields.
6. **`eventDate: String?`** (nil = no date). Any non-nil value MUST be ISO-8601 `YYYY-MM-DD` so
   lexical order == chronological order (load-bearing for `_resolve_target_week`). Enforce at the codec.
7. **Post-batch repair: avoid the double-save race + preserve monotonicity.** Only enqueue
   keepers/tombstoned rows that actually CHANGED; tombstone via encode+save (never deleteRecord);
   the GroceryItem codec already keeps the check-state triple together (verify it doesn't tear).
8. **`Week.weekEnd`** add + index (prod week.py:26 indexed); `weekStart` is the unique key.

## Layered plan (each layer independently committable + verifiable)

- **Layer A (DONE this turn) — multi-merger seam + EventGroceryItem merger.** `DispatchingMerger`
  (holds `[RecordMerger]`, dispatches by `handles`); `EventGroceryCodec` (the existing 5 thin fields);
  `EventGrocerySyncMerger` wrapping the tested resolver. On-sim: two engines, concurrent edits to an
  EventGroceryItem's `mergedInto` pointer + `eventQuantity` → converge. No value-type expansion → no blocker.
- **Layer B — Event sticky merger.** `EventSyncMerger` over the 2b Event record (map updatedAt→clock),
  registered in the DispatchingMerger. On-sim: concurrent `manuallyMerged` pin vs a clearing edit → pin survives.
- **Layer C — value-type expansion + GroceryItem.weekID + Week.weekEnd + codecs + CKDSL** (EventGroceryItem
  ingredient fields, Event/Week/WeekMeal codecs). Headless round-trip tests.
- **Layer D — `EventMergeEngine`** (pure): port `merge_event_into_week` / `unmerge_event_from_week` /
  `apply_auto_merge_policy` / `_resolve_target_week` / `_match_keys` VERBATIM (the corrected semantics
  above). Hard-delete vs tombstone kept distinct. Headless tests against the prod scenarios (3→6→9 guard,
  re-date unmerge, manuallyMerged pin, name-agnostic marker).
- **Layer E — post-batch repair pass** wired into the engine (after fetched changes land): dedupe +
  slot-repair + sort-reconcile over the affected week's siblings (needs weekID index). On-sim: two
  devices race a duplicate → converge to one keeper + tombstones, no double-count.
- **Layer F — on-sim event↔week** end-to-end (merge an event into a week on engine A while engine B
  edits a shared grocery row → both converge; unmerge hard-deletes the event-only rows on both).

Phase 5 "done" = Layers C–F. Layers A–B are Phase-4-remainder foundation.
