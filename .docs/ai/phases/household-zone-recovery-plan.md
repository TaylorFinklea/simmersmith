# Household Zone Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Safely preview, approve, and idempotently copy all user-approved household data from the reserved `household-spc-recipe-test` zone into the genuine production household without mutating the source.

**Architecture:** A pure recovery-plan core canonicalizes identities, dependencies, actions, conflicts, approvals, and digests. An injected CloudKit transport performs exact-zone reads and target-only writes. The TestFlight developer surface exposes a read-only analyzer first; apply ships only after the user approves the actual production manifest digest. A target-zone receipt makes apply crash-resumable and idempotent.

**Tech Stack:** Swift 6.2, CloudKit, Swift Testing, SwiftUI, existing `HouseholdRecords` manifest/codecs, SHA-256 helpers, TestFlight `DebugGate`.

## Global Constraints

- Source zone is exactly private/owner `household-spc-recipe-test`; target is the active genuine owner/private household zone.
- No source record, share, local cache, or CloudKit zone may be deleted, reset, renamed, or mutated.
- Normal launch and `HouseholdSyncEngine` remain exact-zone; recovery is an explicit TestFlight-only tool.
- Analyze performs zero writes.
- Apply accepts only an approved canonical manifest digest and invalidates approval when source or target inputs change.
- Core Data, `coexistence-spike`, CKShare, unknown types, other zones, and system records are ineligible.
- Conflicting target records require an explicit per-record source/target decision; no implicit LWW.
- Preserve record names and application fields; rebuild target-zone identities, references, and assets; never copy CloudKit system fields.
- Apply is idempotent and crash-resumable through a target-zone receipt; source remains the rollback reference.
- Build 167 remains blocked default-on. Every recovery vehicle keeps `CacheFirstLaunchPolicy.staticDefault == false`.
- Do not run apply or any production CloudKit write before the explicit Task 6 approval gate.

---

## Phase A — Read-only production preview

### Task 1: Canonical recovery plan model

**Files:**
- Create: `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdZoneRecoveryPlan.swift`
- Create: `SimmerSmithCloudKit/Tests/HouseholdSyncTests/HouseholdZoneRecoveryPlanTests.swift`

**Interfaces:**
- Produces `HouseholdZoneRecoveryIdentity`, `HouseholdZoneRecoveryAction`, `HouseholdZoneRecoveryDecision`, `HouseholdZoneRecoveryEntry`, `HouseholdZoneRecoveryExclusion`, `HouseholdZoneRecoveryManifest`, and `HouseholdZoneRecoveryApproval`.
- Produces canonical JSON bytes and SHA-256 digest from one manifest.
- The manifest initializer rejects duplicate identities, unresolved conflicts, missing dependencies, cross-zone identities, unstable ordering, and invalid source/target scope.

- [ ] **Step 1: Write failing tests for canonical identity and ordering**

Cover exact owner+zone identity, source-to-target identity projection, deterministic ordering independent of input order, and duplicate rejection. Follow `ShadowMirrorCanonicalDigest` test conventions; do not reimplement its byte encoding ad hoc.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryPlanTests`

Expected: compile failure because recovery-plan types do not exist.

- [ ] **Step 3: Implement immutable plan value types**

Use explicit `Codable`, `Equatable`, and `Sendable` values. Canonical entries sort by record type, source owner, source zone, and record name. Exclusions sort by reason then count. The digest covers format version, account fingerprint, source/target IDs, input fingerprints, entries, decisions, dependencies, asset digests, and exclusions.

- [ ] **Step 4: Add failing invariant tests**

Cover source==target, non-owner/private scope, candidate outside exact source, target identity outside exact target, unresolved conflict, missing dependency, duplicate record, and approval digest mismatch.

- [ ] **Step 5: Implement validation and approval verification**

Expose one throwing initializer/factory for a validated manifest and one method that verifies `HouseholdZoneRecoveryApproval.manifestDigest` byte-for-byte against the manifest.

- [ ] **Step 6: Run focused tests and commit**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryPlanTests`

Expected: PASS.

Commit: `feat(cloudkit): model canonical household recovery plans`

---

### Task 2: Production schema classification and dependency closure

**Files:**
- Create: `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdZoneRecoveryClassifier.swift`
- Create: `SimmerSmithCloudKit/Tests/HouseholdSyncTests/HouseholdZoneRecoveryClassifierTests.swift`
- Read before implementation: `SimmerSmithCloudKit/Sources/HouseholdRecords/` codecs and manifest definitions; `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdMigrationRunner.swift`.

