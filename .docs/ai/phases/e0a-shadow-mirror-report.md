# e0a Shadow Mirror — P1e Hardening Evidence

Date: 2026-07-15
Status: automated gate green; real-device latency gate awaiting human verification
Scope: P1 shadow capture only. The active store remains the source of truth; no cache-first UI or P2 restore behavior is enabled.

## Automated evidence

- `ShadowMirrorCheckpointTests.failedPublicationKeepsPriorGeneration`: each pre-pointer failure point (`afterRecordsWrite`, `afterStateWrite`, `afterManifestWrite`) repeated twice. Every run retained the prior generation, coverage revision, and canonical logical digest.
- `ShadowMirrorCheckpointTests.postPointerCrashDoesNotReplayIncludedJournalEntry`: `afterPointerPublication` repeated twice. Every recovery retained the journal entry exactly once at the manifest high-water.
- `ShadowMirrorRuntimeTests.badCheckpointFallsBackWithoutHydration`: removed checkpoint records are quarantined; `loadCurrent()` returns nil; a subsequent full-fetch boundary publishes fresh records; the active store remains empty.
- Existing corruption cases remain green: checksum-corrupt final frame, invalid interior frame, journal sequence gap, corrupt journal asset, records-only generation, state-only generation, and manifest/pointer mismatch all quarantine or reject the checkpoint without selecting it.
- `swift test --package-path SimmerSmithCloudKit` — **562 tests passed**.
- `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED**.

## Real-device P1 checklist — `[?] awaiting human verify`

Record device model, iOS version, app build, account role, and timestamp for each run.

1. Install a signed build on a real iPhone with an existing owner household; confirm the household zone and iCloud account are available before launch.
2. Cold-launch after force-quitting. Confirm the existing P1 path still performs the normal full fetch and that no shadow checkpoint hydrates the active `HouseholdLocalStore` before that fetch.
3. While online, edit and delete representative household records, then wait for a clean sync. Confirm the user-visible store and sync status remain unchanged by shadow capture.
4. Repeat the same edit/delete flow offline, force-quit during the operation, relaunch, and reconnect. Confirm the app recovers through the existing full-fetch path and no record or delete is silently lost.
5. Run the signed build under Instruments File Activity (or an equivalent device file trace), filter to the app's shadow `journal.wal`, and collect at least 30 journal flushes spanning save and delete mutations. Record min, p50, p95, max, and the complete sample count in this report; do not claim a latency distribution until this measurement is captured.
6. If any checkpoint digest mismatch or quarantine is observed, capture the device log and leave P1e open for diagnosis; do not enable cache-first UI.

Device results: not collected in this session; `xcrun devicectl list devices` returned `No devices found.` No on-device journal-flush latency distribution is claimed.
