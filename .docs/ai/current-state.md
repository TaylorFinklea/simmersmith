# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h owner repair: exact-zone fence and build 166 physical checkpoints proved genuine owner data; stranded data remains preserved in reserved source.
- [x] recovery Phase A Tasks 1-5: pure plan/classifier, exact-zone read-only analyzer, TestFlight preview, and user approval complete. Build 169 manifest digest `32b692f3d7d9edf1a7d3ea5f6a7ba2cf85ec1e81ca291f6ff34d31a65f49a280`: 641 copy/include, 5 excluded, 0 conflicts, 0 blocked.
- [ ] recovery Phase B Task 6: target-zone reconstruction and receipt model. Verify: `swift test --package-path SimmerSmithCloudKit --filter HouseholdZoneRecoveryApplyPlanTests`.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and default-on build 170 remain blocked.

## Blockers
- `simmersmith-mpa` P0: approved manifest is read-only; target-only apply plan/engine and post-apply verification remain.
- `simmersmith-rpz`: exact-zone fence works, but content-equivalence/cached proof waits on recovery apply.
- `simmersmith-e0a`: blocked on `mpa`, `rpz`, and the full cross-account P2h matrix.

## Open questions
- None.
