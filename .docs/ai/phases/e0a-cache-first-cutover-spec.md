# e0a P2 — Cache-first cold-launch cutover

> Status: staged direction selected; adversarially revised written spec awaiting owner review (2026-07-15)
> Owner: Lead · scope: Week 3 cache-first cutover, default off until device gates clear
> Builds on: `e0a-shadow-mirror-spec.md`, `e0a-shadow-mirror-report.md`, and the
> adopted requirements in `arch-audit-2026-07-14-report.md`.

## 1. Outcome and rollout boundary

An existing household with one valid, scope-matched P1 checkpoint opens its cached kitchen
before network reconciliation. The app restores the checkpoint's records, every contiguous WAL
suffix, durable local intents, tombstones, CloudKit state serialization, zone state, and mutation
generations as one bootstrap unit. It constructs `CKSyncEngine` with that serialization, reconciles
the engine's opaque pending set against the durable outbox while all delegate work is gated, and
only then lets automatic sync run. Reconciliation fetches only changes after the checkpoint token.

P2 is staged behind one injected `CacheFirstLaunchGate`. Its shipping default remains **off**
while P1e's signed-device offline rerun is open. Unit and integration tests may opt in. A
TestFlight/debug-only control may opt in on a named test device only after P1e and the authority
hardening clear. Default-on is a later one-line policy change after the P2 crash, account,
two-device, offline-finding, and performance gates in §8 all pass. Gate-off behavior remains the
P1 nil-token/full-fetch path.

The gate is a pure value injected into the AppState/session factory, not a global read scattered
through boot code. The production resolver combines one static shipping default with an
install-local override that is honored only for sandbox-receipt TestFlight/debug runs; tests inject
the value directly. The hidden internal control writes only that local override. App Store receipt
runs ignore it, and an unknown receipt environment fails off. Default-on changes the single static
default after §8; there is no remotely mutable flag or account/household identifier in the policy.

This phase does not weaken any fail-closed rule to improve launch time:

- no account identity or no unique exact scope ⇒ no cache;
- any checkpoint, asset, journal, outbox, receipt, or state decode failure ⇒ quarantine that
  scope and use the full-fetch path;
- a cache may render user data but is not authoritative until a post-restore fetch succeeds;
- absence-based creation, migrations, destructive repair, and cascade planning remain dormant
  until authoritative reconciliation; and
- sign-out, account switch, participant revocation, factory reset, or a stale boot epoch removes
  cached data from the active UI before another scope can render.

Offline cached launch is best effort, not a privacy exception. P2 may render offline only when
CloudKit can still prove the current account identity locally. If the platform cannot do so on a
supported device, the app keeps the blocking path and records that platform limitation; it never
caches or guesses an account identity to satisfy the cold-launch metric.

First install and any launch without a valid checkpoint keep the existing blocking discovery,
mint-if-definitively-empty, full fetch, migration, and repository wiring path. Onboarding can
continue to occupy that unavoidable first-install window. P3's user-facing "rebuild local cache"
action remains separate.

## 2. Grounding and rejected approaches

### Current critical path

- `HouseholdSession.init` deletes the role-specific legacy state file, creates an empty
  `HouseholdLocalStore`, and constructs an automatically syncing engine with nil state.
- `HouseholdSession.start()` opens the independent private plane, ensures the owner zone, and
  awaits a full `fetchChanges()` before returning.
- Owner boot then runs receipt checks and migrations before `wireHouseholdRepositories` performs
  ten local repository reloads and `ensureCurrentCloudKitWeek()` before `.ready`.
- P1 already has the recoverable checkpoint needed to remove the full fetch from the visible
  path, but its runtime deliberately never returns records to the active store.
- `HouseholdLaunchPhase.ready` currently conflates "content can render" with "the complete server
  state has been reconciled." `SyncPhase` is a legacy mixed status surface and cannot safely gate
  destructive household work.

### Alternatives

1. **Selected — staged, default-off cutover.** Build and verify the complete restore and
   authority model now, expose it only to tests and a gated internal device control, then flip the
   default after evidence. This keeps an immediate per-device escape hatch during validation and
   leaves release users on the proven P1 path.
2. **Wait for P1e, then big-bang cutover.** This minimizes concurrent modes but delays all local
   TDD work and provides no opt-in candidate or kill switch when device testing begins.
3. **Immediately default on.** This is the smallest rollout diff but violates the adopted P1 gate.
   P1's build-157 quarantine was safe, yet it demonstrated that device-only delivery behavior can
   expose a defect absent from package tests. A binary rollback is too coarse for this data path.

Rejected implementation shortcuts:

- **Restore records but keep a nil token.** Safe from skipped server changes, but every launch
  still full-fetches and can overwrite/reload the UI repeatedly; it is not P2.
