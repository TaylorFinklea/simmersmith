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

- [ ] **Step 1: Add failing visibility and receipt-policy tests**

Add table-driven tests proving the developer surface resolves visible for DEBUG and
`sandboxReceipt`, hidden for `receipt` and unknown release receipts, and proving an App Store
receipt ignores both `true` and `false` local overrides while `staticDefault` is false. Run the
focused `P2eLaunchPolicyTests`; require the new visibility seam test to fail before implementation.

- [ ] **Step 2: Expose a pure DebugGate visibility seam**

Refactor `DebugGate.showsCloudKitChecks` through an internal pure resolver taking `isDebug: Bool`
and `receiptFilename: String?`. It returns true only for DEBUG or `sandboxReceipt`; the live
property supplies compile configuration plus `Bundle.main.appStoreReceiptURL?.lastPathComponent`.
Run the focused tests and require them to pass.

- [ ] **Step 3: Add the internal toggle**

In `CloudKitDebugView`, bind `@AppStorage(AppState.cacheFirstLaunchOverrideKey)` to a Boolean and
add a developer section with a `Toggle` labeled `Cache-first launch`. Its footer must say that it
is an internal TestFlight control and requires force-quit/relaunch. Do not add another persistence
key, settings route, launch argument, device allowlist, or App Store-visible affordance.

- [ ] **Step 4: Verify and commit the feature**

Run both Swift packages, the signed `SimmerSmithTests` suite, the generic iOS build, and
`git diff --check`. Commit `feat(ios): add internal cache-first launch gate`. Generate a task review
package and require separate `Spec compliance: APPROVED` and `Task quality: APPROVED` verdicts.

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

- [ ] **Step 1: Push and gate the feature commit**

Fast-forward the reviewed feature commit to `main`, push `main`, select the GitHub Actions run whose
head SHA is that non-`[skip ci]` feature commit, and require it to finish green.

- [ ] **Step 2: Bump build 163 mechanically**

Add a silent `ReleaseNote` for build 163 dated `July 19, 2026` with headline `Under the hood` and
empty `new`, `improved`, and `fixed` arrays. Set `CURRENT_PROJECT_VERSION: 163`, regenerate with
`xcodegen generate --spec SimmerSmith/project.yml`, run the release-note tests and generic build,
then commit `chore(release): bump to build 163 [skip ci]`.

- [ ] **Step 3: Push, upload, assign, and install**

Push the release commit only after Task 3 Step 1 is green. Run `scripts/release-ios.sh` from the
main checkout, require terminal ASC `VALID`, confirm internal Finklea Dev assignment, install build
163 on the named owner and participant devices, and verify Settings -> Developer -> CloudKit checks
contains the cache-first toggle. Shipping static default must still be false.

---

### Task 4: Run the complete build-163 P2 device matrix

**Ownership:** Root controller plus the user handling Roshar and Sel. No worker receives device,
account, release, or credential authority.

**Files:**
- Modify: `.docs/ai/phases/e0a-cache-first-cutover-report.md`
- Modify: `.docs/ai/current-state.md`

**Interfaces:**
- Consumes: build 163, Roshar and Sel, owner and participant accounts, the internal toggle, launch
  signposts, mirror diagnostics, and genuine CKSyncEngine serialization.
- Produces: paired performance statistics, owner/participant/offline/account/crash/two-device
  evidence, and a positive token-resume trace.

- [ ] **Step 1: Capture the paired launch distribution**

On one seeded device/build, run 30 force-quit launches with the toggle off and 30 with it on.
Capture launch-task -> first `MainTabView`, bundle validation, bootstrap/store materialization, and
all initial projection signposts. Report all samples plus median, nearest-rank p95, and conventional
MAD. Enforce the Global Constraints performance thresholds.

- [ ] **Step 2: Exercise owner and participant identity**

Run online cached launch on owner and participant devices. Attempt offline cached launch and record
whether CloudKit proves account identity. If identity is unavailable, require privacy-safe full-fetch
fallback with no cached household flash.

- [ ] **Step 3: Exercise mutation and crash recovery**

Create pending saves and deletes and force termination around the existing record-first/state-second,
supersede, and restart-retry durability boundaries using an Xcode-installed signed build from the
same reviewed source when debugger timing is required. Reconnect and require no loss, resurrection,
duplicate delivery, stuck `sent` row, or unexplained quarantine.

- [ ] **Step 4: Exercise lifecycle privacy**

Switch accounts, adopt and revoke a share, and provoke every supported fallback. Require immediate
old-scope teardown, no stale session publication, no cross-account content flash, and no replacement
household mint before durable invalidation completes.

- [ ] **Step 5: Capture genuine token resume**