**Interfaces:**
- Consumes source-zone `CKRecord` snapshots and the Task 1 identity model.
- Produces eligible records, explicit exclusions, dependency edges, unresolved provenance, and blocked missing dependencies.
- Maintains one explicit catalog of supported production record types and known deterministic developer fixtures.

- [ ] **Step 1: Write failing type-eligibility tests**

Enumerate every production household record type from the existing manifest. Assert CKShare, Core Data types, `coexistence-spike`, unknown types, migration/recovery system records, and foreign-zone records are excluded with distinct reasons.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryClassifierTests`

- [ ] **Step 3: Implement the explicit supported-type and fixture catalogs**

Derive the supported list from the existing production manifest pattern rather than inventing a second schema. Keep fixture identifiers explicit and tested. Unknown provenance remains unresolved; never infer from timestamps alone.

- [ ] **Step 4: Write failing dependency-closure tests**

Cover recipe→ingredients/steps/images, week→meals→meal ingredients, grocery/event links, managed ingredient relationships, profile/settings membership, missing required parents, optional references, and cycles.

- [ ] **Step 5: Implement deterministic graph closure**

Return dependency-closed selectable groups. Required missing nodes block their dependents. Cycles become deterministic strongly connected groups. No record is silently dropped.

- [ ] **Step 6: Run focused tests and commit**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryClassifierTests`

Expected: PASS.

Commit: `feat(cloudkit): classify stranded household records`

---

### Task 3: Read-only exact-zone analyzer

**Files:**
- Create: `SimmerSmithCloudKit/Sources/CloudKitProvisioning/HouseholdZoneRecoveryTransport.swift`
- Create: `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdZoneRecoveryAnalyzer.swift`
- Create: `SimmerSmithCloudKit/Tests/HouseholdSyncTests/HouseholdZoneRecoveryAnalyzerTests.swift`
- Modify: `SimmerSmithCloudKit/Package.swift` only if target dependencies require the existing module boundary to be wired explicitly.

**Interfaces:**
- `HouseholdZoneRecoveryTransport` protocol: exact-zone fetch, per-record target lookup, asset-byte access, input fingerprint, and no write methods in the analyzer-facing interface.
- Analyzer consumes proven account/source/target scope plus the transport; produces a validated Task 1 manifest and human-readable preview summary.

- [ ] **Step 1: Write a recording transport and failing no-write tests**