- **Restore the token without WAL/outbox overlay.** Can silently lose a pre-crash save, delete, or
  explicit field clear and is the exact token-ahead-of-mirror failure P1 was built to prevent.
- **Render the legacy `SimmerSmithCacheStore`.** It is not account/zone scoped and does not contain
  CloudKit system fields or the durable outbox. It must not become P2's stale-data source.
- **Guess among cached scopes.** Alphabetical, newest-file, or record-count selection can expose a
  prior household. Ambiguity always returns to CloudKit discovery and full fetch.

## 3. Package design — one verified bootstrap unit

### 3.1 Scope discovery without a zone census

Add a versioned, self-validating `MirrorScopeAnchor` beside the P1 checkpoint types. The writer
persists and fsyncs the exact `MirrorScope` anchor before it accepts the first WAL mutation. A
pre-P2 directory with a valid `current` bundle may derive and durably backfill the same anchor only
after full bundle validation; a journal by itself can never invent its scope from the hashed
directory name. P2b owns the durable anchor write primitive and new-write ordering; P2c owns this
one-time validated backfill while cataloging an existing generation.

The read-only bootstrap catalog receives the CloudKit-proved current account record name,
requested role, and (for a participant) the marker's exact owner zone. It scans anchored scope
directories and committed `current` generations under the shadow-mirror root. It recognizes two
fail-closed results:

- **cached resume:** a valid scope anchor, `current` generation, and recovered contiguous WAL can
  materialize household content plus engine state; and
- **recovery only:** an exact valid scope anchor and WAL exist but no complete generation exists.
  The app must preserve and re-enqueue those local intents, but it renders no partial household and
  takes the nil-token full-fetch path before becoming ready.

For a pre-P2 journal-only directory without an anchor, cold catalog discovery refuses the data. If
normal CloudKit discovery later independently establishes that exact scope, writer recovery may
open the directory by its derived `cacheKey`, replay its journal, and use the recovery-only path.
This preserves an edit without allowing anonymous bytes to select an account or zone.

Candidate data is untrusted until all of these hold:

- the directory name equals the decoded full scope's `cacheKey`, and the anchor equals the bundle
  manifest scope;
- container, format, account record name, database scope, role, zone, and household fields are
  internally valid;
- the `current` pointer resolves inside its scope directory;
- the complete bundle passes archive, asset, receipt, logical-digest, engine-state-digest, and
  outbox validation;
- every decoded record ID, tombstone, receipt identity, and outbox save/delete ID belongs to the
  manifest's exact zone; no two envelopes use the same `CKRecord.ID`, even under different record
  types; and every asset resolves inside the selected generation or a retained outbox asset root;
- recovery replays every contiguous journal transition above the manifest high-water before it
  materializes records or pending work; and
- participant selection exactly matches its saved zone owner/name. Owner selection requires
  exactly one valid owner/private scope for the current account.

An incomplete final WAL frame is truncated back to the last validated byte boundary and the file
and parent directory are synchronized before any later append. A complete frame with an invalid
checksum, shape, or sequence quarantines the exact scope; it is not treated as a torn tail. Tests
cover checkpoint-plus-suffix replay, anchor-plus-WAL without `current`, pre-P2 journal-only
recovery after independent discovery, and torn-tail → restart → append → restart.

Zero candidates, multiple owner candidates, a malformed candidate, an unknown account identity,
or an unavailable participant marker yields no cached bootstrap. Multiple valid owner candidates
also emit a privacy-safe anomaly diagnostic. Corruption quarantines only the exact scope; healthy
siblings are untouched. Account-boundary root clearing is a separate intentional lifecycle policy
in §6. The catalog never trusts mtime and never persists an unscoped "last household" pointer.

This bypasses the owner zone census only when a previously verified unique scope already names the
household and zone. It never bypasses the current `accountStatus`/account-record identity check.

### 3.2 Materialized bootstrap

The catalog produces one immutable `MirrorBootstrap` for cached resume, or a recovery-only plan
with no base records/state token. These are spec-derived boundaries, not alternate stores. A
cached bootstrap contains:

- the exact validated `MirrorScope` and generation identity;
- decoded record clones whose `CKAsset` fields still point only to verified generation-local
  durable files;
- a decoded `CKSyncEngine.State.Serialization` from the bundle's engine-state bytes;
- the recovered `zoneEnsured` value;
- one normalized pending save/delete change per `CKRecord.ID`, reconstructed from the ordered
  durable outbox;
- durable post-checkpoint removal proofs for an acknowledgement, terminal failure, remote-delete
  supersession, or older operation superseded by a newer durable mutation;
- the maximum local mutation generation per record identity;
- the journal high-water and blocked-permanent intent count; and
- the receipt index used only as cached UI data until authority is established.

