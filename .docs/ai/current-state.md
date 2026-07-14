# Current State
Branch: main

## Plan

Wk1 wave → build 155. Lanes A-F run in-session (Workflow, file-disjoint); the mechanical tail below is ralph-loopable.

- [x] 154 SAFETY CUT — deh + eig fixed, uploaded to TestFlight 2026-07-14 (0317679).
- [x] `simmersmith-dds` — Settings Test-Key/model-fetch formatter drops HTTP body; delete local aiErrorMessage, delegate to AIError.errorDescription; thread provider name into streaming transport error. Verify: xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
- [x] `simmersmith-57d` — re-key AssistantToolCallCard title/icon/args to the 13 live ToolRegistry tool names. Verify: xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
- [x] `simmersmith-blv` — clear AIService.seasonalCache at the teardown choke point. Verify: xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
- [x] `simmersmith-5fm` — release-ios.sh polls ASC processing state after upload. Verify: bash -n scripts/release-ios.sh

## Blockers
- Device gates riding 153 (unchanged): mmi · 6uj · a97 · nli · 3hn · f5e · auc.
- `deh` (debug data destruction) is TestFlight-reachable on ≤153 — testers should avoid Settings → CloudKit checks → "Phase 1"/"RUN ALL CHECKS" until 154.

## Notes
- 2026-07-14 audit COMPLETE: 24 new beads, 30+ updated, 2 folded (v89, bnh → 7in). Report: `phases/arch-audit-2026-07-14-report.md`. Direction ADR: decisions.md 2026-07-14 (six-week program, owner-locked; roadmap `### Now` holds the week map).
- Peer-review mode validated: pre-digested no-tools `pi -p` — glm-5.2/terra/sol all 5/5 (scorecard logged). Tool-loop headless review dispatch stays banned.
- e0a = P1 with shadow→cutover→recovery rollout on the bead; do NOT start z69.1 extraction concurrently (Sol condition, on the beads).

## Open Questions
- none — owner answered both product rounds 2026-07-14 (direction, monetization, images, dead-Fly duo, assistant scope; recorded in the ADR).
