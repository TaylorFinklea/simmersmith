# Household Zone Recovery Specification

## Status

Approved design, 2026-07-25. Implementation is blocked until the user approves this written spec.

## Problem

Build 166 proved the exact-zone boundary is working. Roshar and Sel each produced an anchored owner/private checkpoint for `household-9d154384-34aa-41dc-8f28-1d9e20e662ad` with three records, all in that exact zone: one `HouseholdProfile` and two `Week` records. `zoneEnsured` is true.

The household data previously visible in the app is stranded in the reserved developer zone `household-spc-recipe-test`. The preserved source contains 645 household-zone records, including eight `HouseholdProfile`, 28 `Recipe`, 72 `WeekMeal`, eight `Week`, groceries, recipe children, and managed ingredient records. The old contaminated checkpoint also included 59 Core Data records and seven `coexistence-spike` records; those are outside the source household zone and are never eligible for recovery.

No source record, share, local cache, or CloudKit zone may be deleted or reset. Default-on build 167 and the P2h owner matrix remain blocked until recovery and clean cached resume are physically proven.

## Goal

Recover all user-approved, user-facing household data from the reserved source zone into the genuine production household while preserving relationships and assets, avoiding synthetic fixtures, and remaining idempotent and crash-resumable.

## Non-goals

- No broad or permanent cross-zone reads in normal app launch or sync.
- No source-zone deletion, mutation, tombstoning, cleanup, or rename.
- No share adoption, revocation, participant simulation, or membership automation.
- No Core Data or `coexistence-spike` migration.
- No heuristic write without a user-approved preview manifest.
- No default-on cache-first release.

## Execution Surface

A TestFlight-visible developer recovery tool runs on the signed owner device against the production CloudKit container. It is isolated from normal launch and normal `HouseholdSyncEngine` operation.

The tool has two explicit phases:

1. **Analyze** — read-only; creates a canonical recovery manifest and displays/exports its summary.
2. **Apply approved manifest** — accepts only the exact manifest digest the user approved; performs bounded target-zone writes.

Release/App Store builds without the internal TestFlight developer surface cannot invoke either phase. Analyze and apply must never run automatically during launch.

## Authority and Scope Preconditions

Before analyze or apply:

- Resolve the current CloudKit account record name.
- Prove owner/private authority for the genuine target zone.
- Require source zone name exactly `household-spc-recipe-test` owned by `CKCurrentUserDefaultName` in the private database.
- Require target zone name and owner to equal the active genuine household session.
- Reject equal source and target zone IDs.
- Reject participant/shared sessions.
- Capture a session epoch and revalidate account, target zone, owner role, and epoch before every write batch.
- Freeze/park the normal household session before apply; no concurrent sync or projection mutation may run.

Any failed precondition is a terminal no-write result.

## Analyze Phase

Fetch records directly from the exact source and target zone IDs. Never use database-wide fetch results.

### Eligible records

Only record types in the production household manifest are candidates. Every candidate identity must have the exact source zone ID. Records from Core Data, coexistence, other household zones, CKShare, unknown types, and system records are excluded and counted by reason.

### Dependency closure

Build a graph from production relationships, including CKRecord references and schema-level parent IDs. A selectable root includes its required children and referenced user-facing dependencies. A record with a missing required dependency is blocked, never silently dropped.

### Synthetic classification

Known deterministic developer fixtures and verification-only identifiers are excluded by an explicit, tested catalog. Unknown provenance is not guessed: it appears in the preview as unresolved and is excluded from apply until the user explicitly approves it.

### Target comparison

Rebuild each candidate identity in the target zone while retaining its record name. Compare against the exact target record:

- Target absent: `copy`.
- Target present and canonical user fields equal: `skip-identical`.
- Target present and fields differ: `conflict`.

Conflicts block apply until the approved manifest contains an explicit per-record `source` or `target` decision. There is no implicit last-write-wins policy.

### Manifest

The canonical manifest contains:

- format version;
- current account fingerprint, source zone, target zone, and target household ID;
- source and target change-token/fingerprint inputs used for analysis;
- every candidate identity, record type, action, dependency identities, asset digests, and collision decision;
- excluded counts grouped by reason;
- unresolved and blocked entries;
- deterministic total counts by record type and action;
- a SHA-256 digest over canonical bytes.