Materialization starts from the checkpoint records and the writer's fully recovered state, never
from `loadCurrent` alone. It replays effective outbox intents in sequence: a save replaces its
matching record with the intent payload; a delete removes the record; tombstones are then asserted
absent. A generation lease pins every checkpoint/outbox asset root referenced by the active store
or pending payload until the session has rebound or released those records.

Restart normalization is per `CKRecord.ID`, not per outbox row. For each ID, the latest effective
mutation wins. Older `sent` intents are durably superseded; only a latest effective mutation still
marked `sent` receives an append-and-fsync restart-retry transition back to `pending`. A latest
pending mutation stays pending. A latest `blockedPermanent` mutation stays terminal and contributes
to `intervention`, never to the retryable `pending(count:)`. After normalization there are no
restored `sent` rows and at most one retryable engine change per record ID. Every normalization
transition is idempotent across a crash. Tests cover sent-save→new-save, sent-save→new-delete,
sent-delete→new-save, sent-delete→new-delete, an old acknowledgement arriving after each newer
operation, and crashes on both sides of supersede/retry persistence.

Each normalization runs on the writer's serial state lane in durability order: append and fsync
the transition, apply the transition to in-memory recovered state, then expose the normalized
bootstrap plan. Engine state is untouched until that plan exists. A crash after the durable append
but before the in-memory apply replays the transition exactly once on restart; the inverse order is
forbidden and pinned by a failpoint test.

`supersededByRemoteDelete` is a separate terminal state: its archived save payload remains
available only to local diagnostics/recovery evidence and is excluded from projection overlay,
tombstones, and engine pending changes. It contributes to `intervention`, not `pending`.

A recovery-only plan carries the same normalized intents, generations, removal proofs, and asset
leases but no renderable base or serialized token. It does not enter the cached engine seam. The
nil-state control performs independent discovery/ensure-zone/full fetch first; before `.ready`, it
overlays the recovered intents onto that authoritative base, seeds generations, and adds exactly
their pending changes. Thus an anchor-plus-WAL crash cannot lose an edit, but WAL-only partial data
never becomes UI and never sends before the base fetch/zone path succeeds.

The bootstrap decoder additionally proves that the opaque state bytes decode as
`CKSyncEngine.State.Serialization`; P1's raw digest alone does not prove P2 can construct an engine
from them. Decoding is necessary but not sufficient: §3.3 reconciles the opaque state's pending
changes against the normalized durable plan. Any decode, recovery, overlay, or normalization
failure quarantines the exact scope and returns no cached bootstrap.

### 3.3 Engine construction

Before implementation relies on this seam, a deterministic real-engine probe must prove the SDK
contract: create a non-automatic engine, add save/delete pending changes, capture a genuine
`State.Serialization` from `stateUpdate`, encode/decode it, construct a second non-automatic
engine, and verify its pending set plus `state.add`/`state.remove` reconciliation. The signed-device
gate in §8 separately proves that a captured production serialization resumes a server token. The
probe records Xcode/CloudKit SDK and OS versions in the P2 report and must rerun after any SDK/Xcode
change before default-on.

`HouseholdSyncEngine` gains an optional bootstrap input and a closed bootstrap delegate gate at its
construction seam. When present:

1. the catalog hands off one immutable bootstrap snapshot. The store, merger, callbacks,
   generation lease/bookkeeping, normalized outbox, zone state, and continuing checkpoint runtime
   are ready before the candidate engine exists; a bootstrap publication fence defers new
   generation publication until candidate reconciliation opens or fails closed;
2. configuration receives the bootstrap serialization instead of nil;
3. every delegate entry point—including `handleEvent`, `nextFetchChangesOptions`, and
   `nextRecordZoneChangeBatch`—waits behind the same closed gate, because an automatic engine may
   call back as soon as it is constructed. The gate has terminal `open` and `rejected` outcomes;
   rejection releases waiters into no-op/discard behavior rather than leaking suspended tasks;
4. after construction, the bootstrapper projects the public, `Hashable`
   `PendingRecordZoneChange` cases into canonical `(CKRecord.ID, save|delete)` set entries and
   diffs them against the normalized durable plan. It uses only the public
   `state.remove(pendingRecordZoneChanges:)` and `state.add(pendingRecordZoneChanges:)` APIs to
   remove an opposite/absent operation only when a recovered WAL transition durably proves its
   acknowledgement, terminal resolution, or supersession; it adds a missing target operation,
   then reprojects and requires one exact operation per ID. A serialized pending without either a
   durable target or a durable removal proof is an invariant breach and fails closed rather than
   being silently sent or discarded;
5. cached resume requires recovered `zoneEnsured == true`, and its expected pending-database set is
   empty. The bootstrapper separately canonicalizes the public `pendingDatabaseChanges` cases and
   fails closed on any save/delete, participant database mutation, unrelated zone, or mismatch.
   Recovery-only/full-fetch boot keeps the existing owner ensure-zone path instead; and
