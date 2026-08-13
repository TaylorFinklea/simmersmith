# Current State
Branch: codex/recipe-photo-rendering
Status: `xwb` stage-2 design approved; implementation plan ready. Build 174 remains `VALID` and unchanged.
Spec: `phases/recipe-photo-rendering-spec.md`

## Plan
- [x] Define and approve shared bounded recipe-photo loader and fallback behavior; Verify: explicit user approval.
- [x] Write implementation plan; Verify: every task has exact red/green commands.
- [?] Select inline or subagent-driven execution; Verify: explicit choice.
- [ ] Implement `xwb` stage 2 with TDD; Verify: app-host tests + generic simulator build.

## Blockers
- Recipe-photo implementation waits on execution-mode selection.
- Build 174 onboarding and owner/participant durability checks continue independently on TestFlight.
- Build 174 crash-durability device matrix remains a separate parked gate.
- `simmersmith-9w4`: crash-durability evidence still required before closure.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.

## Open questions
- None.
