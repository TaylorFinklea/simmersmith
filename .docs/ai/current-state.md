# Current State
Branch: main

## Plan
Milestone: `990.4` Recipe Memories → CloudKit (ultracode session 2026-07-12; .1 landed 1556cc0)
- [x] `990.4.2` rewire AppState+UI memories off apiClient onto RecipeRepository (+ restore-copy photo-exclusion note). Verify: `swift test --package-path SimmerSmithCloudKit && swift test --package-path SimmerSmithKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -only-testing:SimmerSmithTests` (665 pkg tests + 13 app-target tests green; NOTE: plain `build` never compiles SimmerSmithTests — use `test`/`build-for-testing`)
- [x] (discovered) `ppp` BGTask register-before-return — deterministic test-host launch crash on fresh sim; fixed e5efddf
- [ ] `990.4.3` RecipeMigrationLoader memories loop (mirror image task-group; photos best-effort). Verify: `swift test --package-path SimmerSmithCloudKit`
- [ ] Product test: drive memories add/list/delete in the iPhone 17 Pro sim (screenshots); suite 3-5x (asset-staging rule)

## User-gated (details in roadmap Awaiting User + the beads)
- Build 150 uploaded to TestFlight 2026-07-10 (`scripts/release-ios.sh` archive + export succeeded); await processing,
  then run device gates — `6uj` (Gate-1 regression incl. c57/glw/ioj), `a97` (sharing), `nli` (voice), `3hn`/`3sf`/`cnx`.
- hdeck `simmersmith/arch-v3-2026-07-09` is **awaiting-review**: pick which surviving product
  proposal(s) become beads (the bugs it surfaced are already filed).
- Device gates open: `6uj` `a97` `nli` `3hn` `3sf` `cnx`. Dashboard ops: `9wr` `pb8`.
- `5w8` privacy draft awaits review: phases/privacy-policy-cloudkit-draft.md (+ asc-label-notes).
- When monetization activates: Pro products must ship `isFamilyShareable = false` (decisions.md).

## Blockers
- none. (`990.8` is unblocked: phases/fly-call-inventory.md is the authoritative table —
  21 live-and-broken / 73 guarded-dead / 46 ported-already. Strip only guarded-dead.)

## Open Questions
- `4ii` (P2): port Plan Shopping as a local projection, or hide it? Lead call.
- `32i` (P2, blocked on 990.5.1): port grocery-item feedback, or drop it as redundant with the
  existing avoid/allergy flags? Prefer drop.