6. only after the post-construction state exactly matches the durable plan does the gate open and
   queued events drain through one ordered event path.

Bootstrap reconciliation reads direct engine state and never waits for a gated delegate event, so
an awaiting delegate cannot participate in the gate-open dependency. A real-engine test proves
construction returns with callbacks queued, no batch is produced before reconciliation, and queued
events drain in order after open.

This is the sole allowed post-construction bootstrap work. Store records, assets, generations,
callbacks, and runtime are never hydrated after engine construction. If candidate validation
fails, its gate never opens; operations are canceled, the exact scope is quarantined, its leases
are released, queued delegate work is rejected/discarded, the store is cleared before content can
render, and a fresh nil-state/full-fetch engine is constructed. The construction seam rechecks the
expected CloudKit account record name,
role, zone owner/name, and participant marker against the bootstrap scope even though the catalog
already checked them. With no bootstrap, `coldStartStateSerialization()` remains nil and current
P1 behavior is unchanged.

## 4. App boot and orthogonal state

### 4.1 Two boot paths

The serialized owner/participant boot queue and `sessionBootEpoch` stay the single lifecycle
choke point.

**Valid cache + gate on:** resolve account identity, select/materialize the exact bootstrap,
construct `HouseholdSession`, wire household repositories from the restored store, mirror their
local projections, set the content gate to ready, and start reconciliation in the same epoch-owned
boot operation. The caller may still be awaiting reconciliation, but `RootView` renders as soon as
content is ready.

**No cache or gate off:** run the current participant-first/discover/mint, `session.start()`,
migration, repository wiring, and full-fetch path. No timing or behavior change is accepted in
this control mode. With gate on plus a recovery-only plan, use the same nil-state/full-fetch path
but apply its normalized durable intents after the successful fetch and before authority/ready as
specified in §3.2. Gate off remains the exact P1 shadow behavior.

The per-user NSPersistentCloudKitContainer is independent of the household mirror. On a cached
launch it opens in parallel rather than ahead of the kitchen. `ProfileRepository`,
`PreferenceRepository`, `AssistantRepository`, and `AIService` already reach
`session.privateStore` dynamically; after the container opens, their projections reload and the
personal-data readiness state updates. Until then, household data remains usable and personal
writes that require the private plane stay disabled/no-op exactly as they are when that store is
unavailable.

### 4.2 State model

Keep `HouseholdLaunchPhase` as the content-availability gate used by `RootView`:

- `resolving` — no scope-validated household content is safe to display;
- `ready` — cached or authoritative household content can render; and
- `iCloudUnavailable` — the current account cannot be used.

Add an orthogonal household authority state rather than flipping `.ready` twice:

- `none` — no session;
- `reconciling(cachedAt:)` — scope-valid cached content is visible while the first fetch runs;
- `current(Date)` — the post-bootstrap fetch returned and completeness gates opened;
- `offlineCached(cachedAt:)` — cached content is visible but authority was not reached;
- `pending(count:)` — authority was reached and durable local changes remain queued;
- `degraded(message:)` — a recoverable sync failure exists; and
- `intervention(message:)` — blocked-permanent work, revocation, or an account boundary requires
  user action.

This state is household-specific and does not reuse legacy Fly `SyncPhase`. It drives sync copy,
system-operation gates, and diagnostics. `intervention` outranks `pending`; blocked-permanent or
terminal conflict rows are not reported as retryable work. A user can read cached content and make
ordinary non-destructive edits while reconciling/offline; those edits enter the durable outbox.
Operations that derive deletes from absence remain disabled until `current`.

P2e implements these transitions through one pure reducer rather than ad hoc assignments. Table
tests cover initial cached/direct-current entry, every reconciliation outcome, current/pending
movement, error retry, and teardown to none; an epoch/session mismatch is always a no-op. Property
tests pin intervention priority and forbid a torn-down session from returning to ready/authority.

Every transition after an `await` rechecks the captured boot epoch and exact session identity.
The stale-to-current transition never rewires repositories or writes `.ready` again, so a late
fetch cannot resurrect a torn-down session.

## 5. Authoritative-only operations

The following stay behind one session-owned authority boundary. A store being non-empty, a cached
migration receipt, or a valid token is not equivalent authority. This boundary is enforced at the
data plane, not only by disabled buttons: every direct repository call to `engine.delete` or
`engine.deleteCascading`, every repair/migration entry point, and every AppState system operation
must present current-session authority or return the retryable not-authoritative result.

- owner `ensureCurrentCloudKitWeek()` and any other absence-based record creation;
- ingredient, recipe, event, week, and pantry/profile migration receipt checks and writes;
- `RepairScheduler.activate()` and any destructive repair/dedupe pass;
- cascade-child enumeration in `deleteCascading`;
- leftover-household census/deletion;
- factory-reset postconditions that assert a freshly complete household; and
- any future operation that converts "not in the local store" into a create or delete.

