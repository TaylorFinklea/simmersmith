# Current State
Branch: main

## Plan

- [ ] Wk1 stop-ship wave → cut build 154: deh · 48y · dkj · 91e · f0s · 7in · l4i-s1 · akv · xwb-s1 · 4ii/32i hides · dac · kby · eig · z69.3-timeboxed. Verify: per-bead verify_cmds + human device pass on 154.

## Blockers
- Device gates riding 153 (unchanged): mmi · 6uj · a97 · nli · 3hn · f5e · auc.
- `deh` (debug data destruction) is TestFlight-reachable on ≤153 — testers should avoid Settings → CloudKit checks → "Phase 1"/"RUN ALL CHECKS" until 154.

## Notes
- 2026-07-14 audit COMPLETE: 24 new beads, 30+ updated, 2 folded (v89, bnh → 7in). Report: `phases/arch-audit-2026-07-14-report.md`. Direction ADR: decisions.md 2026-07-14 (six-week program, owner-locked; roadmap `### Now` holds the week map).
- Peer-review mode validated: pre-digested no-tools `pi -p` — glm-5.2/terra/sol all 5/5 (scorecard logged). Tool-loop headless review dispatch stays banned.
- e0a = P1 with shadow→cutover→recovery rollout on the bead; do NOT start z69.1 extraction concurrently (Sol condition, on the beads).

## Open Questions
- none — owner answered both product rounds 2026-07-14 (direction, monetization, images, dead-Fly duo, assistant scope; recorded in the ADR).
