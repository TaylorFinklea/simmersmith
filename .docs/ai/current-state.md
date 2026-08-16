# Current State
Branch: main
Status: build 177 VALID; callback-time asset ownership fix ready for physical retest.
Reports: `phases/normal-mode-crash-durability-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Trace delayed build-176 fence to CKSyncEngine callback asset ownership; Verify: queued-publication hypothesis falsified, callback-source regression red.
- [x] Rehome fetched/saved CKAssets before store mutation; Verify: expiry + immutable-path tests green under debug and release optimization.
- [x] Machine verify; Verify: CloudKit 704, Kit 188, signed app 257, generic iOS build, diff check.
- [x] Cut/upload build 177; Verify: archive/export/upload succeeded and App Store Connect reached `VALID`.
- [?] Device retest; Roshar owner repeated photo replacement without relaunch, then Sel cross-device render; participant gate remains.

## Blockers
- Install build 177 from TestFlight before physical retest; Roshar and Sel were last paired/available.
- Sel + Roshar are owner/same-account representatives, not a participant or clean-account matrix.
- Offline WDA check needs a non-Wi-Fi control path; current endpoint is the device LAN address.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.