Ordinary upserts remain available because the WAL captures their full payload and explicit field
clears before the store changes. A destructive user action requested before authority either waits
behind reconciliation or presents a retryable "Finish syncing before deleting" result; it never
derives a cascade from stale children. After the first fetch succeeds, the boot operation runs the
deferred migrations, current-week creation, and repair activation in today's order, then reloads
only the affected projections.

An authoritative remote deletion received during first reconciliation wins over a pre-authority
pending save for that same record ID. Before removing the cached record, the engine appends and
fsyncs a terminal `supersededByRemoteDelete` transition, removes the engine pending save, retains
the archived local payload only for diagnostics/recovery evidence, and surfaces a non-retryable
conflict instead of recreating the deleted record. A matching pending delete is consumed as
success. This policy prevents a stale cached edit from silently resurrecting a record another
device deleted. It applies equally to a recovered offline edit and an edit made after cached ready;
tests pin both cases.

Cached `MigrationReceipt` records may inform UI but cannot suppress a migration until the same
session becomes authoritative. This preserves the receipt-last fix without trusting an incomplete
cache as proof of source completeness. A table-driven inventory test covers the ingredient,
recipe, event, week, pantry, and profile receipt consumers named above; adding a new receipt
consumer requires adding it to the authority table rather than branching directly on cached data.

The test-injected P2 path may exercise cached boot before this authority slice lands only with all
destructive/system operations denied. No debug/TestFlight opt-in control becomes available until
the complete data-plane boundary and lifecycle ordering in §6 are implemented and green.

## 6. Lifecycle, fallback, and recovery

- **Mandatory handoff ordering:** on an account boundary or verified revocation, AppState first
  performs one main-actor, non-suspending transition that advances the boot epoch, moves content out
  of `.ready`, detaches published projections, and marks teardown in progress. It then
  fences/cancels the engine and writer, tears down repositories and the active generation lease,
  durably invalidates the required cache/marker, and only then may discovery construct another
  session. Every later step is idempotent; suspension/failure leaves the app non-ready in
  `intervention`, and the next launch retries teardown from the already-advanced epoch. It never
  proceeds on a best-effort `try?` clear.
- **Sign-out/account switch:** the account-change callback must reach that AppState lifecycle choke
  point; clearing only the engine store is insufficient. Account boundaries intentionally clear
  the entire shadow root, including unanchored legacy directories, rather than trying to retain a
  previous account's household data. Root clearing first atomically renames the active root to a
  non-catalog `retired` sibling and synchronizes the parent directory; only that successful
  namespace invalidation permits a new root/session. Recursive deletion of the retired tree is
  retryable cleanup, so a partial delete is never selectable. Exact-scope quarantine below remains
  scoped.
- **Owner→participant adoption:** fence and park the owner scope; resolve the participant's
  current account identity and exact saved shared-zone scope; never select the parked owner scope
  while a participant marker exists. Parking is a durable non-selectable scope state, not an
  in-memory flag; only independently verified owner discovery may unpark it. Normal generation
  retention/cleanup applies while parked.
- **Participant revocation/deleted shared zone:** a verified deletion unconditionally clears the
  participant marker and exact participant scope under the mandatory handoff, then transitions to
  intervention/resolution. The current P1 path clears only the in-memory store; P2 must close this
  verified stale-cache resurrection gap before any cache can drive UI. An offline device cannot
  learn about an unobserved remote revocation; it may show a previously verified cache only while
  CloudKit still proves the same account and the local marker remains valid. The next observed
  revocation must tear it down before any later ready transition.
- **Owner zone deleted remotely:** a fetched deletion not owned by the active reset transaction
  uses the same epoch-first teardown, invalidates the exact owner scope, and returns to discovery;
  it never trusts restored `zoneEnsured` to recreate the zone or send cached work first. Cached
  visibility before that server event remains explicitly non-authoritative.
- **Factory reset:** write the local invalidation boundary before CloudKit deletion/mint work.
  A crash after local invalidation cannot select the old generation. A new scope becomes selectable
  only after a complete verified checkpoint publishes. Factory reset intentionally clears the
  entire shadow root. A durable reset transaction outside that retired root records CloudKit
  deletion as pending; reset is not reported complete and no replacement household is minted until
  the server deletion succeeds. Network/server failure remains visible and retries idempotently on
  foreground/next launch.
- **Corruption/quarantine:** never mutate the last good generation in place. Quarantine the exact
  scope, construct a nil-state empty store, and run the full fetch. Sibling account/role scopes
  remain untouched.
- **Reconciliation failure:** keep scope-valid cached content visible as `offlineCached` or
  `degraded`; keep authority-only work dormant. A later foreground retry uses the same serialized
  operation gate and epoch checks.
