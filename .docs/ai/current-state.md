# Current State
Branch: main
Status: callback-time asset ownership fix machine-green; next TestFlight RC not cut.
Reports: `phases/normal-mode-crash-durability-report.md`, `phases/recipe-photo-rendering-report.md`

## Plan
- [x] Trace delayed build-176 fence to CKSyncEngine callback asset ownership; Verify: queued-publication hypothesis falsified, callback-source regression red.
- [x] Rehome fetched/saved CKAssets before store mutation; Verify: expiry + immutable-path tests green under debug and release optimization.
- [x] Machine verify; Verify: CloudKit 704, Kit 188, signed app 257, generic iOS build, diff check.
- [ ] Cut/upload next RC; Verify: release script succeeds and App Store Connect reaches `VALID`.
- [?] Device retest; Roshar owner repeated photo replacement without relaunch, then Sel cross-device render; participant gate remains.

## Blockers
- Next TestFlight RC required before physical retest; Roshar and Sel are currently paired/available.
- Sel + Roshar are owner/same-account representatives, not a participant or clean-account matrix.
- Offline WDA check needs a non-Wi-Fi control path; current endpoint is the device LAN address.
- `.beads/` absent; do not reinitialize. `e0a` remains default-off pending device gates.
