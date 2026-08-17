# Current State
Branch: main
Status: build 177 VALID; Sel cross-device photo rendering and restart persistence passed.
Reports: `phases/normal-mode-crash-durability-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Trace delayed build-176 fence to CKSyncEngine callback asset ownership; Verify: queued-publication hypothesis falsified, callback-source regression red.
- [x] Rehome fetched/saved CKAssets before store mutation; Verify: expiry + immutable-path tests green under debug and release optimization.
- [x] Machine verify; Verify: CloudKit 704, Kit 188, signed app 257, generic iOS build, diff check.
- [x] Cut/upload build 177; Verify: archive/export/upload succeeded and App Store Connect reached `VALID`.
- [?] Device retest; Sel owner cross-device list/detail + restart passed; Roshar repeated photo replacement without relaunch and participant gate remain.

## Blockers
- Install build 177 on Roshar; repeat photo replacement without relaunch.
- Sel + Roshar are owner/same-account representatives, not a participant or clean-account matrix.
- Offline WDA check needs a non-Wi-Fi control path; current endpoint is the device LAN address.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.
