# Current State
Branch: main
Note: build 174 metadata `781bc3f`; Ballast retired from source/build/CI; upload not started.

## Plan
- [x] `jfn` design + written spec approved: `phases/jfn-onboarding-spec.md`.
- [x] Self-reviewed implementation plan: `phases/jfn-onboarding-plan.md`.
- [ ] Plan Tasks 1-2: lifecycle receipt + private completion. Verify: focused app-host tests.
- [ ] Plan Tasks 3-4: mint wiring + four-screen UI. Verify: focused tests + generic app build.
- [ ] Plan Tasks 5-6: planning + recipe servings. Verify: package + focused app-host tests.
- [ ] Plan Task 7: full verification + report. Verify: both packages + app tests/build + diff audit.

## Blockers
- `jfn`: implementation awaits the required execution-style choice.
- `simmersmith-9w4`: code complete; device crash-durability evidence still required before closure.
- Build 174 release: Apple Distribution identity present; blocked only by ASC Keychain entries + local `.p8`.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending its device gates.

## Open questions
- Execute `jfn` inline or with explicitly authorized task subagents?
