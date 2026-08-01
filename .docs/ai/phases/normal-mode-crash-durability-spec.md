# Normal-Mode Crash Durability

Issue: `simmersmith-9w4`
Status: implemented; awaiting device verification
Threat model: process termination after an accepted local mutation

## Goal

- Cache-first remains presentation/performance only; shipping `.normal` mutations are durable.
- Accepted save/delete intent survives immediate process death for owner and participant sessions.
- Cache-first OFF relaunches from canonical CloudKit data, then overlays exact-scope recovery before ready.

## State model

- Mutation durability is independent of `HouseholdDataPlaneMode`:
  - `bestEffort`: unscoped diagnostic/test construction only.
  - `required`: exact-scope writer/runtime installed before `CKSyncEngine` construction.
  - `recoveryPending`: durability required, no writer yet, every mutation rejected until recovery installs it.
- Startup chooses exactly one branch:
  - cached candidate: existing gated cached activation;
  - recovery candidate: false authority -> nil-state full fetch -> recovery overlay/writer -> authority promotion;
  - ordinary normal: required writer/runtime -> nil-state full fetch -> authority promotion.
- One writer/runtime owns a session. Recovery never pre-creates a replacement writer.

## Recovery selection

- Catalog input adds `cachedAllowed` vs `recoveryOnly` selection.
- `recoveryOnly` validates the same account/role/zone ladder and uses normalized
  `recoveryState.outbox`, including checkpoint-carried and terminal blocked intent.
- Nonempty normalized outbox -> recovery plan with no renderable records or engine serialization.
- Empty normalized outbox -> no candidate; never replay checkpoint records.
- Owner ambiguity, participant marker mismatch, corrupt scope, and unknown identity fail closed.

## Mutation and delivery invariants

- Reuse the existing `shadowMirrorLock` ordering:
  WAL append+sync -> generation increment -> store mutation -> CKSyncEngine pending enqueue.
- Append/setup failure changes neither store nor pending state, fences the runtime, and surfaces a
  cache-neutral durability intervention.
- Preserve existing sent-before-handoff, acknowledgement/failure transitions, crash normalization,
  checkpoint high-water compaction, stale-generation handling, and lifecycle fencing.
- AppState-resolved identity is canonical. Remove the later fire-and-forget identity lookup and mirror attach.
- Recovery/full-fetch failure leaves the session unavailable/offline, preserves retryable durable intent,
  and never falls back to checkpoint presentation.

## Tests and acceptance

- Required normal writer exists before engine callbacks; writer-open/append failure rejects mutation.
- Recovery-pending mutation rejects before apply; apply uses the candidate writer exactly once.
- Save and delete replay over canonical fetched state after engine destruction.
- Acknowledged intent is absent from the next recovery selection.
- Current generation + nonempty outbox selects recovery-only; empty outbox selects none.
- Cache-allowed behavior stays unchanged; owner/participant scope mismatch stays unselected.
- Package verification: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit`.
- App verification: full-Xcode app tests/build when the external `ballast/` checkout is present.
- Human TestFlight gate, cache-first OFF, owner + participant: add/kill/relaunch persists; delete/kill/relaunch stays deleted.

## Explicit exclusions

- No backend, CloudKit schema, database, or network API change; cache-first default remains OFF.
- No redesign of post-write fsync ambiguity, power-loss/F_FULLFSYNC semantics, checkpoint-publication
  health, checksum-torn tails, or store-absent cascade deletion.
- Adversarial review: `opencode-go/kimi-k3` and `ollama-cloud/glm-5.2` both returned
  `ACCEPT WITH REQUIRED CHANGES`; adopted amendments are branch exclusivity, normalized-outbox
  selection, false authority through recovery, single-writer ownership, and explicit ack retirement.
