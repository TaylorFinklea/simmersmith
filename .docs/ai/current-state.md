# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h Tasks 2-3: internal opt-in control and default-off build 163 installed on Roshar/Sel.
- [x] e0a owner namespace repair: legacy developer scopes excluded from launch/discovery/automatic cleanup; commit `f41c3e9`; exact CI run `29959784936` green.
- [!] e0a P2h owner-only build 164: Roshar/Sel override-ON launches rendered via safe fallback, but Sel quarantined the genuine owner scope because its checkpoint was cross-zone contaminated. `simmersmith-rpz` zone fence implemented locally; physical proof/build 165 blocked. Overrides remain ON on both devices while user is away.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and build 165 remain blocked.

## Blockers
- `simmersmith-rpz` P0: genuine owner checkpoint contained 711/712 foreign-zone records; bidirectional exact-zone engine fence implemented and independently approved, awaiting commit/new default-off build/physical proof.
- `simmersmith-fkn` P0: missing wife/member is consistent with the contaminated checkpoint/data source but remains unproven; no reset or share automation allowed.
- `simmersmith-lrz`: namespace repair correctly excluded `spc-recipe-test`, but owner proof remains blocked on `rpz`.
- `simmersmith-e0a`: blocked on `rpz`, `fkn`, and the full cross-account P2h matrix.

## Open questions
- None.
