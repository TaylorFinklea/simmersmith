# Current State
Branch: main
Note: P8 baseline runner `214ec20` is separate; not part of e0a.

## Plan
- [x] e0a P1e-P2g: cached boot, authority/lifecycle, observability, and performance evidence complete; shipping default off.
- [x] e0a P2h owner repair: exact-zone fence proved genuine owner data; `simmersmith-rpz` closed on a clean physical checkpoint (Roshar target scope 5/5 records in the exact zone, zero foreign; was 711/712 foreign).
- [x] recovery Phase A/B: closed out. The owner recovered the stranded data out-of-band (second device rejoined iCloud, device backup restored), so the analyze/apply feature was deleted in `7f9830d` rather than finished. See decisions.md 2026-07-28.
- [~] e0a P2h owner matrix on build 173 (`simmersmith-h1g`): with the override ON every row PASSED, including the force-quit durability row that FAILS with it off (`simmersmith-9w4`, scoped to the `.normal` plane). Only the paired sixty-launch distribution is outstanding. Evidence: `phases/e0a-cache-first-cutover-report.md` P2h Task 5.
- [ ] e0a cross-account participant matrix (`simmersmith-go35`): **blocker lifted 2026-07-29** — a real participant device on a separate Apple Account is now available. Rows: participant cached launch exact-scope selection, participant offline identity finding, participant mutation force-quit durability, owner share-adopt with durable owner-scope parking, participant revocation clearing marker+scope, owner/participant convergence.

## Blockers
- `simmersmith-9w4` P1: a mutation force-quit within ~1s is lost (add vanishes) or reverted (delete resurrects). One root cause: `HouseholdSyncEngine.swift:571` makes the durable WAL required only when `dataPlaneMode == .cached`, so the shipping `.normal` plane journals nothing and relies on an unawaited `drainSync()` beating process death. Blocks `h1g`.
- `simmersmith-e0a`: blocked by `h1g` plus the cross-account matrix above.
- Shipping default stays off: `CacheFirstLaunchPolicy.staticDefault == false`, and non-debug/non-sandbox resolves to `staticDefault && receipt == .appStore`.

## Open questions
- Does enabling cache-first fix `simmersmith-9w4`? Re-run the crash-durability row with the override ON; `.cached` makes the WAL append required and synchronous. Cheapest available confirmation.
