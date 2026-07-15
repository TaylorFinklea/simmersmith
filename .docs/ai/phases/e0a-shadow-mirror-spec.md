# e0a P1 — Shadow mirror checkpoint design

> Status: adversarially reviewed design / implementation not started (2026-07-15)  
> Owner: Lead · scope: Week 2 shadow mode only  
> Source ground truth: `HouseholdSession`, `HouseholdSyncEngine`, `HouseholdLocalStore`,
> `MigrationLedger`, and the adopted requirements in `arch-audit-2026-07-14-report.md`.

## 1. Outcome and boundary

`HouseholdLocalStore` is recreated empty at every cold launch, while
`HouseholdSyncEngine` serializes its CloudKit state independently. The current safety backstop
therefore deletes `engine-state.json` before building the engine, forcing a complete fetch.
That is safe but slow. The durable-store work must make the mirror and the sync token one
recoverable unit; an advanced token over an older mirror is a silent permanent data-loss bug.

P1 builds and exercises that unit in **shadow mode**. The shipping boot path still starts with
an empty active store, clears the legacy engine-state file, does the existing full fetch, and
uses the fetched data for UI, migrations, repairs, and writes. The shadow cache is parsed,
validated, and compared, but it does not hydrate the live store or give state to
`CKSyncEngine`. P2 is the separately gated cached-launch cutover; P3 is a user-facing,
non-destructive rebuild-cache recovery action.

P1 must not change CloudKit schema, repository semantics, launch readiness, migration order,
repair activation, or the current full-fetch fallback. This P1a iteration is design-only;
subsequent P1b–P1d production edits are limited to the files and seams named in §6.

## 2. Grounding and alternatives

### Current seams

- `HouseholdSession.init` chooses only `engine-state.json` or `engine-state-shared.json`, then
  calls `HouseholdSyncEngine.clearPersistedState` before constructing its automatic-sync
  engine. It has neither an account namespace nor a persisted store.
- `HouseholdSyncEngine` supplies `stateSerialization` at construction and atomically overwrites
  the state file for `.stateUpdate`; its fetched, sent, account-change, and revocation events
  mutate the store separately. `save`/`delete` queue only CloudKit pending IDs.
- `HouseholdLocalStore` owns copy-in/copy-out `CKRecord` instances. Its tests establish that
  `copy()` retains changed-key state; the test note records that a full secure keyed archive is
  required to preserve a server-fetched record's partial changed-key split.
- `RecipeImageCodec` and `RecipeMemoryImageCodec` attach `CKAsset` files from Caches. Those
  transient URLs cannot be the durable cache representation.
- Migration completion is a `MigrationReceipt` record in the local store; migrations and
  destructive repairs currently rely on a freshly complete fetch before they run.
- Owner-to-participant adoption calls `detach()` to retain the owner's token. Sign-out calls
  `clearState()`. The participant marker contains the owner zone ID, and
  `HouseholdShareFlow.currentUserRecordName()` already provides the signed-in account's stable
  CloudKit record name.

### Rejected alternatives

1. **Archive `HouseholdLocalStore` beside the existing state JSON.** It is the smallest diff,
   but two independently replaced files retain the exact dangerous window: a new token can be
   durable while the record archive is old or absent. It also cannot replay a local save/delete
   whose only durable CloudKit form is a pending ID.
2. **Use SwiftData/SQLite as a new mirror database.** A database could transact records and an
   outbox, but it introduces a second object model for full `CKRecord` system fields, references,
   changed keys, and assets. That is a larger correctness project, not a bounded cold-launch
   repair, and it still needs a generation boundary with the opaque CloudKit state blob.
3. **Use CloudKit's state serialization as the outbox.** The serialization is opaque and its
   pending changes are IDs, not enough payload to replay an interrupted local edit or preserve a
   clear. It cannot be the source of truth for a durable client write.

## 3. Selected design — scoped generation bundle plus write-ahead intents

### Scope identity

Every mirror has an explicit `MirrorScope` with all of these fields:

