# e0a Shadow Mirror — P1e Hardening Evidence

Date: 2026-07-15
Status: build 157 device gate failed safely; repair feedback loop fixed and automated gates green; build 158 device rerun pending
Scope: P1 shadow capture only. The active store remains the source of truth; no cache-first UI or P2 restore behavior is enabled.

## Automated evidence

- `ShadowMirrorCheckpointTests.failedPublicationKeepsPriorGeneration`: each pre-pointer failure point (`afterRecordsWrite`, `afterStateWrite`, `afterManifestWrite`) repeated twice. Every run retained the prior generation, coverage revision, and canonical logical digest.
- `ShadowMirrorCheckpointTests.postPointerCrashDoesNotReplayIncludedJournalEntry`: `afterPointerPublication` repeated twice. Every recovery retained the journal entry exactly once at the manifest high-water.
- `ShadowMirrorRuntimeTests.badCheckpointFallsBackWithoutHydration`: removed checkpoint records are quarantined; `loadCurrent()` returns nil; a subsequent full-fetch boundary publishes fresh records; the active store remains empty.
- Existing corruption cases remain green: checksum-corrupt final frame, invalid interior frame, journal sequence gap, corrupt journal asset, records-only generation, state-only generation, and manifest/pointer mismatch all quarantine or reject the checkpoint without selecting it.
- `ConflictRepairTests.dedupeNoDuplicates` went red because no-duplicate repair returned every
  singleton keeper as a write; `EventMergeAdapterTests` now pins the exact changed-keeper /
  tombstone / repointed-link write set and a self-signaling repair pass that converges after one
  follow-up. Mutation verification restored the old adapter loop and reproduced 57 passes plus 58
  writes in 100 ms; the fixed path returns to exactly 2 passes and 2 required writes.
- `swift test --package-path SimmerSmithCloudKit` — **564 tests passed**.
- `swift test --package-path SimmerSmithKit` — **187 tests passed**.
- App-target gate — **90 tests passed** across 18 suites.
- `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO` — **BUILD SUCCEEDED**.
- GitHub Actions run `29437504939` — **green** under Xcode 26.3: both Swift packages, app build, and 90 app-target tests. The first run exposed an older-compiler isolation error in the detached account-identity task; `fb34fae` confines the session validation to its owning main actor while preserving asynchronous launch behavior.
- App Store Connect build **157** — uploaded and processed **VALID**; this is the signed device-test vehicle for the checklist below.

## Real-device P1 checklist — `[?] build 158 rerun pending`

Record device model, iOS version, app build, account role, and timestamp for each run.

1. Install the candidate TestFlight build on a real device with an existing owner household; confirm the household zone and iCloud account are available before launch.
2. Cold-launch after force-quitting. Confirm the existing P1 path still performs the normal full fetch and that no shadow checkpoint hydrates the active `HouseholdLocalStore` before that fetch.
3. While online, edit and delete representative household records, then wait for a clean sync. Confirm the user-visible store and sync status remain unchanged by shadow capture.
4. Repeat the same edit/delete flow offline, force-quit during the operation, relaunch, and reconnect. Confirm the app recovers through the existing full-fetch path and no record or delete is silently lost.
5. Run the signed build under Instruments File Activity (or an equivalent device file trace), filter to the app's shadow `journal.wal`, and collect at least 30 journal flushes spanning save and delete mutations. Record min, p50, p95, max, and the complete sample count in this report; do not claim a latency distribution until this measurement is captured.
6. If any checkpoint digest mismatch or quarantine is observed, capture the device log and leave P1e open for diagnosis; do not enable cache-first UI.

### Build 157 — Sel (failed safely, diagnosed)

- Device: iPad Air 11-inch (M2), iPadOS 26.5 (23F77), TestFlight build 157,
  owner/private household, 2026-07-15. The app cold-launched through the normal full-fetch path;
  no crash or partial active store was observed.
- Focused two-minute Instruments File Activity trace: **35 distinct `journal.wal` fsyncs** after
  de-duplicating accessibility rows by timestamp + duration. Min **0.02383 ms**, p50 **0.03608
  ms**, p95 **0.22242 ms**, max **0.38954 ms** (nearest-rank percentiles).
- Before failure, the current shadow generation contained 702 records; `records.json` and
  `engine-state.json` recomputed SHA-256 values matched the manifest and no quarantine existed.
- With Xcode Network Link set to 100% packet loss, a quarantine appeared. The condition was then
  stopped and Sel returned online. The user-visible app remained available through the existing
  full-fetch fallback; no SimmerSmith crash report existed.
- Quarantined evidence was structurally valid: both generation file hashes matched, the 898,866
  byte WAL contained 195 checksum-valid contiguous frames (53431...53625), no torn tail, and local
  replay succeeded. The durable outbox was the same **65 GroceryItem identities** repeated as
  generation 2 sent, generation 250 sent, and generation 251 pending; the WAL recorded gen-251
  sent + transient failure followed by gen-252 mutations for those same 65 identities.
- Root cause: every post-send `onStoreChanged` signaled `RepairScheduler`; grocery dedupe returned
  all live singleton `keepers`; `EventMergeAdapter` re-saved all 65 unchanged rows; that send
  signaled the same repair again. The quarantine was the intended fail-closed response once forced
  packet loss stressed this runaway delivery churn, not corrupt checkpoint bytes.
- Build-157 gate remains open: the explicit offline save/delete checklist was not completed, and
  build 158 must repeat online/offline recovery and prove that no new quarantine is created.
