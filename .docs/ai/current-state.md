# Current State
Branch: main
Status: build 175 owner-write blocker repaired locally; build 176 RC prep next.
Reports: `phases/normal-mode-crash-durability-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Reproduce expired fetched-asset failure; Verify: focused test failed with unreadable CKAsset.
- [x] Retain callback-owned photo bytes through async checkpoint publication; Verify: focused test green.
- [x] Machine verify; Verify: CloudKit 702, Kit 188, signed app 257, generic iOS build, diff check.
- [ ] Prepare local build 176 RC; Verify: release-note preflight + regenerated project + generic build.
- [?] Device gate; owner add/delete crash durability + photo replace/remove, then participant matrix.

## Blockers
- Sel + Roshar are owner/same-account representatives, not a participant or clean-account matrix.
- Neutral test photo remains on Honey Garlic Butter Salmon; remove failed safely on both devices.
- Offline WDA check needs a non-Wi-Fi control path; current endpoint is the device LAN address.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.
