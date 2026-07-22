# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h Tasks 2-3: internal opt-in control and default-off build 163 installed on Roshar/Sel.
- [x] e0a owner namespace repair: legacy developer scopes excluded from launch/discovery/automatic cleanup; commit `f41c3e9`; exact CI run `29959784936` green.
- [ ] e0a P2h owner-only build 164: cut default-off repair vehicle, install over preserved data, prove owner/private cache launch on Roshar/Sel, then run owner-representative matrix. Verify: named build-164 checks in `phases/e0a-p2h-execution-plan.md`.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and build 165 remain blocked.

## Blockers
- `simmersmith-lrz`: remains open until build-164 owner physical proof passes.
- `simmersmith-e0a`: blocked on the full cross-account P2h matrix; owner-only evidence cannot close it.

## Open questions
- None.
