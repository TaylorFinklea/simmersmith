# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h Tasks 2-3: internal opt-in control and default-off build 163 installed on Roshar/Sel.
- [x] e0a owner namespace repair: legacy developer scopes excluded from launch/discovery/automatic cleanup; commit `f41c3e9`; exact CI run `29959784936` green.
- [!] e0a P2h owner repair: build 166 (`4b81b68`) VALID/installed; both devices produced anchored exact-zone checkpoints (3/3 records, `zoneEnsured=true`). Missing meals/member are proven stranded in reserved `spc-recipe-test`; overrides restored OFF. Recovery spec awaits approval.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and default-on build 167 remain blocked.

## Blockers
- `simmersmith-mpa` P0: recover approved real household data from reserved source without source mutation; spec `phases/household-zone-recovery-spec.md`.
- `simmersmith-rpz`: exact-zone fence works, but content-equivalence/cached proof blocked on `mpa`.
- `simmersmith-e0a`: blocked on `mpa`, `rpz`, and the full cross-account P2h matrix.

## Open questions
- None.
