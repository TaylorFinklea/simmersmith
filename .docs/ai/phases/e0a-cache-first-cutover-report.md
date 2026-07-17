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