- **Reconciliation success:** apply deltas, preserve/rebase local outbox intents through existing
  merge seams, mark authority current, run deferred system work, and publish a fresh generation.
  Once the active records and pending payloads are rebound into that generation, release the
  bootstrap generation lease; never release while an active `CKAsset` still points into it.

Rebase tests name the supported cached cases rather than assuming every existing seam is sufficient:
a pending merger-owned save plus remote modification uses `RecordMerger`; a pending non-merger save
keeps its local payload until CloudKit resolves its send conflict; remote delete follows §5; and a
recovery-only launch completes the full fetch before it may project or author dependent records.

P3 adds the user-facing non-destructive rebuild action. P2 may expose the existing internal
quarantine/fallback diagnostics but does not add a production cache-reset button.

## 7. Performance and observability

The cached path records privacy-safe signposts for account identity resolved, gate source/decision,
checkpoint selected, bundle validated, candidate gate opened or rejected/quarantined, store
materialized, household projections ready, `MainTabView` visible, private plane ready, and
reconciliation complete. Payloads are allowlisted to event kind, duration, counts, booleans, build,
and SDK version. Do not log account names, household IDs, recipe text, raw record identifiers, or
hashed versions of those identifiers. Owner-scope anomalies log counts/timestamps only.

Bead `8qy` remains a separate optimization item, not a P2 correctness dependency. First measure
bootstrap validation, hydration, and each initial repository projection. If the absolute launch
target fails and repeated whole-store scans are the demonstrated blocker, triage/execute `8qy`
against that evidence: maintain a record-type index across every store mutation and hydrate/clear
path, then take one immutable typed snapshot for the hot initial projections. Do not fold broader
mutation-path JSON cleanup or speculative indexing into the cache cutover.

That conditional work has an explicit stop: P2g records the failed target, adds `8qy` as a blocker
of P2h, and stops. `8qy` lands as its own phase-loop item and commit, then P2g's measurements repeat.
P2h cannot begin, and cannot absorb the architecture change, until the repeated target passes.

Before default-on, record at least 30 force-quit launches on the same seeded device/build pair for
the P1 control and P2 opt-in paths. Report median and p95 launch-task-to-`MainTabView` time plus
median absolute deviation, checkpoint materialization, and projection sub-times. Hard acceptance
is P2 median ≤1.0 seconds and p95 ≤1.5 seconds to cached `MainTabView`. When the paired P1 control
median is at least 2.0 seconds, P2 must also reduce it by at least 75%; below that floor, report the
relative change but use the absolute targets. If account identity or private-plane work dominates,
move only independently safe work off the visible path; never cache an unvalidated account
identity to win the metric.

## 8. Crash, test, and release gates

### Deterministic package/app matrix

- valid exact owner and participant checkpoints restore before engine construction;
- checkpoint-plus-WAL suffix, anchor-plus-WAL without `current`, independently rediscovered
  pre-P2 journal-only data, and torn-tail→append recovery preserve every valid local intent;
- recovery-only boot renders/sends nothing before nil-state discovery/full fetch, then overlays and
  enqueues each normalized intent exactly once before authority/ready;
- zero, ambiguous, cross-account, wrong-role, wrong-zone, duplicate-record-ID, wrong-format,
  corrupt, escaped-asset, or missing-asset candidates never hydrate the active store;
- a real non-automatic engine serialization round-trip preserves pending changes; bytes with a
  valid digest but invalid `CKSyncEngine` decoding fail closed;
- the closed delegate gate prevents every automatic callback/send from observing partial bootstrap
  state, and a rejected candidate is canceled/cleared before content readiness;
- an unrelated-zone pending database change, any participant database mutation, an unexpected
  delete-zone, or a pending database change inconsistent with `zoneEnsured` fails closed;
- pending save, pending delete, save→delete, explicit clear, sent-before-crash, ack-before-crash,
  blocked-permanent, newer-edit-before-old-ack, and every sent→newer-operation permutation survive
  restart with no `sent` row and exactly one effective pending change per record ID;
- a stale serialized pending is removed only with a recovered post-checkpoint ack/terminal/
  supersession proof; the same extra pending without proof quarantines instead;
- local mutation generations resume above every recovered intent generation;
- crash before/after supersede or restart-retry WAL append is idempotent;
- restored assets remain readable across publication/old-generation cleanup;
- gate off constructs a nil-state engine, starts empty, and keeps the current full-fetch path;
- test injection can enable the gate, the local override is honored only under the internal
  receipt policy, and an App Store receipt ignores that override while the static default is off;
- cached ready renders while every direct delete/cascade, migration, week creation, repair, and
  cleanup entry point remains denied at the data plane;
- successful reconciliation opens each deferred gate once; failed reconciliation opens none;
- a remote delete consumes a matching pending delete and terminally supersedes a pre-authority
  pending save without resurrection or silent payload loss;
