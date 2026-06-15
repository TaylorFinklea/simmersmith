# SimmerSmithCloudKit — SP-A foundation modules

Pre-built ahead of CloudKit container provisioning, per
`.docs/ai/phases/cloudkit-sp-a-spec.md`. Pure-Swift and **CloudKit-free**, so they
unit-test headlessly; the thin `CKSyncEngine` / `CKRecord` / `NSPersistentCloudKitContainer`
adapters land at the relevant build phases. **Not yet wired into the app target.**

Run: `swift test` (Xcode 26 / Swift 6.2) — 25 tests, all green.

## `GroceryMerge` — the field-merge resolver (SP-A §5, the make-or-break component)
Generalizes Spike 1's `groceryResolver` to the full sticky-field policy.
- `FieldMergeResolver` — per-field merge for `GroceryItem` (monotonic tombstone,
  sticky overrides, check-state triple-as-a-unit, event_quantity writer-ownership),
  `EventGroceryItem` (live-pointer-wins), `Event` (sticky `manually_merged` pin), and
  generic `lww` pass-through.
- `ConflictRepair` — semantic grocery dedupe **with `EventGroceryItem` repointing**
  (the M68 fix the adversarial review caught), duplicate-slot repair, duplicate-week
  collapse, sort reconcile, dangling-ref SET-NULL.
- Wire-up at Phase 4: the `CKSyncEngine` conflict handler calls `FieldMergeResolver`;
  a post-batch pass calls `ConflictRepair` over affected parents.

## `AIProviderKit` — the provider-agnostic AI seam (SP-A §7)
- `ProviderRouter` — feature→tier policy (light tasks on-device; heavy reasoning
  cloud-by-default on iOS 26; on-device-heavy gated behind a flag until Spike 2 at GA).
- `KeyStore` — `InMemoryKeyStore` (tests) + `KeychainKeyStore` (BYO keys never touch
  CloudKit).
- `AIProvider` + `AIClient` — one call site; `OnDevice`/`BYOKey`/`CreditsGateway`
  providers are wired stubs (`throws .notWiredYet`); SP-B fills the real backends.

## Status
Foundation only. The CloudKit integration (zones, CKShare, the sync adapters) is the
container-gated phase work in the SP-A spec. These modules de-risk the two hardest
pure-logic pieces — the resolver and the AI seam — so the integration phases inherit
tested cores.
