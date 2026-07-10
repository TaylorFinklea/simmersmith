# Current State
Branch: main

## Plan
- (empty — arch-v3 complete, incl. `b9z`. Lead = Fable; the Sonnet-5 succession has ended.)

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
