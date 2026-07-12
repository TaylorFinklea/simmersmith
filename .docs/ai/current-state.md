# Current State
Branch: main

## Plan
- (empty — milestone `990.4` Recipe Memories → CloudKit CLOSED 2026-07-12, all children + umbrella;
  `ppp` closed en route. Product test: RecipeMemoriesProductFlowTests on the real stack + clean sim
  launch. Landmines for next session: plain `xcodebuild build` never compiles SimmerSmithTests (use
  `test`); old sim UDID 386E369A in bead verify_cmds is stale → iPhone 17 Pro FDDFB511-272B-40DD-8927-5E71311E96BA;
  `xcodebuild` needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` — xcode-select points at CLT.)

## User-gated (details in roadmap Awaiting User + the beads)
- Memories on-device drive (add/list/photo/delete in the real UI) rides the next build's device
  gates — sim has no iCloud account, so the app correctly halts at setup there. Prod schema deploy
  of RecipeMemory/RecipeMemoryImage rides `pb8`.
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
