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
