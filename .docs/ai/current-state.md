# Current State
Branch: main

## Plan
- (empty — Fable day 2026-07-07 complete: pr9/13j/qrt/ebu/0gf/7mb + 5w8 draft landed, adversarially verified, closed; see git log 23efe83..bfe8af6 + runbook checkboxes + decisions.md 2026-07-07. Next session: `bd prime` → `bd ready`; Sonnet 5 resumes acting Lead per lead-succession.)

## User-gated (details in roadmap Awaiting User + the beads)
- CUT 150 (148 phantom-never-uploaded; 149 BURNED — crashed at first open): 150 = q6y BG-wake fix (bb687b3) + vda first-open fix (5fdbb2c: AsyncSerialGate serializes explicit engine ops; repairs gated on initial-fetch success — 149 was the FIRST build running the repair layer in production and its destructive pass fired mid-refetch). Field GREEN per beads q6y + vda. Beads open: ppp (late BG registration), hwi (drain audit), 148 (gate cancellation), ec2 (release-script dup guard).
- Assertion message recovery (nice-to-have): user runs `sudo /usr/bin/log collect --device-name Roshar --last 90m --output /tmp/roshar.logarchive`; cross-check vs gate design, update hwi.
- 5w8 privacy draft awaits review: phases/privacy-policy-cloudkit-draft.md (+ asc-label-notes); remaining user steps itemized on the bead.

## Blockers
- none

## Open Questions
- none