The review UI shows human-readable names/dates/counts needed to distinguish real data from fixtures. It never logs account IDs, record IDs, names, meal text, or asset contents to unified logging. The full manifest remains local application data and is not uploaded to an analytics or AI service.

Analyze performs zero CloudKit writes and zero source mutations.

## Approval Gate

Apply requires the user to enter or select the exact analyzed manifest digest. The tool reloads the stored manifest, verifies its digest, and rechecks that every unresolved entry and conflict has an explicit decision.

Immediately before the first write, refetch source and target fingerprints. Any relevant source or target change since analysis invalidates approval and requires a new analyze phase.

## Apply Phase

### Record reconstruction

For every approved `copy` or source-winning conflict:

- Create a new CKRecord in the exact target zone with the original record name and record type.
- Copy only production manifest fields.
- Rewrite every CKRecord.Reference to the corresponding target-zone record ID.
- Recreate CKAssets from verified local bytes and check their SHA-256 digests before upload.
- Preserve application-level IDs, clocks, dates, tombstone fields, and relationship values.
- Never copy CloudKit system fields, change tags, creation metadata, or source-zone IDs.

### Ordering

Apply dependency-safe batches: independent roots/parents first where required by schema, then dependent children. Cycles use deterministic strongly connected groups in one CloudKit modify batch. CKAsset lifetime extends through acknowledgement.

### Receipt and resume

A target-zone `HouseholdRecoveryReceipt` (or the existing project-standard migration receipt type if it can express every invariant) is keyed by the manifest digest and records:

- source and target fingerprints;
- approved item identities/actions;
- completed batch indexes and per-record target digests;
- terminal status and completion timestamp.

Persist receipt progress in the same atomic CloudKit batch as copied records whenever possible. A retry with the same digest refetches target records, verifies completed digests, skips proven work, and resumes the first incomplete batch. A different digest cannot reuse the receipt.

### Failure behavior

- Transient CloudKit failures stop and remain resumable.
- Permission, account, epoch, zone, schema, digest, missing dependency, or changed-input failures stop before the next write.
- A target record whose content differs from both the approved source digest and completed receipt is a conflict and stops recovery.
- No rollback deletes copied records automatically. The source remains the durable rollback reference; any compensating action requires a separate reviewed manifest.

## Post-apply Verification

Before normal sync resumes:

1. Refetch the target zone and compare every approved target digest and relationship.
2. Require no unresolved, blocked, or divergent entries.
3. Tear down stale local household projections/checkpoints without deleting source CloudKit data.
4. Full-fetch the genuine target zone independently on Roshar and Sel.
5. Confirm expected member, weeks, meals, recipes, groceries, and managed ingredients are restored.
6. Confirm both devices converge to equal record counts/digests.
7. Confirm each checkpoint is anchored, owner/private, exact-zone only, and `zoneEnsured=true`.
8. Force-quit and prove cached resume without candidate rejection, new quarantine, wrong-scope flash, or content loss.
9. Restore cache-first overrides OFF.

Only then may `simmersmith-mpa`, `simmersmith-rpz`, and `simmersmith-lrz` close. Cross-account gates and default-on build 167 remain independently blocked.

## Tests

Permanent tests must cover observable contracts:

- exact source/target/account/role preconditions;
- analyze is read-only;
- type allowlist and explicit fixture exclusions;
- dependency closure and missing-dependency blocking;
- stable canonical manifest/digest;
- target absent/identical/conflict classification;
- conflict approval requirement;
- reference and asset rewriting into the target zone;
- source/system field exclusion;
- changed-input invalidation between analyze and apply;
- idempotent retry and partial-batch resume;
- account/epoch change during apply;
- target divergence after a completed receipt;
- no source deletion or mutation path;
- post-apply digest/count verification.

Physical verification uses production TestFlight and preserved device data; simulator fixtures cannot substitute for it.

## Delivery Sequence

1. Implement and review the read-only analyzer and manifest UI/export.
2. Ship a default-off TestFlight build and obtain user approval of the actual production manifest.
3. Implement and review apply/resume behind the exact digest gate.
4. Ship a later default-off TestFlight build; run apply once on the designated owner device.
5. Run post-apply two-device verification and cached-resume gates.
6. Keep source zone preserved until a separate retention decision after release confidence.
