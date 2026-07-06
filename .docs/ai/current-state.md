# Current State
Branch: main

## Plan
- [x] simmersmith-pwf: BGTask double-complete + APNs .noData-before-work — Verify: `xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=386E369A-CB32-4BBB-9080-719A770E1828 CODE_SIGNING_ALLOWED=NO` · tier_floor: senior · complexity: S — done: BackgroundSyncService single-fire `CompletionFlag` (OSAllocatedUnfairLock → exactly-once `setTaskCompleted`); natural path awaits `syncTask.value` before completing; expiration cancels `syncTask`+`timeoutTask` BY HANDLE (cancellation reaches sync via `Task.isCancelled` in `handleReminderStoreChange` — old `work.cancel()` never reached the unstructured sibling). AppDelegate APNs routes via `MainActor.assumeIsolated` BEFORE `completionHandler(.noData)` (was fired synchronously before the detached `Task`). xcodebuild BUILD SUCCEEDED (backstop-verified on main). Arena candidate A (pi-glm52, opencode-go/glm-5.2 @ xhigh) applied by acting lead after Conductor judge format-bug + no-unique-winner; see decisions.md 2026-07-06.

## Blockers
- none

## Open Questions
- none