Assert analyze calls only exact source/target zone reads; rejects database-wide or mismatched-zone results; never invokes a mutation capability; and emits exclusion counts without record contents in diagnostics.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryAnalyzerTests`

- [ ] **Step 3: Implement exact-zone CloudKit fetch using existing operation patterns**

Mirror `HouseholdZoneProvisioner`'s continuation/error handling, but constrain every operation to the supplied zone ID. Fetch complete record pages and asset bytes. The transport must fail closed on partial zone results or unreadable required assets.

- [ ] **Step 4: Write failing target-action tests**

Cover target absent→copy, canonical equality→skip-identical, difference→conflict, source change fingerprint, target change fingerprint, unreadable asset, asset digest, and stable manifest digest.

- [ ] **Step 5: Implement analyzer assembly**

Use Task 2 classification/closure, reconstruct projected target identities without writing, compare canonical application fields, and build Task 1 manifest. Do not compare CloudKit system fields.

- [ ] **Step 6: Run focused and package tests; commit**

Run:
- `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryAnalyzerTests`
- `swift test --package-path SimmerSmithCloudKit`

Expected: PASS.

Commit: `feat(cloudkit): analyze stranded household recovery`

---

### Task 4: TestFlight preview and local approval artifact

**Files:**
- Create: `SimmerSmith/SimmerSmith/Features/Settings/HouseholdZoneRecoveryView.swift`
- Create: `SimmerSmith/SimmerSmithTests/HouseholdZoneRecoveryViewModelTests.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/CloudKitDebugView.swift`
- Modify the existing app-state/session boundary that owns exact current account, owner role, active zone, and epoch; find and mirror its current authority-check pattern before editing.

**Interfaces:**
- A `@MainActor` view model exposes idle/analyzing/preview/failed states, manifest digest, grouped counts, human-readable record labels/dates, exclusions, unresolved entries, conflicts, and dependency-blocked entries.
- Stores the full approved manifest only in application support; unified logging receives event names and counts only.

- [ ] **Step 1: Write failing view-model authority and redaction tests**

Cover TestFlight gate, owner/private requirement, exact source/target IDs, epoch capture, analyze cancellation, no approval when unresolved/conflicts remain, and privacy-safe error/output strings.

- [ ] **Step 2: Verify RED**

Run the exact `HouseholdZoneRecoveryViewModelTests` app-target test destination used by `scripts/dev-sim.sh`.

- [ ] **Step 3: Implement the preview view model and local manifest store**

Use the existing `DebugGate`, AppState authority snapshot, and app support storage conventions. Persist canonical manifest bytes and digest atomically. Do not add an apply button in this task.

- [ ] **Step 4: Implement the preview UI**

Add one developer-panel entry: `Household data recovery — Analyze`. Show grouped candidate/copy/identical/conflict/excluded/blocked counts and reviewable names/dates. Provide explicit source/target decisions for conflicts and explicit include/exclude decisions for unresolved provenance; changing a decision creates a new canonical digest.

- [ ] **Step 5: Run app tests and unsigned build; review**

Run:
- focused app-target recovery tests;
- `swift test --package-path SimmerSmithCloudKit`;
- `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`.

Obtain independent package and app reviews. Fix every Critical/Important finding and rerun affected commands.

- [ ] **Step 6: Commit**

Commit: `feat(ios): preview stranded household recovery`

---

### Task 5: Ship analyzer and approve the real manifest

**Files:**
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift`
- Modify: `SimmerSmith/project.yml`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`
- Modify: `.docs/ai/current-state.md`
- Modify: `.docs/ai/phases/e0a-cache-first-cutover-report.md`

- [ ] **Step 1: Require exact feature SHA CI**

Push the reviewed non-`[skip ci]` analyzer commit. Require exact commit SHA success for `SimmerSmithCloudKit`, `SimmerSmithKit`, generic iOS build, and app-target tests.

- [ ] **Step 2: Cut a separate default-off analyzer build**

Add a silent release note, increment build number, preserve `staticDefault=false`, regenerate, run release-note tests, commit `[skip ci]`, archive/export/upload, require ASC `VALID`, and confirm Finklea Dev all-build access.

- [ ] **Step 3: Install over preserved Roshar data and run Analyze only**

Do not reset, change sharing, or invoke apply. Export the local preview summary and manifest digest. Independently compare its type/action/exclusion counts against the pulled build-166 evidence.

- [ ] **Step 4: User approval gate — STOP**

Present the actual preview, unresolved provenance choices, conflicts, and digest to the user. Apply implementation may proceed only after the user approves the exact manifest and decisions. Record approval in `.docs/ai/current-state.md` and the recovery report; never put record names or meal text into git-tracked docs.

---

## Phase B — Approved target-only apply

### Task 6: Target-zone reconstruction and receipt model

**Prerequisite:** Task 5 exact production manifest approval is recorded. Without it, do not start.

**Files:**
- Create: `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdZoneRecoveryApplyPlan.swift`
- Create: `SimmerSmithCloudKit/Tests/HouseholdSyncTests/HouseholdZoneRecoveryApplyPlanTests.swift`
- Read before implementation: `HouseholdSyncEngine.applyFields`, `ShadowMirrorRecordEnvelope`, image codecs, and `HouseholdMigrationRunner` receipt conventions.

**Interfaces:**
- Produces target-zone reconstructed records, deterministic dependency batches, and a versioned target-zone receipt keyed by manifest digest.
- Input is only a validated manifest plus matching approval; no analyzer rerun is implicit.

- [ ] **Step 1: Write failing record reconstruction tests**

Cover stable record names, exact target zone, every CKRecord.Reference rewrite, production-field allowlist, system-field exclusion, scalar/list/date/data preservation, asset restaging/digest verification, and unsupported value rejection.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryApplyPlanTests`

- [ ] **Step 3: Implement reconstruction by mirroring existing codecs/field-copy rules**

Do not prescribe a new field schema. Reuse the production manifest and the existing record-value canonicalization patterns. Stage assets under an application-support recovery directory whose lifetime extends through CloudKit acknowledgement.

- [ ] **Step 4: Write failing batch/receipt tests**

Cover deterministic dependency batches, SCC cycles, receipt identity by digest, completed batch digests, same-digest resume, different-digest refusal, target divergence, and terminal completion.

- [ ] **Step 5: Implement apply plan and receipt values**

Use the existing migration receipt record type only if it can express every spec invariant without overloading legacy semantics; otherwise add `HouseholdRecoveryReceipt` to the production manifest and all manifest tests.

- [ ] **Step 6: Run focused tests and commit**

