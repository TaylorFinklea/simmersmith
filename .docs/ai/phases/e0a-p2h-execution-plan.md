# e0a P2h Device Gate and Default-On Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove cache-first launch on real owner and participant devices, then enable the shipping
default and release it only after every automated, adversarial, identity, crash, convergence,
token-resume, and performance gate passes.

**Architecture:** P2h is a serial hard-gate sequence with no cache architecture changes. Build 161
exposed a CloudKit delegate-context crash during the pre-existing P1e shadow-mirror device gate, so
build 162 is a crash-only, default-off hotfix vehicle for finishing P1e. A separate default-off
TestFlight vehicle then exposes the existing receipt-gated `sm.cacheFirstLaunchOverride` only inside
the DEBUG/TestFlight developer panel, allowing the same seeded build/device to supply paired P1 and
P2 measurements. The shipping default changes in a later feature commit only after the device
matrix and two independent Lead reviews are clean; release bookkeeping remains separate and
controller-owned.

**Tech Stack:** Swift 6.3.3, SwiftUI, CloudKit/CKSyncEngine, Swift Testing, Xcode 26.6,
CoreDevice/Instruments, GitHub Actions, App Store Connect/TestFlight.

## Global Constraints

- P2h makes no cache architecture changes; `simmersmith-8qy` remains separate.
- Shipping cache-first stays default-off until P1e, the complete P2 device matrix, genuine token
  resume, two-device convergence, adversarial reviews, and performance targets all pass.
- Never weaken or cache account identity to make offline launch or performance appear successful.
- App Store receipts ignore the local override; only DEBUG and sandbox/TestFlight receipts may use
  it. The internal control is never reachable in an App Store build.
- Performance evidence is at least 30 force-quit launches for P1 control and 30 for P2 opt-in on
  the same seeded device/build. Report conventional median and MAD plus nearest-rank p95.
- P2 absolute acceptance is median <= 1.0 s and p95 <= 1.5 s from launch task to first
  `MainTabView`. If P1 median is at least 2.0 s, P2 must also improve it by at least 75%.
- Release operations, credentials, build-number edits, pushes, TestFlight assignment, and installed
  build checks are controller-owned. Workers and reviewers receive no authority for them.
- Push the non-`[skip ci]` feature commit and wait for its exact CI run before pushing a release
  bookkeeping commit whose message contains `[skip ci]`.
- Any unexplained digest mismatch, quarantine, cross-scope flash, lost/duplicate delivery, stale
  callback publication, or unresolved Critical/Important review finding stops P2h.
- Record lack of offline account identity as a platform limitation and fall back to full fetch;
  never infer identity from cached household data.

---

### Task 1: Repair the build-161 reconnect crash and close P1e on signed TestFlight build 162

**Ownership:** Root controller plus the user handling the physical device. No worker receives
release, build-number, installed-app, or device authority.

