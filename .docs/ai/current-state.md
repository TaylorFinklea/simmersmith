# Current State
Branch: main

## Plan
- [?] **e0a P1e hardening evidence — build 160 device rerun pending.** Post-repair packages/app/build green; repeat signed-device online edit, offline save+delete, force-quit/relaunch/reconnect, no-new-quarantine. Verify: named device check + `swift test --package-path SimmerSmithCloudKit && xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`.
- [?] **e0a P2a Lead spec/decomposition — awaiting owner review.** Staged/default-off exact-scope recovery, gated CK engine, authority/lifecycle, crash/perf/device/release gates; Opus/Terra/GLM/MiniMax findings folded in; final GLM clearance. `tier_floor: lead` · `complexity: L`. Verify: `test -f .docs/ai/phases/e0a-cache-first-cutover-spec.md && rg -q "closed bootstrap delegate gate" .docs/ai/phases/e0a-cache-first-cutover-spec.md && rg -q "P2h — adversarial/device gate" .docs/ai/phases/e0a-cache-first-cutover-spec.md` + owner approval.
- [ ] **e0a P2b scope anchor + WAL recovery.** `tier_floor: lead` · `complexity: M`. Verify: `swift test --package-path SimmerSmithCloudKit`.
- [ ] **e0a P2c bootstrap catalog + normalization.** `tier_floor: senior` · `complexity: L`. Verify: `swift test --package-path SimmerSmithCloudKit`.
- [ ] **e0a P2d gated resumable engine.** `tier_floor: lead` · `complexity: L`. Verify: `swift test --package-path SimmerSmithCloudKit`.
- [ ] **e0a P2e test-only cached app boot/state.** `tier_floor: senior` · `complexity: L`. Verify: CloudKit package + ad-hoc app-target suite + generic iOS build command in P2 spec §9.
- [ ] **e0a P2f authority/conflict/lifecycle.** `tier_floor: lead` · `complexity: L`. Verify: CloudKit package + ad-hoc app-target suite + generic iOS build command in P2 spec §9.
- [ ] **e0a P2g observability/performance evidence.** `tier_floor: senior` · `complexity: M`. Verify: CloudKit package + ad-hoc app-target suite + generic iOS build command in P2 spec §9.
- [ ] **e0a P2h adversarial/device/default-on release.** `tier_floor: lead` · `complexity: L`. Verify: automated gates + named owner/participant/two-device/token-resume/crash/performance evidence in `phases/e0a-cache-first-cutover-report.md`; then CI/upload/ASC assignment/installed-build check.

## Blockers
- P1e needs connected device evidence; P2a needs owner approval; P2 shipping default stays off until P1e + P2 automated/device/performance gates clear.

## Open questions
- Approve the written P2 spec before implementation?
