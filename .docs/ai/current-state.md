# Current State
Branch: main

## Plan

## Blockers
- `simmersmith-cel`: TestFlight 1.0.0 (151) is processed `VALID`, App Store eligible, and `IN_BETA_TESTING`; awaiting the user’s device checklist.
- Device gates riding 151: `mmi` (memories 990.4 — never driven on a device; sim has no iCloud acct), `6uj` `a97` `nli` `3hn`.

## Notes
- `project.pbxproj` is now COMMITTED in sync with `project.yml` at build **152** (the old 150-vs-151 drift is resolved; it is no longer "expected dirty"). A NEW source file still needs `xcodegen generate` + the pbxproj committed, or it vanishes from fresh clones.
- Build 152 (unreleased) carries What's New (`224`). `release-ios.sh` now REFUSES to archive a build with no entry in `ReleaseNotesCatalog.swift` — empty new/improved/fixed is the valid "nothing user-visible" answer.
- `224`'s launch trigger is NOT device-verified (sim iCloud needs re-auth → household never reaches `.ready`) → bead `f5e`.
- New machine ⇒ the old baked simulator UDID died, breaking 28 beads' `verify_cmd` (swept, bead `1j0`). NEVER bake a UDID. Build verify → `-destination generic/platform=iOS` (no sim). Test verify → `-destination name=SimmerSmithSim`, never with `CODE_SIGNING_ALLOWED=NO`. Run `scripts/dev-sim.sh` once per machine to create the sim.
- Release landmines → bd memory `testflight-cut-landmines`. Credential durability = `ana`; script cert/profile preflight = `qjx`.

## Open Questions
- none; Lead corrections recorded in revised spec + decisions.md. Ralph workers do not close beads.