**Files:**
- Modify: `SimmerSmithCloudKit/Sources/HouseholdSync/RepairScheduler.swift`
- Modify: `SimmerSmithCloudKit/Tests/HouseholdSyncTests/RepairSchedulerTests.swift`
- Modify: `SimmerSmith/project.yml`
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`
- Modify: `.docs/ai/phases/e0a-shadow-mirror-report.md`
- Modify: `.docs/ai/current-state.md`

**Interfaces:**
- Consumes: the preserved build-161 crashes and app state, its existing owner/private household,
  the build-157 35-flush latency record, and the repaired grocery merge path.
- Produces: a detached scheduler-owned debounce boundary, terminal build-162 ASC `VALID`, current
  signed-device online/offline/relaunch/reconnect/no-new-quarantine evidence, and an `[x]` P1e
  prerequisite. Cache-first remains default-off.

- [x] **Step 1: Capture the failure and prove the exact root cause**

Preserve both build-161 crash reports and the app container before replacement. Symbolicate against
the exact build-161 dSYM and exact device CloudKit symbols. Require the repeated crash to resolve to
`RepairScheduler` repair work calling `CKSyncEngine.sendChanges()` from inherited delegate-callback
task context, not to corrupt mirror bytes or overlapping explicit operations.

- [x] **Step 2: Add the regression first, apply the narrow fix, and review it**

Add a Swift task-local regression that fails when the scheduler-owned debounce uses ordinary
`Task {}` and passes only when it detaches from the caller. Change only that owned debounce task to
`Task.detached`; retain stored-task cancellation, MainActor repair closures, pass ordering,
single-flight draining, lifecycle fences, and automatic sync. Run both Swift packages, the signed
app-target suite, the generic iOS build, and `git diff --check`; require independent review approval.

- [x] **Step 3: Land the hotfix feature commit and require exact CI**

Commit `fix(cloudkit): detach repair work from sync callbacks`, fast-forward it to `main`, push, and
require the GitHub Actions run whose head SHA is that non-`[skip ci]` commit to finish green before
release bookkeeping.

Landed as `ea15406`; deterministic CI follow-up `d18f3af` and private Ballast checkout restoration
`9f8f39e` followed without changing production behavior. Exact run `29717363663` at full SHA
`9f8f39e44e189d95cb2c83adb9718441c00a27d9` passed both Swift packages, the generic iOS build,
and the signed app-target suite.

- [x] **Step 4: Cut and install crash-only TestFlight build 162**

Add build 162 dated `July 19, 2026`, headline `A steadier grocery sync`, with one `fixed` entry:
`The app no longer closes unexpectedly while syncing grocery changes after you reconnect.` Keep
the cache-first static default false. Set `CURRENT_PROJECT_VERSION: 162`, regenerate the project,
run release-note tests and the generic build, commit
`chore(release): cut crash hotfix build 162 [skip ci]`, push, run `scripts/release-ios.sh`, require
terminal ASC `VALID`, confirm internal Finklea Dev assignment, and install build 162 on Roshar.

Release commit `ae029f7` is pushed. The signed archive and upload succeeded; App Store Connect
reports build 162 `VALID` and its Finklea Dev assignment is present. Roshar device inspection
confirmed build 162 installed.

- [x] **Step 5: Repeat the P1e control and shadow-durability path**

Force-quit and cold-launch the existing owner household with cache-first still off. Prove the normal
full-fetch control path, online edit/delete, offline save/delete, force-quit/relaunch, and reconnect.
Confirm pending shadow intents remain durable without hydrating the active store, the duplicate Week
repair completes without a new crash, and no active full-fetch content disappears or duplicates.

Roshar build 162 remained alive through the user relaunch and a second instrumented launch. Its
authoritative full-fetch UI stayed server-rendered; the mirror retained the two pending grocery saves
for later P2 replay, resolved the already-absent delete, and created no quarantine.

- [x] **Step 6: Inspect durability evidence and close the gate**

Capture the signed-device logs and mirror outcome. Require every offline mutation to be either
server-resolved or retained as an exact pending shadow intent, with no digest mismatch or
quarantine. P1 does not re-enqueue those intents; the build-163 P2 gate must drain them. Append the
exact device result to
`e0a-shadow-mirror-report.md`, change P1e to `[x]` in `current-state.md`, close
`simmersmith-e0a.1`, rerun the CloudKit package and generic iOS build, then commit
`docs(ai): close e0a p1e device gate`.

---

### Task 2: Add the DEBUG/TestFlight-only cache-first opt-in control

**Prerequisite:** Task 1 is committed with P1e `[x]`. Do not start earlier.

**Files:**
- Modify: `SimmerSmith/SimmerSmith/App/DebugGate.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/CloudKitDebugView.swift`
- Modify: `SimmerSmith/SimmerSmithTests/P2eCachedBootTests.swift`

**Interfaces:**
- Consumes: `AppState.cacheFirstLaunchOverrideKey`, `CacheFirstLaunchPolicy`, and the existing
  Settings -> Developer -> CloudKit checks surface.
- Produces: a persistent internal toggle that changes only the existing install override and takes
  effect after force-quit/relaunch; App Store remains unable to display or honor it.

- [x] **Step 1: Add failing visibility and receipt-policy tests**

Add table-driven tests proving the developer surface resolves visible for DEBUG and
`sandboxReceipt`, hidden for `receipt` and unknown release receipts, and proving an App Store
receipt ignores both `true` and `false` local overrides while `staticDefault` is false. Run the
focused `P2eLaunchPolicyTests`; require the new visibility seam test to fail before implementation.

- [x] **Step 2: Expose a pure DebugGate visibility seam**

Refactor `DebugGate.showsCloudKitChecks` through an internal pure resolver taking `isDebug: Bool`
and `receiptFilename: String?`. It returns true only for DEBUG or `sandboxReceipt`; the live
property supplies compile configuration plus `Bundle.main.appStoreReceiptURL?.lastPathComponent`.
Run the focused tests and require them to pass.

- [x] **Step 3: Add the internal toggle**

In `CloudKitDebugView`, bind `@AppStorage(AppState.cacheFirstLaunchOverrideKey)` to a Boolean and
add a developer section with a `Toggle` labeled `Cache-first launch`. Its footer must say that it
is an internal TestFlight control and requires force-quit/relaunch. Do not add another persistence
key, settings route, launch argument, device allowlist, or App Store-visible affordance.

- [x] **Step 4: Verify and commit the feature**

Run both Swift packages, the signed `SimmerSmithTests` suite, the generic iOS build, and
`git diff --check`. Commit `feat(ios): add internal cache-first launch gate`. Generate a task review
package and require separate `Spec compliance: APPROVED` and `Task quality: APPROVED` verdicts.

Completion evidence: strict RED for the missing resolver; focused policy tests 4/4 green; CloudKit
676, Kit 187, signed app 234 tests; generic iOS build and diff check green; independent spec and
quality reviews APPROVED; feature commit `e21dadf`.

---

### Task 3: Cut default-off TestFlight build 163

**Ownership:** Root controller only.

**Files:**
- Modify: `SimmerSmith/project.yml`
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`
- Modify after external verification: `.docs/ai/current-state.md`
- Modify after external verification: `.docs/ai/phases/e0a-cache-first-cutover-report.md`

