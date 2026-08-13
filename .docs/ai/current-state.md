# Current State
Branch: main
Status: `xwb` stage 2 merged at `607ea60`; build 175 release in progress.
Spec: `phases/recipe-photo-rendering-spec.md`
Report: `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Merge recipe-photo rendering and prepare build 175; Verify: fast-forward merge + release-note preflight.
- [ ] Archive, upload, and process build 175; Verify: `scripts/release-ios.sh` reports terminal `VALID`.
- [?] Human UI gate; verified fallback + list/card/detail upload; hero/compact, successful replace/remove, scroll, offline remain.

## Blockers
- Build 175 will carry onboarding + owner/participant crash-durability retests forward.
- `simmersmith-9w4`: crash-durability evidence still required before closure.
- QA household rejects writes with `Couldn't save this change safely`; blocks mutation/hero/compact proof.
- Launch UI smoke reproducibly hangs on CloudKit `.resolving` on iPhone 17 Pro test simulator; separate issue.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.

## Open questions
- None.
