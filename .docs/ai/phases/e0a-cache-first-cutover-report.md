# e0a P2 — Cache-first cold-launch cutover: implementation report

Spec: `e0a-cache-first-cutover-spec.md`. Sections land as each phase closes; P2g adds
performance evidence; P2h adds device-gate evidence.

## P2c — SDK probe (spec §3.3 first acceptance)

- Probe: `SimmerSmith/SimmerSmithTests/CKSyncEngineStateProbeTests.swift` (app-target suite;
  the unsigned package host traps in CloudKit on any `CKContainer` construction — see
  decisions.md 2026-07-17).
- Result 2026-07-17: PASS. Non-automatic engine construction; `stateUpdate` emitted after
  `state.add`; `State.Serialization` JSON encode/decode round-trip byte-identical (2377 bytes);
  second non-automatic engine reconstructed the exact save+delete pending set; public
  `state.add`/`state.remove` reconciliation exact; removal of a non-pending operation is a no-op;
  `pendingDatabaseChanges` empty on restore.
- Environment: Xcode 26.6 (17F113) · macOS 26.5.2 · iOS simulator runtime 26.5 (23F77) ·
  Swift 6.3.3. Must re-run after any SDK/Xcode change before default-on (the app-suite verify
  commands in P2e–P2h re-run it automatically).
- Caveat for P2d: `State.Serialization` decoding does NOT validate the opaque archive (garbage
  bytes decode successfully). Decode is necessary-but-not-sufficient; engine-side pending-state
  reconciliation is the real local gate, and §8's signed-device token-resume proof remains the
  only positive resume evidence.

## P2c — bootstrap catalog + normalization

- Durable restart normalization (spec §3.2): journal transition kinds `restartRetry`,
  `supersededByNewerMutation`, `supersededByRemoteDelete`; terminal delivery state
  `supersededByRemoteDelete` (payload retained for diagnostics, contributes to intervention);
  per-identity normalization on the writer state lane, WAL append+fsync before in-memory apply,
  crash-window failpoints (`beforeNormalizationAppend`/`afterNormalizationAppend`) pinned by
  tests; post-conditions: no `sent` rows, ≤1 retryable change per record ID.
- Removal proofs (`MirrorOutboxRemovalProof`): acknowledged / terminalFailure /
  remoteDeleteSupersession / supersededByNewerMutation, re-derived from the post-checkpoint
  journal suffix on every recovery; consumed by P2d reconciliation.