- blocked-permanent/terminal conflicts produce intervention, never retryable pending counts;
- sign-out/account switch, owner↔participant swap, participant revocation, remote owner-zone
  deletion, factory reset, and a stale epoch cannot leave prior-scope content visible or
  selectable; an injected invalidation failure remains non-ready and cannot construct the next
  session;
- an atomically retired root stays unselectable across partial recursive-delete failure/restart,
  and a factory-reset transaction cannot report complete or mint while server deletion is pending;
- a late fetch from a torn-down session cannot rewire repositories, write `.ready`, or alter the
  successor session; and
- signpost payloads pass a static/test allowlist that rejects account/household/record identifiers
  and user-authored text; and
- legacy unscoped `SimmerSmithCacheStore` data cannot flash after cached `.ready`.

### Device gate before any opt-in launch

P1e must first record a clean signed-device online edit, offline save+delete, force-quit, relaunch,
reconnect, and no-new-quarantine result on the post-repair build. The existing two-device Gate-1
proof must be current enough to exercise the same schema/merge code.

### P2 opt-in device gate

On owner and participant devices: measure online cached launch and attempt offline cached launch;
record whether CloudKit can prove account identity offline rather than weakening the identity gate.
Make pending edits/deletes; crash at the record-first/state-second/supersede/restart-retry
checkpoints; reconnect and verify no loss or duplicate delivery; switch accounts; adopt and revoke
a share; and confirm every fallback returns to full fetch without exposing another scope. Capture
launch signposts, mirror digest/quarantine outcomes, and visible sync/authority states in the P2
report.

At least one signed-device run must use a genuine device-captured serialization, create one known
remote change after that checkpoint, relaunch, and capture an engine trace showing that the
serialization was accepted, the post-token change arrived, pre-token records were not replayed,
and a later state update advanced/published. A decode-only or mock-engine test cannot clear this
positive resume gate.

### Default-on and release

Default-on requires all automated gates, P1e closure, the P2 opt-in device matrix, two-device
convergence, the genuine-token-resume proof, no unexplained digest mismatch/quarantine, and the
performance target. A fresh Opus plus equal-or-higher-tier adversarial review of the final default-
off implementation must have no unresolved Critical/Important findings. Lack of offline account
identity is recorded as a platform limitation, not a reason to guess identity. Then run both Swift
packages, the ad-hoc-signed app-target suite, generic iOS build, CI, archive/upload, ASC processing,
internal-group assignment, and a final installed TestFlight cold-launch check. Release operations
are controller-owned; workers never push, upload, assign groups, or edit build numbers.

## 9. Phase-loop decomposition

Every implementation item is one serial TDD unit with its own command verifier and commit. Worker
prompts grant only named files and explicitly deny git, beads, release, and build-number authority.

### P2b — scope anchor and WAL recovery hardening

- **Scope:** persist/fsync the validated scope anchor before the first WAL mutation; recover every
  suffix above `current`; support recovery-only anchored WAL; truncate an incomplete tail before
  later append; expose a read-only recovered snapshot without hydrating the live store.
- **Files:** checkpoint writer/contracts and focused crash tests only; no engine, session, or app
  edits.
- **Routing:** `tier_floor: lead` · `complexity: M`
- **Verify:** `swift test --package-path SimmerSmithCloudKit`
- **Commit:** `fix(cloudkit): harden mirror journal recovery`

### P2c — verified bootstrap catalog and normalization

- **Scope:** add exact-scope catalog selection, object-level zone/ID/asset validation, cached and
  recovery-only bootstrap values, outbox/tombstone overlay, durable sent/supersession
  normalization, generation leases/seeds, state decode, and the non-automatic real-engine
  serialization probe. Backfill the anchor for a pre-P2 `current` only through P2b's durable write
  primitive after complete validation. Pin WAL-fsync-before-in-memory normalization with
  failpoints. The SDK probe is the first red/green acceptance; if it cannot prove the public state
  contract on the pinned SDK, P2c stops and P2d does not begin. No production engine wiring.
- **Files:** new focused bootstrap source/tests plus checkpoint contracts/writer only; no app edits.
- **Routing:** `tier_floor: senior` · `complexity: L`
- **Verify:** `swift test --package-path SimmerSmithCloudKit`
- **Commit:** `feat(cloudkit): materialize verified mirror bootstraps`

### P2d — gated resumable engine construction

- **Scope:** accept a verified bootstrap at the engine seam; prepare store/runtime/leases before
  construction; fence generation publication; hold every delegate callback; canonicalize/diff the
  public pending record/database cases through `state.add`/`state.remove`; open only an exact
  candidate; cancel/quarantine/fallback otherwise; keep nil-state control exact.
- **Files:** `HouseholdSyncEngine.swift`, focused bootstrap/runtime sources, and package tests; no
  app lifecycle or UI edits.
