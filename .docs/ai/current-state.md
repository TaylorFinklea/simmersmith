# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h owner repair: exact-zone fence and build 166 physical checkpoints proved genuine owner data; stranded data remains preserved in reserved source.
- [x] recovery Phase A/B: closed out. The owner recovered the stranded data out-of-band (second device rejoined iCloud, device backup restored), so the analyze/apply feature was deleted rather than finished. See decisions.md 2026-07-28.
- [ ] e0a P2h owner matrix: online/offline, mutation/crash, account-boundary, token-resume, two-device convergence, and the paired sixty-launch distribution rows still owe evidence. Verify: named device checks in `phases/e0a-p2h-execution-plan.md`.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus dedicated physical device; shared participant, share adopt/revoke, final reviews, static-default flip, and the default-on build remain blocked.

## Blockers
- `simmersmith-e0a`: cache-first default-on still blocked on the owner matrix rows plus the full cross-account P2h matrix.

## Open questions
- None.
