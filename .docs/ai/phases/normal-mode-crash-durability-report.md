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