**Interfaces:**
- Consumes: reviewed Task-2 feature commit and `scripts/release-ios.sh`.
- Produces: a silent build-163 release-note entry, terminal ASC `VALID`, internal Finklea Dev
  assignment, and an installed default-off opt-in test vehicle.

- [x] **Step 1: Push and gate the feature commit**

Fast-forward the reviewed feature commit to `main`, push `main`, select the GitHub Actions run whose
head SHA is that non-`[skip ci]` feature commit, and require it to finish green.

- [x] **Step 2: Bump build 163 mechanically**

Add a silent `ReleaseNote` for build 163 dated `July 19, 2026` with headline `Under the hood` and
empty `new`, `improved`, and `fixed` arrays. Set `CURRENT_PROJECT_VERSION: 163`, regenerate with
`xcodegen generate --spec SimmerSmith/project.yml`, run the release-note tests and generic build,
then commit `chore(release): bump to build 163 [skip ci]`.

- [x] **Step 3: Push, upload, assign, and install**

Push the release commit only after Task 3 Step 1 is green. Run `scripts/release-ios.sh` from the
main checkout, require terminal ASC `VALID`, confirm internal Finklea Dev assignment, install build
163 on the named owner and participant devices, and verify Settings -> Developer -> CloudKit checks
contains the cache-first toggle. Shipping static default must still be false.

---

### Task 4: Cut default-off owner-repair TestFlight build 164

**Ownership:** Root controller only. Preserve installed data and share membership.

- [x] **Step 1: Repair and verify the production namespace defect**

Legacy developer IDs are launch-ineligible, discovery partitions them before census, automatic
cleanup excludes them, explicit factory reset still recognizes them, and developer checks now use
`simmersmith-verification-*`. Repair commit `f41c3e9`; exact CI run `29959784936` green.

