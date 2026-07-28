# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h owner repair: exact-zone fence and build 166 physical checkpoints proved genuine owner data; stranded data remains preserved in reserved source.
- [x] recovery Phase A Tasks 1-5: build 169 manifest digest `32b692f3d7d9edf1a7d3ea5f6a7ba2cf85ec1e81ca291f6ff34d31a65f49a280` approved: 641 copy/include, 5 excluded, 0 conflicts, 0 blocked.
- [x] recovery Phase B Tasks 6-8 implementation: deterministic target reconstruction/receipt, exact target-only CloudKit apply, and explicit TestFlight UI reviewed.
- [x] recovery Phase B build 170/171 applies wrote nothing, two distinct defects, both repaired: layers [142, 515] exceeded CloudKit's per-request ceilings (`8d2f920`), and parking tore down the sheet that owned the apply task, cancelling it mid-prepare (`877abc1`, run now owned by AppState with a durable outcome).
- [ ] recovery Phase B physical gate: install build 172 over preserved Roshar data, run one approved apply, then prove post-apply Roshar/Sel full-fetch and cached convergence. Verify: Task 8 Steps 4-6 in `phases/household-zone-recovery-plan.md`.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and default-on build 173 remain blocked.

## Blockers
- `simmersmith-mpa` P0: apply repaired twice and reviewed; build 172 physical apply and post-apply proof remain.
- `simmersmith-d2q`: closed by `dfb0b79` — relay handshakes no longer bounded on a two-second race; CI green on `72d0f8e`.
- `simmersmith-rpz`: exact-zone fence works, but content-equivalence/cached proof waits on the build 172 recovery apply.
- `simmersmith-e0a`: blocked on `mpa`, `rpz`, and the full cross-account P2h matrix.

## Open questions
- None.
