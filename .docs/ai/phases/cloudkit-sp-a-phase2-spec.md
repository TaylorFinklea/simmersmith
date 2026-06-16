# SP-A Phase 2 — Household zone + CKShare + plain-CRUD content (spec)

Phase 2 is large; it decomposes into 2a–2d. The CKShare half genuinely needs two iCloud
accounts, so it's the manual residual; everything else builds + verifies single-device.

## Decomposition

- **2a — household-zone `CKSyncEngine` driver. ✅ BUILT + VERIFIED LIVE 2026-06-15.**
- **2b — typed plain-CRUD household records** + cascade/SET-NULL graph (the ~12 record
  types the spec lists). Layer typed encode/decode + relationship cleanup over 2a's store.
- **2c — CKShare lifecycle**: `UICloudSharingController` invite + accept, owner/participant
  model, single-household-per-user enforcement, ownership-transfer policy (pin-to-owner vs
  re-host). **Two-account manual verify.**
- **2d — `WeekChangeBatch`/`WeekChangeEvent` audit retention/prune** (keep local-only or
  prune on cap/age — it otherwise syncs to every member's iCloud quota).

## 2a — what shipped

Spec §4.2: one household zone = ONE sync stack (two stacks racing the change token forks
the household). 2a builds that single stack.

Files (`SimmerSmithCloudKit`, new `HouseholdSync` target, Swift 5 mode — `CKSyncEngine` +
`CKRecord` predate strict-concurrency annotation):
- `Sources/HouseholdSync/HouseholdLocalStore.swift` — thread-safe (NSLock) in-memory
  mirror of the zone's `CKRecord`s; the source of truth the engine uploads from and applies
  fetched changes into. `applyRemoteModification` is the LWW pass-through hook the Phase 4
  grocery/event field-merge resolver will override.
- `Sources/HouseholdSync/HouseholdSyncEngine.swift` — `CKSyncEngineDelegate`:
  state-serialization persistence (JSON at an injected URL), `nextRecordZoneChangeBatch`
  from pending state, `handleEvent` for sent/fetched/state/account, manual `sync()` /
  `sendUntilDrained()` (deterministic for the DEBUG round-trip; the app can flip
  `automaticSync` on), `save`/`delete` API.

### Two correctness rules the live round-trip forced out (keep these)

1. **A fetch must not clobber a record with an unsynced local edit.**
   `.fetchedRecordZoneChanges` skips any modification whose recordID is in
   `pendingRecordZoneChanges` (a pending `.saveRecord`). Without this, `sync()`'s
   fetch-before-send pulled the older server copy over the pending edit and re-sent the
   stale value — the local edit was silently lost. This skip point is exactly where the
   Phase 4 field-merge resolver hooks in (merge instead of skip-or-overwrite).
2. **`serverRecordChanged` rebases, not drops.** On a stale-tag save failure, copy the
   local field values onto the server record (which carries the current tag) and re-enqueue
   the save, so the retry matches. `sendUntilDrained` drains the rebase-and-retry. (Plain
   records = local LWW wins; grocery/event re-merge here at Phase 4.)

### Verify — the single-device trick

`runHouseholdSyncCheck()` (DEBUG CloudKit-checks panel) drives **two** `HouseholdSyncEngine`
instances with **separate local state files** against **one shared zone** on this account —
engineB stands in for a second device. Proves the full round-trip:
- engineA save+send → record on the server,
- engineB (fresh state) fetch → sees it,
- engineA edit → engineB converges (LWW),
- engineA delete → engineB sees the tombstone.

**Verified live 2026-06-15** on the iPad sim signed into Taylor's iCloud: all ✅. The
`eventTrace` diagnostic on the engine stays (CloudKit is hard to debug on-device; it's the
only window into delegate events).

### Residual / debt carried into 2b–2d

- Cross-account CKShare (savanne's iCloud on the iPhone-16 sim) = the real multi-member
  proof; needs two accounts; manual.
- `HouseholdLocalStore` is in-memory for 2a; 2b backs it with persistence + typed models.
- `eventTrace` accumulates unbounded — fine while only the debug panel drives the engine;
  cap or drop it when wiring the engine into the live app.
- The `household-phase2-test` dev zone holds a few leftover records from the 3 failed
  debug runs (each early-returned before cleanup). Harmless dev-zone debris.
