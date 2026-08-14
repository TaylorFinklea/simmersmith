# Normal-Mode Crash Durability Report

Issue: `simmersmith-9w4`
Status: `[?] awaiting human verify`

## Landed behavior

- Exact-scope `.normal` sessions synchronously install a required WAL writer before engine creation.
- Recovery sessions start false-authority and reject mutation until full fetch + one-writer overlay.
- Cache-first OFF scans exact owner/participant scopes for durable intent only; checkpoint records stay hidden.
- Save/delete acceptance remains WAL-first; storage failure leaves store and CKSyncEngine pending state unchanged.
- Late fire-and-forget identity lookup/writer replacement removed; AppState identity is canonical.
- Durability errors and traces are cache-neutral.

## Verification

- `swift test --package-path SimmerSmithCloudKit`: 696 tests passed; 0 failures (existing Swift 6 warnings).
- `swift test --package-path SimmerSmithKit`: 187 tests passed; 10 entitlement-only tests skipped by existing guards.
- Changed app sources + app-host tests: `swiftc -frontend -parse` passed.
- App-host `xcodebuild test`: blocked during package resolution because repo-local `ballast/` is absent; no app test compiled.
- `git diff --check`: passed.
- Spec adversarial review: `opencode-go/kimi-k3` + `ollama-cloud/glm-5.2`; required changes incorporated.

## Remaining gates

- TestFlight, cache-first OFF, owner + participant: add -> immediate force-quit -> relaunch persists.
- TestFlight, cache-first OFF, owner + participant: delete -> immediate force-quit -> relaunch stays deleted.
- Participant build 173 cache warm-up retest: OFF -> force quit/relaunch/full sync + ~30s -> ON -> force quit -> time two relaunches.
- Close `simmersmith-9w4` only after device evidence; `.beads/` is currently absent, so do not recreate tracker state here.

## Physical-device attempt — 2026-08-14

- TestFlight build 175 on Roshar (iPhone 15 Pro, iOS 26.6) was an owner session: Settings exposed
  the owner-only `Share with your partner` action. Cache-first was changed from ON to OFF, the app
  was force-quit/relaunched, and Settings reported iCloud synced at 07:56 before mutation.
- Quick add `QA Crash Durability 175` was saved; the process-termination command was dispatched
  1,003 ms after the Save command began (device signal-delivery latency was not separately
  instrumented). Relaunch + 15 seconds showed the breakfast slot empty.
- The timed result is not accepted durability evidence: a control save without a kill also produced
  no record, and selecting an existing recipe without a kill immediately surfaced
  `Couldn't save this change safely. Retry when storage is available.` The owner writer is rejecting
  the mutation before there is an accepted record whose crash persistence can be measured.
- Delete durability is blocked by the same condition because no disposable household record can be
  accepted first. Participant durability remains untested: Sel and Roshar represent the owner/same
  account, not a participant on a distinct iCloud account.
- Status remains `[?] awaiting human verify`; release gate fails at the healthy-writer precondition.

## Build 175 blocker repair — 2026-08-14

- Root cause: a fetched `CKAsset` callback URL could expire before asynchronous shadow-checkpoint
  publication copied the photo. The failed publication marked the required normal-session WAL
  unavailable, so later household mutations correctly failed closed but could never recover in-session.
- Repair: fetch snapshots synchronously stage only callback-owned asset files, retain them through
  asynchronous generation/verification, and remove the temporary staging directory with the snapshot.
- Focused regression was observed red with `Unreadable CKAsset file for imageAsset`, then green after
  the repair; it also proves a subsequent required WAL save is accepted.
- Machine verification: `SimmerSmithCloudKit` 702/702, `SimmerSmithKit` 188/188, signed app-target
  tests 257/257, generic iOS build, and `git diff --check` passed.
- Status remains `[?] awaiting human verify`: rerun owner add/delete crash durability on build 176;
  participant evidence still requires a distinct participant iCloud account.