Commit: `feat(cloudkit): plan idempotent household recovery apply`

---

### Task 7: Exact target-only apply engine

**Files:**
- Create: `SimmerSmithCloudKit/Sources/HouseholdSync/HouseholdZoneRecoveryApplier.swift`
- Create: `SimmerSmithCloudKit/Tests/HouseholdSyncTests/HouseholdZoneRecoveryApplierTests.swift`
- Modify: `HouseholdZoneRecoveryTransport.swift` by adding a separate apply-capable protocol; keep analyzer dependency read-only.

**Interfaces:**
- Consumes validated manifest, exact approval, current authority snapshot, and Task 6 apply plan.
- Produces progress, resumable stop, conflict, or verified completion. Writes only target records and target receipt.

- [ ] **Step 1: Write failing preflight tests**

Cover manifest digest, source/target input fingerprints, owner/private account and epoch, parked normal session, source!=target, unresolved decisions, and zero writes on any failure.

- [ ] **Step 2: Verify RED**

Run: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryApplierTests`

- [ ] **Step 3: Implement preflight and session fence**

Mirror the existing lifecycle transaction/authority fencing pattern. Refetch exact source/target fingerprints immediately before first write. Do not create a parallel authority mechanism.

- [ ] **Step 4: Write failing batch/resume tests**

Use a recording transport to prove target-only writes, no source mutations/deletes, receipt+records atomicity, transient stop/resume, partial batch retry, completed target digest verification, changed target conflict, changed account/epoch stop, and asset lifetime.

- [ ] **Step 5: Implement bounded apply and post-apply verification**

Write dependency batches and receipt progress. Never auto-rollback or delete. On completion, exact-zone refetch every approved identity and compare canonical digests/relationships before marking terminal success.

- [ ] **Step 6: Run focused/full tests and independent review; commit**

Run focused applier tests, full `SimmerSmithCloudKit`, app-target tests, and generic unsigned iOS build. Obtain independent CloudKit/data-loss and silent-failure reviews.

Commit: `feat(cloudkit): apply approved household recovery`

---

### Task 8: TestFlight apply UI and production recovery

**Files:**
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/HouseholdZoneRecoveryView.swift`
- Modify: corresponding view-model tests
- Modify release metadata and durable handoff/report files

- [ ] **Step 1: Write failing apply-UI tests**

Cover exact digest confirmation, disabled apply before approval, authority/epoch changes, progress, resumable failure, conflict, success, and inability to trigger from normal launch/App Store gate.

- [ ] **Step 2: Implement explicit apply control**

Require the exact approved digest, destructive-action confirmation language that states source is preserved, and a second authority recheck. Keep all details local and logs count-only.

- [ ] **Step 3: Verify, review, and ship a new default-off recovery build**

Run full package/app verification, exact feature SHA CI, separate release bump, ASC `VALID`, and preserved-data installation. Keep default-on blocked.

- [ ] **Step 4: Apply once on designated owner device**

Capture preflight fingerprints and counts, run apply, retain receipt and source, and stop on any conflict/error. Do not retry with a changed manifest.

- [ ] **Step 5: Run post-apply two-device proof**

Full-fetch Roshar and Sel. Verify expected member, weeks, meals, recipes, groceries, managed ingredients, equal target counts/digests, anchored owner/private checkpoints, exact-zone records only, and `zoneEnsured=true`.

- [ ] **Step 6: Prove cached resume and close recovery blockers**

With override ON, require the complete cached-launch signpost chain and no rejection/quarantine/wrong-scope flash/content loss. Restore overrides OFF. Close `simmersmith-mpa`, then `simmersmith-rpz`/`simmersmith-lrz` only when their original acceptance gates pass. Keep cross-account and default-on gates blocked.

- [ ] **Step 7: Commit durable evidence**

Update `.docs/ai/current-state.md`, `.docs/ai/roadmap.md` only if the durable product arc changed, and `.docs/ai/phases/e0a-cache-first-cutover-report.md`. Commit without private record names/content.

## Plan Self-review

- Spec coverage: authority, read-only analyze, explicit classification, dependency closure, canonical digest, collision approval, source preservation, target reconstruction, references/assets, receipts/resume, failures, physical verification, and staged delivery are each assigned to a task.
- Placeholder scan: no TBD/TODO/follow-up placeholders; Task 5 is an explicit human approval gate, not deferred implementation.
- Type consistency: Task 1 manifest/approval feed Tasks 3–8; Task 3 read-only transport remains separate from Task 7 apply capability; Task 6 apply plan and receipt feed Task 7.