- format/schema version;
- CloudKit container identifier (`iCloud.app.simmersmith.cloud`);
- database scope (`private` for an owner, `shared` for a participant);
- signed-in account record name, fetched with the same `CKContainer.userRecordID()` surface
  already wrapped by `HouseholdShareFlow.currentUserRecordName()`;
- zone owner name and zone name;
- resolved household ID; and
- role (`owner` or `participant`) as a redundant validation field.

The canonical encoded scope is hashed only for a filesystem-safe directory name. The full scope
is stored in every committed manifest and must compare exactly before use. A missing account
identity, scope mismatch, schema mismatch, or malformed manifest never selects a cache. It is
treated as no cache and preserves the P1 full fetch. This removes both current file-name
collisions and cross-account reuse; a participant's shared zone and its own private zone can
never select one another's checkpoint.

P1 never delays engine construction solely to obtain an account record name. The surrounding
async boot path passes a complete scope when that identity is already resolved; otherwise shadow
capture is disabled for that session and the unchanged full-fetch boot continues. P2 may not pass
cached state or records to the active engine until it has resolved and validated the full scope
before engine construction.

### Checkpoint contents

The Application Support layout is a versioned root with one hashed directory per scope. A
committed generation contains immutable files plus a final manifest:

| Content | Required representation and invariant |
| --- | --- |
| Records | Securely archive the complete `CKRecord`, not typed DTOs or system fields alone. The round trip preserves record type/ID/zone, ordinary fields and references, change tag/system fields, and changed-key state. Archive only an immutable clone whose assets have already been rebound to generation-local durable files. |
| Assets | Before archiving a record, copy every available `CKAsset` into the candidate generation, verify its bytes, and replace that field on the clone with a new asset pointing at the durable copy. Store record/field identity, byte count, and SHA-256 as the integrity index, not a second value source. Any unavailable or mismatched asset makes the candidate not cache-ready and prevents `current` publication; never archive an eligible record that still points into Caches. |
| Tombstones | Persist a record-ID tombstone for each unsent local delete. Absence is never interpreted as either delete or not-yet-fetched. |
| Durable outbox | Persist ordered local save/delete intents with a monotonic intent sequence, full payload, mutation generation, changed fields, explicit cleared fields, and delivery status (`pending`, exact sent generation, or blocked-permanent). It is sufficient to reconstruct every still-pending mutation without reading CloudKit's opaque pending-ID list. |
| Receipts | Persist the complete `MigrationReceipt` record set and an indexed receipt summary as part of the same snapshot. A receipt may only prove completion when its source records and checkpoint are valid together. |
| Engine state | Persist the exact `CKSyncEngine.State.Serialization`, its mirror-coverage revision, the derived `zoneEnsured` companion, and the checkpoint generation that captured them. State never validates a mirror by itself and may lag the records but must never lead them. |
| Integrity | Store raw-byte SHA-256 for every immutable file plus a separately canonicalized logical digest, the scope, format version, mirror revision, and last included intent sequence. The committed pointer identifies exactly one verified generation. |

The secure keyed `CKRecord` archive is authoritative for a record. The asset index validates the
durable `CKAsset` already rebound into that archive; it never overrides an archived field. The
explicit outbox field state prevents an absent field from resurrecting during an interrupted
rebase; this carries forward the clear semantics already pinned in `ClearedFieldRebaseTests` and
`AckSeamRebaseTests`.

Raw archive bytes are never used as the logical digest: keyed-archive encoding is not a stable
canonical form. The logical encoder sorts records by type and full record ID, sorts field and
changed-key names, preserves array order, and emits explicit type tags for every supported
CloudKit value. Record IDs include zone owner/name; references include action and full ID; assets
encode their byte digest; dates and numbers use fixed-width representations. It also includes the
public system metadata needed for safe reuse (change tag, creation/modification dates,
creator/last-modifier IDs, parent, and share reference). File digests detect byte corruption;
logical digests prove that decoding produced the same record/outbox/tombstone/receipt content.
Archive-fidelity tests separately pin opaque system-field and changed-key preservation.

### Write protocol

