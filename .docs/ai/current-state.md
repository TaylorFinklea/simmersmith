# Current State
Branch: main

## Plan
- [x] Release push/build 155: `10906ad` pushed; CI run 29419464369 green including app-target tests; build 155 uploaded + `VALID`. Verify: `gh run view 29419464369 --json conclusion,jobs` and ASC `/v1/builds?filter[version]=155` report success/VALID.
- [x] `51d` tracked schema source: EventAttendee.updatedAt added to `phase0-schema.ckdb` (`a1e71b5`); CK 513 + generic iOS build green. Production Dashboard promotion remains under Blockers.
- [x] **e0a P1a Lead spec/decomposition.** Added + GLM/MiniMax-adversarially revised `phases/e0a-shadow-mirror-spec.md`: scoped generation/WAL, state-coverage revision, canonical digest, durable asset rebinding, intent high-water, exact ack transitions, fencing, crash matrix, bounded TDD items. `tier_floor: lead` · `complexity: L`. Verify: `test -f .docs/ai/phases/e0a-shadow-mirror-spec.md && rg -q "Crash matrix" .docs/ai/phases/e0a-shadow-mirror-spec.md && rg -q "state-coverage revision" .docs/ai/phases/e0a-shadow-mirror-spec.md`.
- [ ] **`simmersmith-poj`: release poll propagation-gap regression.** TDD the smallest source-grounded fix so an absent ASC build/state retries, VALID succeeds, INVALID/FAILED fails; do not upload. `tier_floor: junior` · `complexity: S`. Verify: `bash scripts/test-release-ios-poll.sh && bash -n scripts/release-ios.sh`.

## Blockers
- `51d`: CloudKit Dashboard Production deploy only (`cktool` cannot); tracked delta ready, but no controllable browser is exposed in this Codex session. Keep bead open until deploy + two-device recency check.

## Open questions
- none — owner approved e0a P1 completion + release operations 2026-07-15.
