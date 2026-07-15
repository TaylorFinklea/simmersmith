# Current State
Branch: main

## Plan
- [x] Release push/build 155: `10906ad` pushed; CI run 29419464369 green including app-target tests; build 155 uploaded + `VALID`. Verify: `gh run view 29419464369 --json conclusion,jobs` and ASC `/v1/builds?filter[version]=155` report success/VALID.
- [x] `51d` tracked schema source: EventAttendee.updatedAt added to `phase0-schema.ckdb` (`a1e71b5`); CK 513 + generic iOS build green. Production Dashboard promotion remains under Blockers.
- [ ] **e0a P1a Lead spec/decomposition.** Write `phases/e0a-shadow-mirror-spec.md`: code-grounded alternatives + selected transactional generation bundle/write-ahead intent journal; scoped identity, full CKRecord/system fields, assets, tombstones/outbox/receipts, record-first→state-second checkpoints, shadow digest, clear/park, crash matrix; exact bounded TDD/Ralph Plan items. No production code. `tier_floor: lead` · `complexity: L`. Verify: `test -f .docs/ai/phases/e0a-shadow-mirror-spec.md && rg -q "Crash matrix" .docs/ai/phases/e0a-shadow-mirror-spec.md && rg -q "Verify:" .docs/ai/current-state.md`.
- [ ] **`simmersmith-poj`: release poll propagation-gap regression.** TDD the smallest source-grounded fix so an absent ASC build/state retries, VALID succeeds, INVALID/FAILED fails; do not upload. `tier_floor: junior` · `complexity: S`. Verify: `bash scripts/test-release-ios-poll.sh && bash -n scripts/release-ios.sh`.

## Blockers
- `51d`: CloudKit Dashboard Production deploy only (`cktool` cannot); tracked delta ready, but no controllable browser is exposed in this Codex session. Keep bead open until deploy + two-device recency check.

## Open questions
- none — owner approved e0a P1 completion + release operations 2026-07-15.