One serial checkpoint writer owns a scope. It never mutates the last committed generation. All
local store/outbox/generation mutations and all delegate-event store mutations cross one logical
mirror gate; file I/O uses immutable copies captured under that gate. CloudKit documents that
delegate events are delivered serially and that a state update is tied to changes fetched before
that event. Each `.stateUpdate` therefore captures its serialization and the current mirror
revision together inside the event handler. A checkpoint can pair that state only with a record
snapshot at the same or a later mirror revision. It must never read records at one instant and
then attach whatever state serialization happens to be latest at another.

1. Before `save`, `delete`, cascade delete, retry/rebase, or an acknowledgement changes durable
   mirror/outbox state, append and fsync a framed **write-ahead transition** with a monotonically
   increasing intent sequence. A save contains the full archived record; a delete contains the
   record identity/tombstone; an acknowledgement identifies the exact sent sequence and mutation
   generation it resolves. A torn final journal frame is ignored; an invalid interior frame
   quarantines the scope. The synchronous durability cost is intentional and must be measured in
   P1e; generation construction remains coalesced/off the mutation critical path.
2. Under the mirror gate, apply the store and `CKSyncEngine` mutation and increment the mirror
   revision. A coalesced checkpoint captures immutable records, tombstones, outbox, receipts,
   mutation/send-generation bookkeeping, the latest state serialization plus its coverage
   revision, and the journal high-water sequence in one logical snapshot. A transition ordered
   after that snapshot remains in the journal for recovery.
3. Write all record envelopes and copied assets into a fresh generation directory. Validate the
   record and asset digests after writing. This is the **record-first** half.
4. Write the captured engine state serialization and derived `zoneEnsured` only after the record
   bundle validates. Write the manifest last, including the state-coverage revision and journal
   high-water sequence, then atomically replace the scope's `current` pointer with this complete
   generation. This is the **state-second** half.
5. Only after the pointer is durable and the generation has been read back may journal entries
   through the manifest's high-water sequence be compacted. Retain the prior committed generation
   until the new pointer has been read back and verified.

If a crash leaves transitions beyond the current manifest's high-water sequence, recovery builds
a mutable working outbox/tombstone/ack state from the last complete generation and replays only
those higher-sequence transitions in order; it never mutates the immutable generation. P1 still
starts the active engine with nil state for a full fetch, and the next checkpoint captures that
working state. If the pointer includes a transition, its sequence is at or below the high-water
mark and replay cannot apply it twice even when the crash preceded journal compaction. A partial
directory or state file is never selected by itself.

`nextRecordZoneChangeBatch` stamps the exact outbox sequence and mutation generation used to build
each payload. A successful save/delete acknowledgement removes only that exact entry (and its
tombstone for a delete) when no newer mutation supersedes it; a stale acknowledgement rebases
system fields while retaining the newer entry. Transient failure keeps it pending. Permanent
failure remains durably blocked, visible to sync status, and is not automatically replayed until
a later user transition supersedes it. These delivery transitions use the same WAL before their
in-memory effects.

### Shadow behavior and digest

P1 calls the writer from the current engine/store seams but does not restore the cache into the
active store. The existing full fetch remains the source of truth. `.willFetchChanges` opens a
fetch epoch; `.didFetchChanges` closes it after all serially delivered change events. At that
boundary P1 captures a record snapshot under the mirror gate and pairs it only with the most
recent state serialization whose coverage revision does not exceed the snapshot (a lagging token
is safe and may refetch; a leading token is forbidden). After the candidate publishes, P1 reloads
it into an isolated store and compares:

- the canonical logical digest of the immutable boundary snapshot and the reloaded shadow (must
  match; raw keyed-archive bytes are never re-archived and compared);
- count/type/receipt summaries from that same immutable snapshot (must match); and
- asset availability/digest results (must match when an asset is locally downloaded; otherwise
  the generation is explicitly `notCacheReady`).

A prior-launch shadow digest may differ from the current full fetch because another device made
legitimate changes. That difference is diagnostic only. The blocking P1 assertion is the
same-launch round-trip digest, not equality with stale data. Any validation or digest failure
quarantines that generation, records a local diagnostic, and continues the existing full-fetch
experience. It must never downgrade user data, block launch, or silently repair a mismatch.

### Clear, park, and account changes

