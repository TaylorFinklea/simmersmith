# Current State
Branch: main
Status: deterministic onboarding merged at `f595f4d`; build 174 is `VALID` in App Store Connect/TestFlight.
Report: `phases/jfn-onboarding-report.md`

## Plan
- [?] Build 174 human onboarding gate; Verify: clean account mints household -> four screens -> first Skip -> no immediate return/What's New -> due after clock/device-date advance -> second Skip -> no auto return -> Settings relaunch.

## Blockers
- Build 174 crash-durability device matrix remains a separate parked gate.
- `simmersmith-9w4`: crash-durability evidence still required before closure.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.

## Open questions
- None.
