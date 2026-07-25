# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h Tasks 2-3: internal opt-in control and default-off build 163 installed on Roshar/Sel.
- [x] e0a owner namespace repair: legacy developer scopes excluded from launch/discovery/automatic cleanup; commit `f41c3e9`; exact CI run `29959784936` green.
- [!] e0a P2h owner repair: build 165 installed and published clean exact-zone 2-record checkpoints, then rejected them because existing-zone discovery never set `zoneEnsured`. Exact-zone discovery proof fix is locally green/reviewed; build 166 becomes default-off proof. Overrides remain ON.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and default-on build 167 remain blocked.

## Blockers
- `simmersmith-rpz` P0: build 165 proved clean checkpoint contents but exposed false `zoneEnsured`; local fix awaits commit/CI/build-166 physical proof.
- `simmersmith-fkn` P0: missing wife/member is consistent with the contaminated checkpoint/data source but remains unproven; no reset or share automation allowed.
- `simmersmith-lrz`: namespace repair correctly excluded `spc-recipe-test`, but owner proof remains blocked on `rpz`.
- `simmersmith-e0a`: blocked on `rpz`, `fkn`, and the full cross-account P2h matrix.

## Open questions
- None.