- `clearState`, sign-out, an engine `.signOut`/`.switchAccounts` event, and a full cache reset
  first fence/quiesce the old scope writer, then clear journal, current pointer, generations,
  tombstones, outbox, receipts, and state together. The clear uses an atomic move out of the live
  scope before asynchronous deletion, so no next boot can observe only one half and no stale
  writer can publish into the moved directory.
- `detach` for owner→participant adoption first fences/quiesces the old writer, then **parks**
  the owner scope intact. The participant resolves a different scope and starts separately.
  A future un-adopt can only reopen the parked owner scope after identity validation.
- Role adoption, teardown, and account-change callbacks await the writer fence before a new
  session is installed. A stale callback cannot publish a generation into the new scope.
- P1 keeps the legacy state-file deletion for the active engine. The generation bundle is not
  an alternate token path until P2's validation gate is complete.

## 4. Crash matrix

| Interruption or fault | Required recovery / assertion |
| --- | --- |
| Before journal append | Previous valid generation remains selected; no invented mutation. |
| Torn final journal frame | Ignore only the incomplete tail; any invalid interior frame quarantines the scope. |
| After save/delete transition, before in-memory enqueue | Replay the higher-sequence transition into the mutable outbox/tombstone state; P1 full-fetches, P2 later re-enqueues it. |
| `.stateUpdate` races a local or fetched mutation | The shared mirror gate orders them; state coverage is either before the mutation or includes its incremented mirror revision, never state-newer/records-older. |
| During record or asset write | No `current` pointer changes; reject incomplete generation and use the last verified one or full fetch. |
| After records validate, before state write | Never use the new records with either old or new state; old verified generation only. |
| After state write, before manifest/pointer | State is unreachable; never load it alone. |
| After pointer replacement, before journal compaction | Manifest high-water suppresses already-included transitions; validate once, then compact through that sequence. |
| Local save followed by local delete before a send | Ordered outbox preserves the tombstone; restart cannot resurrect the saved record. |
| Delete cascade interrupted mid-list | Each delete has its own tombstone/intent; recovery resumes the ordered outbox without treating absent children as proof of deletion. |
| Server ack races a second local edit | Ack transition names the exact sent sequence/generation; rebase the system fields, remove only the old outbox entry, retain explicit clears, and resend only the newer payload. |
| Ack is durable but its checkpoint is interrupted | Replay the ack transition over the prior generation so an already-confirmed entry is not revived. |
| Migration rows written but receipt is absent | Store remains incomplete; do not claim migration complete or activate receipt-dependent cleanup. |
| Account switch/sign-out during a write | Fence old writer and clear old scope; no checkpoint is discoverable under the next account's identity. |
| Owner→participant swap during a write | Park only a fenced, scope-valid owner generation; participant uses its own shared-zone scope. |
| Asset unavailable or digest mismatch | Mark generation not cache-ready, reject it for P2, and use full fetch; never replace an asset with an empty value. |
| Corrupt manifest, unknown schema, or digest mismatch at launch | Quarantine the generation, load neither records nor token, and preserve full-fetch fallback. |

## 5. P1 acceptance and handoff gates

P1 is complete only when package tests prove archive fidelity, intent replay, generation recovery,
asset handling, explicit clears/tombstones, receipt pairing, scope isolation, and every crash row
above through deterministic failpoints. A TestFlight/device run must also show that P1 continues
to full-fetch and that a forced crash never produces a partial active store. Only then can P2 be
specified to restore a complete mirror before engine construction and render cache-first UI.

P2 must not start on a green build alone. It requires P1 crash-matrix evidence, shadow
round-trip digest telemetry with no unexplained mismatches, and the existing two-device Gate-1
proof. P3's recovery action must clear only the scoped cache and then re-run the normal full
fetch; it never deletes CloudKit records.

## 6. Bounded TDD / Ralph implementation plan

Every item is a single serial work unit. Start each by adding the named failing test, run the
item verifier red, implement only that item, then rerun the verifier green. All items are
Ralph-eligible because their verification is local and command-based; no item may close `e0a`
or start P2.

### P1b — persistence contracts and full-record archive

