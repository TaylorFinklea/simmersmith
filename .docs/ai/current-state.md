# Current State
Branch: main
Status: deterministic onboarding merged at `f595f4d`; build 174 preflight blocked before archive/upload.
Report: `phases/jfn-onboarding-report.md`

## Plan
- [?] Build 174 upload awaiting local ASC assets; Verify: `./scripts/release-ios.sh` reaches `VALID`.

## Blockers
- Named human UI gate remains: clean account mints household -> four screens -> first Skip -> no immediate return/What's New -> due after clock/device-date advance -> second Skip -> no auto return -> Settings relaunch.
- Build 174 upload and crash-durability device matrix remain separate parked gates.
- `simmersmith-9w4`: crash-durability evidence still required before closure.
- Build 174 live preflight: Apple Distribution identity + release note present; `IOS_RELEASE_KEY_ID`, `IOS_RELEASE_ISSUER_ID`, and matching ignored `.p8` absent from every allowed source.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.

## Open questions
- None; release credentials stay local and must not be sent in chat.
