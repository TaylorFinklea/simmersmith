# Current State
Branch: main

## Plan

- [ ] **HUMAN: push `main` + cut build 155.** Push (bead `tjc`, ~9 commits ahead) makes the new CI app-target gate execute for real — no CI run happens until then. Then `./scripts/release-ios.sh` for 155 (agent release is permission-gated; the 155 upload was blocked by design). All committed + verified: CK 513 (3x) · Kit 187 · app-target 90 · Release build. Verify: CI's "Test SimmerSmith app target" job is green on the push; release script prints `processed — VALID`.
- [x] `simmersmith-z69.3` — app-target tests wired into CI (`1eb4f85`→this commit). The host already existed (90 tests, 18 suites); the gap was CI running ZERO of them. Trap sidestepped with ad-hoc signing (`CODE_SIGN_IDENTITY=-`) which embeds the iCloud entitlement without a team/cert — proven locally: 90 green AND exit 65 on a deliberately-broken test (a real gate). First real CI run is on the push above.
- [ ] **Week 2 begins: `simmersmith-e0a` phase 1 (persistent mirror, SHADOW mode).** The cold-start fix. Build the transactional account/zone-partitioned mirror running BESIDE the full fetch, digest-compared; crash/replay/token-skew tests. Do NOT start z69.1 extraction concurrently (Sol condition). Full requirements on the bead + arch-audit report. Verify: mirror survives forced termination at each checkpoint and converges to the full-fetch result.

## Blockers
- Device gates ride **155** once cut: `6uj` `a97` `nli` `3hn` `cnx` `cel` `f5e` `auc` `mmi` + NEW from this wave — assistant targets the BROWSED week, an allergy-violating chat request is refused, a rapid double-edit keeps both edits, a two-device event-attendee edit keeps the partner's guest.
- `51d` — EventAttendee.updatedAt must be promoted to the PRODUCTION CloudKit schema (Development auto-infers; Production does not) or `f0s`'s LWW benefit is inert in prod. Human Dashboard/cktool step; rides with `pb8`.

## Notes
- **Week 1 COMPLETE** (`bf95046` · `4b9f4c1` · `1a67375` · `cefad10`). Build 154 is already on TestFlight carrying the two stop-ship safety fixes (`deh` real-data destruction, `eig` world-joinable share).
- Closed this wave: deh · eig · 48y · dkj · t6t · f0s · 91e · 7in · akv · kby · dac · 32i · dds · 57d · blv · 5fm. Staged (stage 1 done, stage 2 = wk4): `l4i` macro pass · `xwb` photo rendering · `4ii` Plan Shopping port decision.
- **The adversarial-verify lane is load-bearing, not ceremony.** 2 of 6 impl lanes shipped a GREEN self-report over a broken fix: ck-engine REINTRODUCED the clear-resurrection bug at its own new seam and its `updatedAt` guard was a no-op for GroceryItem (Int clocks, no updatedAt); events built the whole baseline mechanism but left every UI call site defaulted — byte-identical to the bug. Lead repaired both. Never fan out impl lanes without paired verifiers.
- **ralph/pi routing rule REVISED**: it works on small, pre-specced, command-verifiable items (`dds` + `57d`), contradicting the 9 prior stall entries — those were all open-ended agentic work. BUT it closed both beads while committing only one; `57d` sat uncommitted in the tree with its bead reading closed. Check `git log`, never its checkboxes.
- Verifier-found follow-ups filed: `51d` (prod schema) · `zfo` (migration test wiring + batched-save failures) · `d2o` (preferences_get untested; Fly-only week fallback) · `9lm` (resolveHouseholdID catch guard + stale lastErrorMessage).
- e0a (wk2-3) = P1, shadow→cutover→recovery on the bead; do NOT start z69.1 extraction concurrently (Sol condition).

## Open Questions
- none — owner locked direction + all four product calls 2026-07-14 (decisions.md).