- [x] **Step 2: Cut and upload build 164**

Add a silent build-164 release note, keep `CacheFirstLaunchPolicy.staticDefault` false, set
`CURRENT_PROJECT_VERSION: 164`, regenerate with xcodegen, run release-note tests plus the generic
unsigned build, and commit/push the separate `[skip ci]` release bump. Archive/export/upload;
require terminal ASC `VALID` and Finklea Dev assignment.

- [!] **Step 3: Install over preserved owner data — build 164 rejected**

Install build 164 on Roshar and Sel without wiping data, factory reset, or share changes. With the
override OFF, require the same visible production household, normal full-fetch launch, no
verification-only household mint, no new quarantine, and no cross-scope flash.

Build 164 is ASC VALID, assigned to Finklea Dev, and installed on Roshar/Sel. The first Roshar
override-OFF launch retained expected meals/recipes but no longer showed the wife/member. No reset
or share automation ran. `simmersmith-fkn` must prove the root cause before Step 4 or Task 5.

Roshar/Sel override-ON visual launches fell back safely, but Sel quarantined the genuine owner
scope. Its checkpoint declared the genuine zone while 711/712 records belonged to unrelated
private-database zones. Exact-zone fence commit `bce2d8a` and CI run `30058965856` are green.
Build 164 cannot satisfy Step 3 or 4; build 165 is the fresh default-off proof vehicle.

- [!] **Step 4: Prove exact owner/private cached launch — blocked on clean exact-zone checkpoint**

On each device, enable the override and force-quit/manual-foreground with USB logging. Require
`bootstrap_checkpoint_selected` → `bootstrap_bundle_validated` → `bootstrap_materialized` →
`bootstrap_store_materialized` → `bootstrap_gate_opened` → all initial `projection_ready_*` →
`projections_ready` → `main_tab_visible`, with no `bootstrap_candidate_rejected`, no quarantine,
and content matching the override-off baseline. Locally verify anchor role owner, database private,
and zone owner equal to the current CloudKit account; track Boolean results only. Restore both
overrides OFF and force-quit.

---

### Task 5: Run build-164 owner-representative P2h rows

- [ ] **Step 1: Owner online and offline launch**

Run Roshar online cached launch, then seed online, force-quit, disable networking, and run one
offline launch. If CloudKit cannot prove identity offline, require privacy-safe full-fetch fallback
without cached content flash. Run Sel owner-online against the same production household.

- [ ] **Step 2: Mutation and crash recovery**

On one owner device using exact reviewed source and USB logging, exercise pending saves/deletes and
force termination around record-first/state-second, supersede, and restart-retry boundaries.
Reconnect with no loss, resurrection, duplicate delivery, stuck `sent` row, or unexplained
quarantine.

- [ ] **Step 3: Lifecycle, token, and convergence**

Mark account-boundary switching environment-blocked if the owner account cannot be safely restored;
do not force it. Capture genuine token resume with one post-checkpoint remote change and prove no
pre-token replay plus later state/publication advance. Make known offline edits/deletes on Roshar
and Sel, reconnect, and require identical final records with no pending duplicates.

- [ ] **Step 4: Paired launch distribution**

On one seeded owner device, manually foreground 30 force-quit launches with override OFF and 30
with override ON. Report every sample plus conventional median/MAD and nearest-rank p95. Enforce
the existing absolute and relative P2 thresholds.

---

### Task 6: Keep cross-account/default-on work blocked

A real physical participant device signed into a different Apple Account must accept the existing
production share and complete participant/shared cache, owner share-adopt, participant revocation,
remaining convergence, and final default-off adversarial rows. Until those pass, do not run or
synthesize them, do not flip `staticDefault`, and do not release default-on.

After the full matrix and final reviews pass, build 166 owns the unchanged default-on sequence:
RED receipt-policy expectations, focused/full verification, default-on review, non-`[skip ci]`
feature commit and exact green CI, separate `[skip ci]` build bump, ASC `VALID`, assignment,
installed-device proof, and durable-state close.
