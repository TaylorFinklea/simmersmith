# Current State
Branch: main

## Plan

## Blockers
- Device gates now riding **153**: `mmi` (memories 990.4), `6uj` `a97` `nli` `3hn`, `f5e` (What's New once-per-update trigger — never run on a real device), and `auc` (below).
- `auc` (leftover-household auto-cleanup, 5c93f55) — the CloudKit zone delete needs iCloud auth, so ONLY a device run proves it. On first 153 launch expect: the 13 empties gone, banner never shown, Settings → household silent (no fork row). Cleanup is detached + post-`.ready`, so it lands a beat AFTER the kitchen opens; if the empties survive one launch, check the `[AppState+HouseholdCleanup]` console line before assuming failure.

## Notes
- **Build 153 UPLOADED to TestFlight 2026-07-13** — `** ARCHIVE SUCCEEDED **` → `Upload succeeded` → `** EXPORT SUCCEEDED **`; processing state NOT yet confirmed (152 took a few min to reach `VALID` / `IN_BETA_TESTING`). Carries `auc` + the `3i0` UI-suite rewrite; What's New = one `fixed` line about the leftover-household warning.
- Build 152 shipped 2026-07-13 — processed `VALID`, `internal=IN_BETA_TESTING`, autoNotify on. Carried What's New (`224`).
- `release-ios.sh` now REFUSES to archive a build with no entry in `ReleaseNotesCatalog.swift`. Empty new/improved/fixed = the valid "nothing user-visible" answer. Verified firing on the 152 cut.
- SIGNING: new Mac ⇒ new distribution cert ⇒ the old `SimmerSmith App Store` profile can't sign (a profile embeds a cert allowlist). ExportOptions points at `SimmerSmith App Store Build 151`, the only profile holding this machine's cert. Fails AFTER `ARCHIVE SUCCEEDED` — only export re-signs. Details → bd memory `new-machine-signing-cert`; name consolidation beaded.
- SIM: never bake a UDID in `verify_cmd` (a new Mac killed 28 of them). Build verify → `-destination generic/platform=iOS`; test verify → `-destination name=SimmerSmithSim`, never with `CODE_SIGNING_ALLOWED=NO`. Run `scripts/dev-sim.sh` once per machine.
- Test verify is GREEN unscoped again (`3i0`, 85bdbeb): the Fly-era `SimmerSmithUITests` (6 dead + 1 vacuous) are gone, replaced by one launch smoke test — launch must settle on either terminal gate (tab bar OR "Sign in to iCloud") and never hang on the spinner. Deliberately NOT a launch→Week-tab test: the Week tab needs an iCloud account, so that would be red on every signed-out sim/CI box.
- `project.pbxproj` is COMMITTED in sync with `project.yml` (153); no longer "expected dirty". New source files still need `xcodegen generate` + the pbxproj committed.

## Open Questions
- none; Lead corrections recorded in revised spec + decisions.md. Ralph workers do not close beads.