- Catalog (`ShadowMirrorBootstrapCatalog.open`): exact-scope selection for the CloudKit-proved
  account (owner: exactly one owner/private scope, multiple → privacy-safe anomaly diagnostic;
  participant: marker's exact owner zone, nil marker → none); pre-P2 anchorless `current`
  backfills its anchor through the P2b primitive only after full bundle validation; journal-only
  anchorless directories refused cold (writer recovery by independently discovered exact scope
  still works); corrupt selected candidate quarantines only its exact scope.
- Materializer: object-level zone membership for every record/tombstone/receipt/outbox identity;
  CKRecord.ID uniqueness across record types; asset containment inside the selected generation or
  journal-asset roots; genuine-serialization decode proof; outbox/tombstone overlay in sequence
  order with tombstones asserted absent; cached `MirrorBootstrap` and recovery-only
  `MirrorRecoveryPlan` values with pending changes, proofs, max mutation generations, high-water,
  intervention counts, receipts.
- Generation leases (`MirrorGenerationLease`): pin journal-asset sequence roots referenced by a
  materialized plan; publication-time journal-asset cleanup skips pinned sequences; release makes
  them collectable by the next publish. Verified by test across two publishes.
- Verify: `swift test --package-path SimmerSmithCloudKit` — 598 tests, run 5×; app suite 122
  tests (probe included) on SimmerSmithSim.

## P2d — gated resumable engine construction (spec §3.3)

- Package core (`ShadowMirrorBootstrapEngineSeam.swift`): canonical record-ID-level projection
  of the public `PendingRecordZoneChange`/`PendingDatabaseChange` cases (unknown future cases
  fail closed); `MirrorBootstrapDelegateGate` with terminal latching open/rejected outcomes;
  `MirrorBootstrapReconciler` — proof-gated removals (identity+operation must match a
  `MirrorOutboxRemovalProof`), additions for missing targets, foreign-zone and
  duplicate-record-ID fail-closed, empty-pending-database requirement, exact-reprojection
  verify, live-identity candidate recheck (account/role/zone/marker/engine-zone, owner blocked
  while a participant marker exists), and generation seeding above every recovered intent
  generation. 19 package tests.
- Engine wiring (`HouseholdSyncEngine`): two-phase seam. Gated `init(bootstrapCandidate:)`
  validates identity + `zoneEnsured`, hydrates the store, seeds generations, installs the
  continuing `ShadowMirrorRuntime` on the catalog's writer — all before the `CKSyncEngine`
  exists — then constructs with the bootstrap serialization. One-shot
  `activateBootstrapCandidate()` reconciles direct engine state via public
  `state.remove`/`state.add`, requires exact reprojection + empty database set, then opens the
  gate. Any failure: gate rejected (queued delegate work discards), store cleared, lease
  released, exact scope quarantined, error rethrown for nil-state fallback. All three delegate
  entry points (`handleEvent`, `nextRecordZoneChangeBatch`, new `nextFetchChangesOptions`)
  await the gate; nil-gate control engines take the exact P1 paths (the new
  `nextFetchChangesOptions` returns `context.options`, the SDK default).
- Publication fence is structural: every generation-publishing capture flows through a gated
  delegate callback, so the closed gate defers publication until open/rejected (decisions.md
  2026-07-17).
- Real-engine evidence (`SimmerSmithTests/HouseholdSyncEngineBootstrapTests`, same pinned SDK
  as the probe — Xcode 26.6 (17F113) · iOS sim 26.5): genuine captured serialization → writer
  checkpoint → catalog → gated construction → activation with reconciled pending set exactly
  equal to the durable plan; activation adds a plan operation the serialization predates; an
  unproven serialized pending rejects/quarantines/falls back to a nil-state engine; and the
  closed gate provably held a live `CKSyncEngine` delegate callback (`sendChanges` queued
  behind the gate, drained after open — the released send then failed only on the accountless
  sim's "Not Authenticated", confirming the delegate path genuinely ran).
- Verify: package suite 617 tests ×5; app suite 126 tests; generic iOS build. All green
  2026-07-17.
- Carried forward: read-only-participant `zoneEnsured == false` checkpoints reject+quarantine
  on every launch (safe, wasteful) — P2e/P2f must demote to recovery-only at the catalog or
  revisit participant zone-ensured semantics (decisions.md flag).

## P2e — test-only cached app boot/state

- Shipping policy remains default-off and injected; no UI, TestFlight control, release, schema,
  or build-number change. Gate-off owner/participant construction preserves the P1 nil-state,
  full-fetch, `ownsZone`, repair, repository, and Boolean pending-status behavior.
- Owner selection requires the exact CloudKit account plus one owner/private scope. Participant
  selection requires the exact share marker plus a typed successful fetch proof for that shared
  zone; legacy participant checkpoints are recovery-only. Recovery completes the P1 full fetch
  before atomically validating and overlaying every durable intent.
- Cached boot activates the gated engine, wires repositories, publishes cached authority and
  readiness, then reconciles. Callback relay ordering is serialized; cached authority establishes
  its baseline before buffered authority events drain, while legacy store/repair/status effects
  remain immediate. Epoch and exact-session checks fence every async publication, private-plane
  reload, retry, account change, and participant revocation.
- Cached/recovery save, delete, conflict rebase, sent, acknowledge, delivery-failure, and remote
  deletion transitions fail closed before active mutation or CloudKit handoff. Mixed WAL state is
  retained for restart normalization when a later transition fails. Cached sessions also deny
  repair, manual grocery dedupe, migrations, absence-derived week creation, zone recreation,
  leftover cleanup, and factory reset until durable retirement succeeds.
- Generation leases pin checkpoint and WAL asset roots through `CKSyncEngine` and retained batch
  teardown. Scope/root clear or quarantine writes a durable deferred marker while any process
  lease remains; deinit disposes the engine before releasing its lease or moving asset roots.
- Final correction after the first full signed suite: the WAL-failure test now creates its
  failure-injected writer before cached lease acquisition, matching the intentional prohibition
  on opening a new writer for a leased scope.
- Independent final review: `APPROVED` after complete `git diff HEAD` inspection.
- Verify 2026-07-18:
  - `swift test --package-path SimmerSmithCloudKit` — **632 passed**.
  - `swift test --package-path SimmerSmithKit` — **187 passed, 8 skipped**.
  - signed `xcodebuild test ... -only-testing:SimmerSmithTests` — **152 Swift Testing tests
    passed**; expected accountless-simulator CloudKit logs only.
  - `xcodebuild build ... -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` —
    **BUILD SUCCEEDED**.
  - exact focused P2e regressions and `git diff --check HEAD` — passed.
- Residual release evidence is intentionally deferred: authenticated device behavior and default-on
  remain P2h gates. The temporary local Ballast resolution symlink used for app verification was
  removed and is not part of the candidate.

## P2f — authority, conflict, and lifecycle hardening

- Replaced P2e's blanket data-plane denial with revocable exact-session authority. Cached sessions
  remain denied until the same epoch/session reconciles; lifecycle callbacks synchronously revoke
  authority, wait out in-flight cache mutations, fence later explicit operation results, and emit
  typed account/revocation/owner-zone events. Direct delete/cascade, migration, repair, cleanup,
  and absence-derived creation now share that authority boundary.
- Remote deletion terminally supersedes a pre-authority local save without resurrection; current
  deletes acknowledge normally. Reconciliation promotes only the still-current session, then runs
  the staged migration/repair/system tail once. Failure or teardown abandons the claimed stage for
  a serialized foreground retry instead of duplicating work.
- Account change, participant revocation, and unexpected owner-zone deletion start with one
  non-suspending epoch-first publication teardown. Integrity-bound lifecycle transactions outside
  the mirror root make exact-scope or whole-root invalidation replayable; malformed/conflicting
  transactions block entry. Atomic non-catalog retirement plus synchronized parent directories
  keeps invalidated generations unselectable even if recursive cleanup fails.
- Share adoption durably saves the exact account-bound participant marker before owner parking or
  participant publication. A marker-write failure leaves the owner intact and the join retryable;
  a later adoption failure retains the marker so restart cannot reopen the parked owner scope.
- Factory reset writes its whole-root transaction before invalidation, binds it to the authorizing
  CloudKit account, and validates that account before zone enumeration, immediately before remote
  deletion, after deletion returns, and before replacement discovery/mint. Server failure or an
  identity/epoch change remains visible and cannot report completion or create a household in a
  successor account; tokenless restart replay is idempotent and requires explicit import recovery.
- Independent review found and closed the marker-before-owner-retirement gap, reset deletion account
  race, and post-transaction replacement-mint account race. Final app and package reviews:
  `APPROVED`.
- Verify 2026-07-19:
  - `swift test --package-path SimmerSmithCloudKit` — **673 passed**.
  - `swift test --package-path SimmerSmithKit` — **187 passed, 8 skipped**.
  - focused signed lifecycle regressions — **24 tests in 4 suites passed**.
  - signed `xcodebuild test ... -only-testing:SimmerSmithTests` — **221 tests in 46
    suites passed**; expected accountless-simulator CloudKit logs only.
  - `xcodebuild build ... -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` —
    **BUILD SUCCEEDED**; `git diff --check` clean.
- P1e remains a human device gate, so P2f intentionally adds no named-device/cache-first opt-in and
  makes no release, schema, or build-number change. Shipping default remains off; P2g is next.

## P2g — privacy-safe launch observability and automated local-path evidence

- Added a closed launch-observation vocabulary spanning identity/gate resolution, checkpoint
  selection, validation, bootstrap/store materialization, gate open/reject/quarantine, all eight
  initial household projections, aggregate household readiness, private-plane readiness,
  reconciliation completion, launch-task start, and first `MainTabView` appearance. Package
  observations flow catalog → bootstrap candidate → engine; validation, bootstrap
  materialization, and store hydration retain separate clocks and exclude observer callbacks.
- The app maps those observations to static OS signpost names. Payload construction is fail-closed:
  only event kind, duration, counts, booleans, build, and SDK version are accepted; account or
  household names, recipe text, raw record IDs, hashes, and similarly identifying fields are
  rejected. Signed tests cover projection and gate-source mappings, the privacy allowlist, the
  real `AppState` catalog bridge, DEBUG gate source, stale reconciliation fencing, and
  absent-observer behavior.
- Controller-owned 30-run evidence below uses one genuine nonautomatic `CKSyncEngine`
  serialization and a fresh fixed nine-record cache/session per iteration. Timing begins after
  fixture creation and includes catalog open, gated cached-session construction/start, and the
  eight initial pre-reconciliation projections. Post-run assertions, captured-observation
  aggregation, and session teardown are outside the local-path endpoint; the package observation
  callbacks themselves remain inside it, making the aggregate measurement slightly conservative.
  Median and MAD use the conventional even-sample midpoint; p95 uses nearest rank. Times are
  milliseconds.

| Timing | Median | p95 | MAD |
|---|---:|---:|---:|
| Local cached path | 5.235250 | 11.259625 | 0.344188 |
| Bundle validation | 2.796917 | 4.196208 | 0.225792 |
| Bootstrap materialization | 0.520604 | 0.619625 | 0.032229 |
| Store hydration | 0.142188 | 0.158917 | 0.004812 |
| Recipe projection | 0.138563 | 0.151625 | 0.005042 |
| Metadata projection | 0.189562 | 0.205417 | 0.004750 |
| Week projection | 0.057750 | 0.063500 | 0.001167 |
| Ingredient projection | 0.052500 | 0.058041 | 0.001187 |
| Guest projection | 0.024042 | 0.025833 | 0.000605 |
| Event projection | 0.101937 | 0.108458 | 0.002583 |
| Pantry projection | 0.027708 | 0.030375 | 0.000417 |
| Alias projection | 0.021292 | 0.023500 | 0.000646 |

- These automated in-process samples are component evidence, not §7's physical-device
  force-quit launch-task→`MainTabView` result and not a P1/P2 paired control. ETTrace 1.1.0
  (`e4ff4a8`) also captured an instrumented cold simulator launch: 32.872498 s recorded,
  0.552770 s sampled non-idle activity; focused inclusive samples were SwiftData 0.403051 s,
  `makeSimmerSmithModelContainer` 0.030763 s, and `AppState.loadCachedData` 0.011368 s. The
  accountless iOS 26.5 simulator never reached the verified account-bound cached-household path
  (no bootstrap-selection, `ensureHouseholdSession`, or `MainTabView` frames), so that trace is
  diagnostic only; sampled non-idle time is not launch wall time.
- The measurements demonstrate no whole-store-scan projection cliff on this fixed seed. Because
  the absolute device target was not measured or failed, `simmersmith-8qy` remains a separate
  optimization item and is not added as a P2h blocker. P2h still owns the same-device 30-launch P1
  control/P2 opt-in pair and every named-device gate.
- Environment: Xcode 26.6 (17F113) · Swift 6.3.3 · macOS 26.5.2 (25F84) · iPhoneSimulator SDK
  26.5 · iOS 26.5 runtime (23F77). Independent package and app-task reviews: `APPROVED`, with no
  Critical, Important, or Minor findings after the final benchmark-boundary corrections.
- Verify 2026-07-19:
  - `swift test --package-path SimmerSmithCloudKit` — **675 tests in 10 suites passed**.
  - `swift test --package-path SimmerSmithKit` — **187 tests in 6 suites passed, 10 skipped**.
  - signed `xcodebuild test ... -only-testing:SimmerSmithTests` — **233 tests in 46 suites
    passed**, including the 30-run evidence record.
  - `bash scripts/dev-sim.sh` — **SimmerSmithSim ready**.
  - generic unsigned iOS build — **BUILD SUCCEEDED**; `git diff --check` clean.
- P1e remains `[?]`; shipping default remains off. P2g performs no named-device opt-in, release,
  schema, or build-number change. P2h is next.

## P2h Task 3 — default-off TestFlight vehicle

- Pushed exact non-`[skip ci]` feature commit `e21dadf`; GitHub Actions CI run
  29798528886 completed green. Only then pushed release commit `9008ef6`
  (`chore(release): bump to build 163 [skip ci]`).
- Build 163 has the silent `July 19, 2026` `Under the hood` release-note entry
  (all visible-change arrays empty) and `CURRENT_PROJECT_VERSION: 163`.
- `scripts/release-ios.sh` archived, exported, and uploaded build 163. Its terminal App Store
  Connect processing result was `VALID`. A direct ASC query then confirmed that the non-expired
  build 163 is assigned to the internal `Finklea Dev` beta group.
- The production gate remains `staticDefault: false`; the cache-first toggle is still only a
  DEBUG/TestFlight receipt control.
- Verify 2026-07-20 and reverify 2026-07-21:
  - GitHub Actions CI run 29798528886 for exact feature SHA `e21dadf` — **green**.
  - signed `xcodebuild test ... -only-testing:SimmerSmithTests/ReleaseNotesGateTests` —
    **13 tests passed**.
  - generic unsigned iOS build — **BUILD SUCCEEDED**.
  - signed archive/export/upload — **ARCHIVE SUCCEEDED**, **EXPORT SUCCEEDED**, then ASC
    **VALID**.
  - fresh ASC query — build 163 remains **VALID** and assigned to `Finklea Dev`.
  - CoreDevice independently reported TestFlight `1.0.0 (163)` installed on Roshar (owner) and Sel
    (participant); both apps survived a controller-triggered terminate/relaunch check.
  - user confirmed Settings → Developer → CloudKit checks exposes `Cache-first launch` on both
    devices with the toggle left off. Shipping `staticDefault` remains `false`.
- Task 3 is complete. Task 4 owns the full opt-in device and performance matrix; build 163 has not
  yet passed that matrix and is not evidence for default-on.