- **Routing:** `tier_floor: lead` · `complexity: L`
- **Verify:** `swift test --package-path SimmerSmithCloudKit`
- **Commit:** `feat(cloudkit): resume sync engine from mirror bootstrap`

### P2e — test-only cached app boot and state model

- **Scope:** inject the default-off gate; resolve/select scope inside serialized owner/participant
  boot; show cached household projections before reconciliation; open the private plane
  independently; add orthogonal authority state. Before cached content can render, install a
  minimal fail-closed data-plane guard that blanket-denies direct engine delete/cascade and every
  migration/repair/system-operation entry point. Tests may inject on; no user-accessible opt-in
  exists yet. Wire the one static-default + receipt-gated local-override policy through the injected
  factory value. Re-run the full gate-off app path to prove nil-state/full-fetch behavior is
  unchanged.
- **Files:** `HouseholdSession.swift`, `HouseholdSyncEngine.swift` destructive seams,
  `AppState.swift`, focused AppState/migration/repair extensions, `RootView.swift`, and app tests.
  Do not enable a debug or shipping control.
- **Routing:** `tier_floor: senior` · `complexity: L`
- **Verify:** `swift test --package-path SimmerSmithCloudKit && bash scripts/dev-sim.sh && xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`
- **Commit:** `feat(ios): open cached household before reconciliation`

### P2f — authority, conflict, and lifecycle hardening

- **Scope:** enforce authority across direct delete/cascade/migration/repair/system boundaries;
  replace P2e's blanket denial with exact current-session authority; implement remote-delete
  terminal conflict policy; defer/run system work once; perform mandatory account/revoke/reset
  ordering, atomic root retirement, durable reset transaction, and invalidation; prevent legacy
  flash and stale epochs. Re-run cached-ready while data-plane-denied coverage against the
  session-aware boundary. Add the named-device
  internal opt-in only after this slice is green **and** P1e is recorded closed; otherwise leave
  the control absent and stop before device opt-in. Shipping default stays off.
- **Files:** engine destructive/revocation seams, app lifecycle and migration/repair entry points,
  gated debug surface, and focused package/app tests. No projection optimization.
- **Routing:** `tier_floor: lead` · `complexity: L`
- **Verify:** `swift test --package-path SimmerSmithCloudKit && bash scripts/dev-sim.sh && xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`
- **Human prerequisite:** `.docs/ai/current-state.md` records e0a P1e `[x]` with the signed-device
  online/offline/no-new-quarantine evidence before the named-device control is added.
- **Commit:** `fix(cloudkit): gate cached sessions until authoritative`

### P2g — observability and performance evidence

- **Scope:** add privacy-safe launch signposts, capture automated seeded-store timings, and begin the
  P2 report with the SDK probe versions and 30-run median/p95/MAD evidence. Verify signpost payloads
  against a privacy allowlist. Keep `8qy` separate unless
  timings prove whole-store scans block the absolute target; on that outcome, add `8qy` as a P2h
  blocker, stop, and repeat P2g after `8qy` lands. The feature remains shipping-default off.
- **Files:** signpost/test sources, only cold-path files proven hot by timing, P2 report, and loop
  state. Any `8qy` implementation stays on its own bead/commit.
- **Routing:** `tier_floor: senior` · `complexity: M`
- **Verify:** `swift test --package-path SimmerSmithCloudKit && bash scripts/dev-sim.sh && xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`
- **Commit:** `perf(ios): measure cached household launch`

### P2h — adversarial/device gate and default-on release

- **Scope:** no architecture changes. Run package/app/CI gates; Opus plus equal-or-higher-tier
  adversarial review; P1e and P2 owner/participant/two-device/account/crash/performance checks;
  capture genuine token-resume and supported-offline findings; then change the shipping default,
  cut the next build, upload, assign, install, and cold-launch check.
- **Routing:** `tier_floor: lead` · `complexity: L`
- **Verify:** automated commands above plus the named human/device evidence in
  `.docs/ai/phases/e0a-cache-first-cutover-report.md`
- **Commit:** default-on and release bookkeeping remain separate controller commits after evidence.

## 10. Threat boundary and non-goals

P2 treats every on-disk cache byte as corruptible/untrusted input and CloudKit responses as the
only remote authority, while relying on iOS app-sandbox, file-protection, Keychain/account, and
CloudKit transport guarantees. It does not defend against an attacker controlling an unlocked or
jailbroken device, nor add cache encryption beyond platform data protection. Those assumptions do
not weaken exact account/scope validation or App Store override denial.

No new CloudKit record types or Production schema change, no typed replacement database, no
remote feature-flag service, no production cache-reset button, no broad repository rewrite, no
broader change to CloudKit merge semantics beyond the named pre-authority remote-delete rule, no
weakening of account identity validation, and no P3 rebuild workflow. P2 fixes cold launch while
preserving the P1 transactional mirror as the sole durable household cache.
