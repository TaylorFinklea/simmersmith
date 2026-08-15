# Current State
Branch: main
Status: build 176 VALID; Roshar owner crash gate passed, photo replacement race remains.
Reports: `phases/normal-mode-crash-durability-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Reproduce expired fetched-asset failure; Verify: focused test failed with unreadable CKAsset.
- [x] Retain callback-owned photo bytes through async checkpoint publication; Verify: focused test green.
- [x] Machine verify; Verify: CloudKit 702, Kit 188, signed app 257, generic iOS build, diff check.
- [x] Prepare local build 176 RC; Verify: release-note tests 18/18 + regenerated project + generic build.
- [?] Device gate; Roshar owner add/delete passed; photo remove/upload passed, immediate replacement failed then relaunch retry passed; Sel + participant remain.

## Blockers
- Sel unavailable; Sel + Roshar are owner/same-account representatives, not a participant or clean-account matrix.
- Neutral anvil remains on Honey Garlic Butter Salmon for Sel cross-device proof.
- Immediate replacement after fresh upload was rejected safely; the same replacement passed after relaunch.
- Offline WDA check needs a non-Wi-Fi control path; current endpoint is the device LAN address.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.
