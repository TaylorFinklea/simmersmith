# Current State
Branch: main
Note: P8 baseline runner merged `214ec20` 2026-07-16 (separate voice/Ballast track — dormant
behind DebugGate, app-target source files added; context in `phases/p8-cloud-baseline-runner-*`
+ bead `simmersmith-zyp`). Not part of this e0a Plan.

## Plan
- [?] **e0a P1e hardening evidence — device rerun pending on build 161 (cut+uploaded 2026-07-17, ASC VALID/TestFlight-ready; adds P8 + Ballast-gate commits; 160 superseded, its upload never confirmed).** Post-repair packages/app/build green; repeat signed-device online edit, offline save+delete, force-quit/relaunch/reconnect, no-new-quarantine. Verify: named device check + `swift test --package-path SimmerSmithCloudKit && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`.
- [x] **e0a P2a Lead spec/decomposition.** Owner-approved 2026-07-16; staged/default-off exact-scope recovery, gated CK engine, authority/lifecycle, crash/perf/device/release gates; adversarial findings folded in.
- [x] **e0a P2b scope anchor + WAL recovery.** Exact-scope anchor-before-WAL, recovery-only snapshot, suffix replay, torn-tail repair, sequence quarantine, and WAL-error fencing; controller verify 575 tests; Opus re-review CLEAR.
- [x] **e0a P2c bootstrap catalog + normalization.** SDK probe PASS (app-target suite — package host traps on CKContainer; see decisions.md 2026-07-17 + phases report). Catalog/materializer/normalization/leases landed; 598 package tests ×5 + 122 app tests green. P2d caveat: State.Serialization decode accepts garbage — engine-side reconciliation is the real gate.
- [x] **e0a P2d gated resumable engine.** Two-phase seam (gated init + one-shot activate), proof-gated state.add/remove reconciliation, exact reprojection, uniform reject→quarantine→fallback; real-engine gate-hold proven in app suite. 617 pkg tests ×5 + 126 app + generic build green. See report + decisions.md 2026-07-17.
- [x] **e0a P2e test-only cached app boot/state.** Default-off exact owner/participant cached boot, P1 fetch-first recovery overlay, fail-closed WAL/CloudKit handoff, authority projection, repair/reset fences, and process-wide asset leases. Verify: 632 CloudKit + 187 Kit + 152 signed app tests; generic iOS build; independent review APPROVED.
- [ ] **e0a P2f authority/conflict/lifecycle.** `tier_floor: lead` · `complexity: L`. Verify: CloudKit package + ad-hoc app-target suite + generic iOS build command in P2 spec §9.
- [ ] **e0a P2g observability/performance evidence.** `tier_floor: senior` · `complexity: M`. Verify: CloudKit package + ad-hoc app-target suite + generic iOS build command in P2 spec §9.
- [ ] **e0a P2h adversarial/device/default-on release.** `tier_floor: lead` · `complexity: L`. Verify: automated gates + named owner/participant/two-device/token-resume/crash/performance evidence in `phases/e0a-cache-first-cutover-report.md`; then CI/upload/ASC assignment/installed-build check.

## Blockers
- P1e needs connected device evidence; P2 shipping default stays off until P1e + P2 automated/device/performance gates clear.

## Open questions
- None.
