# Current State
Branch: main
Note: P8 baseline runner merged `214ec20` 2026-07-16 (separate dormant voice/Ballast track; context in `phases/p8-cloud-baseline-runner-*` + bead `simmersmith-zyp`). Not part of this e0a Plan.

## Plan
- [x] **e0a P1e hardening evidence.** Roshar TestFlight build 162 stayed alive through user + instrumented online relaunches; P1 full-fetch UI stayed authoritative; the delete resolved and two exact grocery saves remain durably pending for P2 replay; manifest digests match and no quarantine/markers exist. Verify: 676 CloudKit tests + generic iOS build succeeded (`SDK_STAT_CACHE_ENABLE=NO` bypassed a tool-only cache stall).
- [x] **e0a P2a Lead spec/decomposition.** Owner-approved 2026-07-16; staged/default-off exact-scope recovery, gated CK engine, authority/lifecycle, crash/perf/device/release gates; adversarial findings folded in.
- [x] **e0a P2b scope anchor + WAL recovery.** Exact-scope anchor-before-WAL, recovery-only snapshot, suffix replay, torn-tail repair, sequence quarantine, and WAL-error fencing; controller verify 575 tests; Opus re-review CLEAR.
- [x] **e0a P2c bootstrap catalog + normalization.** SDK probe PASS (app-target suite — package host traps on CKContainer; see decisions.md 2026-07-17 + phases report). Catalog/materializer/normalization/leases landed; 598 package tests ×5 + 122 app tests green. P2d caveat: State.Serialization decode accepts garbage — engine-side reconciliation is the real gate.
- [x] **e0a P2d gated resumable engine.** Two-phase seam (gated init + one-shot activate), proof-gated state.add/remove reconciliation, exact reprojection, uniform reject→quarantine→fallback; real-engine gate-hold proven in app suite. 617 pkg tests ×5 + 126 app + generic build green. See report + decisions.md 2026-07-17.
- [x] **e0a P2e test-only cached app boot/state.** Default-off exact owner/participant cached boot, P1 fetch-first recovery overlay, fail-closed WAL/CloudKit handoff, authority projection, repair/reset fences, and process-wide asset leases. Verify: 632 CloudKit + 187 Kit + 152 signed app tests; generic iOS build; independent review APPROVED.
- [x] **e0a P2f authority/conflict/lifecycle.** Exact-session authority, terminal remote-delete policy, once-only deferred work, epoch-first crash-replayable handoffs, marker-before-adoption, atomic scope/root invalidation, and account-bound reset delete/remint. Verify: 673 CloudKit + 187 Kit + 221 signed app tests; generic build; independent package/app reviews APPROVED. No named-device opt-in shipped in P2f; shipping default remains off.
- [x] **e0a P2g observability/performance evidence.** Closed privacy-safe package/app signposts plus 30-run fixed-seed local-path evidence (median 5.235 ms, p95 11.260 ms, MAD 0.344 ms); ETTrace simulator diagnostic could not traverse account-bound cached boot. Verify: 675 CloudKit + 187 Kit + 233 signed app tests; generic build; independent task reviews APPROVED. Device P1/P2 force-quit pair remains P2h; `8qy` stays separate; shipping default off.
- [?] **e0a P2h adversarial/device/default-on release.** Execution plan: `phases/e0a-p2h-execution-plan.md`. Build 162 closed P1e without changing the shadow-only boundary. Next: add the sandbox/TestFlight-only cache-first toggle, cut build 163, and prove the retained Roshar saves replay exactly once before the full P2 matrix. Shipping default remains off; default-on vehicle remains 164.

## Blockers
- Build and review the internal cache-first toggle, then cut/install build 163. P2 shipping default stays off until the retained-save replay and full device/performance matrix clear.

## Open questions
- None.
