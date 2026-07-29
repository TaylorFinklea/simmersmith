# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h owner repair: exact-zone fence proved genuine owner data; `simmersmith-rpz` closed on a clean physical checkpoint (Roshar target scope 5/5 records in the exact zone, zero foreign; was 711/712 foreign).
- [x] recovery Phase A/B: closed out. The owner recovered the stranded data out-of-band (second device rejoined iCloud, device backup restored), so the analyze/apply feature was deleted in `7f9830d` rather than finished. See decisions.md 2026-07-28.
- [?] e0a P2h owner matrix: six device rows still owe evidence — online/offline, mutation/crash, account-boundary, token-resume, Roshar/Sel convergence, paired sixty-launch distribution. Human device gate, tracked as `simmersmith-h1g` (`user-verify`). Verify: named checks in `phases/e0a-p2h-execution-plan.md`; artifacts in `phases/e0a-cache-first-cutover-report.md`.
- [?] e0a P2h cross-account gates: blocked pending a second Apple Account plus a dedicated physical device. Sel is same-account, i.e. an OWNER — never usable to simulate a participant. Shared participant, share adopt/revoke, participant cached resume, final cross-account reviews, and the static-default flip all stay blocked.

## Blockers
- `simmersmith-e0a`: blocked by `simmersmith-h1g` (owner matrix device rows) plus the cross-account matrix above.
- Shipping default stays off: `CacheFirstLaunchPolicy.staticDefault == false`, and non-debug/non-sandbox resolves to `staticDefault && receipt == .appStore`. Flipping it is a separate gated decision.

## Open questions
- None.
