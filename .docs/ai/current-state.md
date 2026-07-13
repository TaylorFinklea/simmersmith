# Current State
Branch: main

## Plan

## Blockers
- `simmersmith-cel`: build 151 TestFlight cut blocked before archive; `.release-ios.env` has a 10-character key ID in `IOS_RELEASE_ISSUER_ID`, not the required 36-character ASC issuer UUID. Chrome recovery was approved, but this harness lacks the Chrome-control runtime; user must correct the local file.

## Open Questions
- none; Lead corrections recorded in revised spec + decisions.md. Ralph workers do not close beads.
