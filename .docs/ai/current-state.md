# Current State
Branch: main

## Plan

## Blockers
- Device gates now riding **152**: `mmi` (memories 990.4), `6uj` `a97` `nli` `3hn`, and `f5e` (What's New once-per-update trigger — never run on a real device).

## Notes
- **Build 152 SHIPPED to TestFlight 2026-07-13** — processed `VALID`, `internal=IN_BETA_TESTING`, autoNotify on (same state 151 had). Carries What's New (`224`), so testers should see the sheet once on updating.
- `release-ios.sh` now REFUSES to archive a build with no entry in `ReleaseNotesCatalog.swift`. Empty new/improved/fixed = the valid "nothing user-visible" answer. Verified firing on the 152 cut.
- SIGNING: new Mac ⇒ new distribution cert ⇒ the old `SimmerSmith App Store` profile can't sign (a profile embeds a cert allowlist). ExportOptions points at `SimmerSmith App Store Build 151`, the only profile holding this machine's cert. Fails AFTER `ARCHIVE SUCCEEDED` — only export re-signs. Details → bd memory `new-machine-signing-cert`; name consolidation beaded.
- SIM: never bake a UDID in `verify_cmd` (a new Mac killed 28 of them). Build verify → `-destination generic/platform=iOS`; test verify → `-destination name=SimmerSmithSim`, never with `CODE_SIGNING_ALLOWED=NO`. Run `scripts/dev-sim.sh` once per machine.
- `project.pbxproj` is COMMITTED in sync with `project.yml` (152); no longer "expected dirty". New source files still need `xcodegen generate` + the pbxproj committed.

## Open Questions
- none; Lead corrections recorded in revised spec + decisions.md. Ralph workers do not close beads.
