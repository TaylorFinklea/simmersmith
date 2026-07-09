# Current State
Branch: main

## Plan
- (empty — simmersmith-a7i provider swap landed: visible OpenRouter replaced by Ollama Cloud + NeuralWatt; hidden legacy OpenRouter remaps to Ollama on Settings/runtime. Verify green: `swift test --package-path SimmerSmithCloudKit`; `xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO`. Next: `bd prime` → `bd ready`.)

## User-gated (details in roadmap Awaiting User + the beads)
- CUT 150 (148 phantom-never-uploaded; 149 BURNED — crashed at first open): 150 = q6y BG-wake fix (bb687b3) + vda first-open fix (5fdbb2c: AsyncSerialGate serializes explicit engine ops; repairs gated on initial-fetch success — 149 was the FIRST build running the repair layer in production and its destructive pass fired mid-refetch). Field GREEN per beads q6y + vda. Beads open: ppp (late BG registration), hwi (drain audit), 148 (gate cancellation), ec2 (release-script dup guard).
- Assertion message recovery (nice-to-have): user runs `sudo /usr/bin/log collect --device-name Roshar --last 90m --output /tmp/roshar.logarchive`; cross-check vs gate design, update hwi.
- 5w8 privacy draft awaits review: phases/privacy-policy-cloudkit-draft.md (+ asc-label-notes); remaining user steps itemized on the bead.

## Blockers
- none

## Open Questions
- none