Use a device-captured serialization, create one known remote change after its checkpoint, relaunch,
and capture an engine trace proving serialization acceptance, delivery of the post-token change,
no replay of pre-token records, and a later state update/publication advance. Decode-only or mock
evidence does not count.

- [ ] **Step 6: Prove two-device convergence and record the matrix**

Make conflicting owner/participant edits and deletes on Roshar and Sel, reconnect both, and require
the same final records, no pending duplicates, and no unexplained digest/quarantine result. Append
every device/build/account/timestamp, raw artifact path, visible authority state, and result to the
P2 report. Any failed row stops P2h.

---

### Task 5: Run the final default-off adversarial reviews

**Files:** No production edits unless a reviewer finds a defect. Any fix receives focused tests,
its own commit, and re-review.

**Interfaces:**
- Consumes: the exact build-163 default-off source and complete P2 report.
- Produces: one fresh Claude Opus verdict and one equal-or-higher-tier independent adversarial
  verdict, both with no unresolved Critical/Important findings.

- [ ] **Step 1: Package the complete default-off diff and evidence**

Generate a review package from the P2 merge base through the exact build-163 source and include the
P2 report plus device artifacts. Reviewers are read-only and receive no release authority.

- [ ] **Step 2: Run both reviews**

Require reviewers to inspect account/scope privacy, CloudKit state reconciliation, crash recovery,
authority/lifecycle fencing, App Store override denial, device evidence truth, and release-gate
completeness. Fix all Critical/Important findings in one fix wave, rerun covering tests, and obtain
clean re-reviews.

---

### Task 6: Enable the shipping default and release build 164

**Prerequisite:** Tasks 1-5 all pass. If any is incomplete, do not start.

**Files:**
- Modify: `SimmerSmith/SimmerSmith/App/AppState.swift`
- Modify: `SimmerSmith/SimmerSmithTests/P2eCachedBootTests.swift`
- Modify as required by real resolver coverage: `SimmerSmith/SimmerSmithTests/HouseholdSyncEngineBootstrapTests.swift`
- Modify: `SimmerSmith/project.yml`
- Modify: `SimmerSmith/SimmerSmith/Features/ReleaseNotes/ReleaseNotesCatalog.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`
- Modify after external verification: `.docs/ai/current-state.md`
- Modify after external verification: `.docs/ai/phases/e0a-cache-first-cutover-report.md`

**Interfaces:**
- Consumes: the fully passed build-163 matrix and clean reviews.
- Produces: App Store cache-first default-on with unknown receipt fail-closed, TestFlight override
  retained for controls, build 164 VALID/assigned/installed, and closed P2h evidence.

- [ ] **Step 1: Write the default-on policy tests first**

Change focused expectations so `staticDefault: true` enables an App Store receipt regardless of a
persisted local override, unknown release receipts remain disabled, and DEBUG/TestFlight may still
set an explicit false P1 control. Run the focused policy tests and require failure against the
current live resolver before editing it.

- [ ] **Step 2: Flip only the static default**

Change the live `resolveCacheFirstLaunchPolicyDetails()` call from `staticDefault: false` to
`staticDefault: true` and update its default-off comments. Do not change identity, scope selection,
reconciliation, fallback, authority, lifecycle, or projection code.

- [ ] **Step 3: Verify, review, and commit the feature**

Run both Swift packages, the signed app-target suite, the generic build, and `git diff --check`.
Obtain task and whole-branch review approval, then commit
`feat(ios): enable cached household launch`.

- [ ] **Step 4: Push the feature and require exact CI**

Fast-forward to `main`, push the non-`[skip ci]` feature commit, and require the GitHub Actions run
for that exact SHA to finish green before release bookkeeping.

- [ ] **Step 5: Bump and push build 164**

Add build 164 dated `July 19, 2026`, headline `Meals ready sooner`, with one `improved` entry:
`Your household now opens from its verified local cache while CloudKit catches up in the background.`
Set `CURRENT_PROJECT_VERSION: 164`, regenerate the project, run release-note tests and the generic
build, commit `chore(release): bump to build 164 [skip ci]`, and push it.

- [ ] **Step 6: Upload and prove the installed release surface**

Run `scripts/release-ios.sh`, require terminal ASC `VALID`, confirm internal Finklea Dev assignment,
install build 164 from TestFlight, force-quit, and cold-launch on the seeded owner device. Require
the cache-first signposts, correct visible household, background reconciliation to current, no new
quarantine, and no cross-scope flash.

- [ ] **Step 7: Close durable state**

Append final CI/upload/ASC/assignment/install/device evidence to the P2 report, mark P2h `[x]` in
`current-state.md`, close `simmersmith-e0a` only if its acceptance criteria are fully satisfied,
publish the harness-deck completion report, and leave `main` clean.
