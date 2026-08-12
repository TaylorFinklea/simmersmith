# Current State
Branch: codex/recipe-photo-rendering
Status: `xwb` stage-2 design approved; written spec awaiting user review. Build 174 remains `VALID` and unchanged.
Spec: `phases/recipe-photo-rendering-spec.md`

## Plan
- [x] Define shared bounded recipe-photo loader and fallback behavior; Verify: spec self-review.
- [?] User review of written spec; Verify: explicit approval.
- [ ] Write implementation plan; Verify: every task has an exact test/build command.
- [ ] Implement `xwb` stage 2 with TDD; Verify: app-host tests + generic simulator build.

## Blockers
- Recipe-photo implementation waits on written-spec approval.
- Build 174 onboarding and owner/participant durability checks continue independently on TestFlight.
- Build 174 crash-durability device matrix remains a separate parked gate.
- `simmersmith-9w4`: crash-durability evidence still required before closure.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.

## Open questions
- None.