- **Scope:** Add the immutable scope, manifest, record envelope, asset envelope, tombstone,
  outbox, receipt index, and canonical-digest contracts in `SimmerSmithCloudKit` beside
  `HouseholdLocalStore`. Add `ShadowMirrorCheckpointTests` in
  `SimmerSmithCloudKit/Tests/HouseholdSyncTests/`.
- **TDD cases:** exact scope match/mismatch; full keyed `CKRecord` round trip including changed
  keys and system fields; canonical logical digest is stable when keyed-archive bytes differ;
  explicit cleared-field state; asset bytes are copied and the archived clone points only to the
  durable copy; unknown/missing asset cannot publish `current`; receipt index requires its receipt
  record.
- **Ralph boundary:** one worker owns only the new persistence source/test files; do not edit
  `HouseholdSyncEngine.swift` or app sources.
- **Verify:** `swift test --package-path SimmerSmithCloudKit`
- **Commit:** `feat(cloudkit): add shadow mirror checkpoint contracts`

### P1c — journal, generation publication, and fault recovery

- **Scope:** Add the serial writer and deterministic failpoint seam in the same package. It
  writes record/asset bundle first, state second, atomically publishes `current`, replays framed
  higher-sequence save/delete/ack transitions, and quarantines invalid generations.
- **TDD cases:** every crash-matrix row through pointer publication and journal compaction;
  state-only and records-only generations rejected; prior generation survives failed publication;
  a post-pointer crash does not replay a sequence at/below manifest high-water; save then delete
  leaves a tombstone; exact ack removes only the sent generation; receipt and state cannot
  validate independently.
- **Ralph boundary:** own only shadow-mirror source/tests added in P1b; no session or UI edits.
- **Verify:** `swift test --package-path SimmerSmithCloudKit`
- **Commit:** `feat(cloudkit): checkpoint shadow mirror transactionally`

### P1d — engine/session shadow wiring without cache restore

- **Scope:** Wire the existing engine store/state/mutation seams and `HouseholdSession` lifecycle
  to the writer. Use a complete scope already available from surrounding async boot or disable
  shadow without delaying engine construction; retain `clearPersistedState` for the active engine;
  couple serialized delegate events/local mutations to the mirror gate; fence
  clear/park/account-change paths; add a same-launch isolated-store digest comparison after the
  existing full fetch boundary.
- **TDD cases:** shadow mode constructs the active engine with nil cached state; a valid shadow
  never hydrates the live store in P1; `.stateUpdate` racing a mutation cannot create
  state-newer/records-older; no account identity means shadow-disabled/full-fetch without a launch
  wait; clear removes a whole fenced scope; detach parks it; participant and owner scopes differ;
  stale callbacks cannot publish after teardown.
- **Ralph boundary:** own `HouseholdSyncEngine.swift`, `HouseholdSession.swift`, and focused
  package tests only. Do not alter repositories, migrations, repairs, or RootView readiness.
- **Verify:** `swift test --package-path SimmerSmithCloudKit && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`
- **Commit:** `feat(cloudkit): run durable mirror in shadow mode`

### P1e — hardening evidence and phase gate

- **Scope:** Expand only the focused fault/digest tests needed to make the crash matrix
  executable, add the exact P1 runtime device checklist to the e0a report, and record observed
  digest/quarantine outcomes. No cache-first UI or P2 state restore.
- **TDD cases:** repeat each deterministic failure injection at least once after P1d; assert
  full-fetch fallback and no active-store hydration after a bad checkpoint; measure journal-flush
  latency on device and record the distribution rather than claiming mutation behavior unchanged.
- **Ralph boundary:** test/report files only; no production behavior change.
- **Verify:** `swift test --package-path SimmerSmithCloudKit && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`
- **Commit:** `test(cloudkit): prove shadow mirror crash recovery`

## 7. Non-goals

No cache-first UI, no replacement of `.ready` with boot/sync substates, no change to the
CloudKit record schema, no typed-record mirror, no background reconciliation redesign, no
destructive repair on a cached store, no migration behavior change, and no user-visible
"rebuild local cache" button. Those are P2/P3 work after this shadow gate.
