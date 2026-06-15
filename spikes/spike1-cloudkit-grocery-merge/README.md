# Spike 1 — CloudKit offline grocery-merge

**Throwaway de-risking spike.** Delete once SP-A absorbs the finding (and the
real two-device CloudKit confirmation is done). Spec + verdict:
`.docs/ai/phases/cloudkit-migration-spikes-{spec,report}.md`.

## What it answers
Does SimmerSmith's grocery smart-merge survive CloudKit's conflict model under
concurrent household edits, and on which sync API?

## Run
```
swift test
```
Headless, no network, no CloudKit container, no keys. Xcode 26 / Swift 6.2.

## What it models
- `GroceryItem.swift` — the merge-relevant fields of the production model + the
  merge key (`_key_for_item`).
- `Replica.swift` — a device's local store + a faithful port of
  `regenerate_grocery_for_week` (app/services/grocery.py:500). Each write stamps a
  shared monotonic clock.
- `SyncFabric.swift` — resolves concurrent same-record writes under two modes:
  `NSPersistentCloudKitContainer` (record-level last-writer-wins) vs `CKSyncEngine`
  (the proposed field-merge `groceryResolver`).
- `Tests/` — the four failure modes under both modes.

## Finding (see report for detail)
Grocery is CloudKit-safe **only on `CKSyncEngine` + a custom field-merge resolver**;
blanket LWW (`NSPersistentCloudKitContainer`) silently resurrects tombstones, drops
event contributions, and clobbers user overrides. Check-state is fine under LWW.

## Caveat
Deterministic model of CloudKit's documented conflict semantics, **not** a live
CloudKit run. SP-A must confirm on two real devices with a provisioned container.
