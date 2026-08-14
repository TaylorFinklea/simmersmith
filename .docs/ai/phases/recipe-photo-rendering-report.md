# Recipe Photo Rendering — Implementation Report

Date: 2026-08-13
Branch: `main`
Base: build-174 commit `72c4033`
Status: shipped in TestFlight build 175; physical UI gate partially verified, healthy-writer checks blocked

## Outcome

- Existing CloudKit recipe photos now render through the shared recipe visual on detail, hero,
  compact, card, and list-row surfaces.
- The editorial gradient and meal icon remain the immediate, no-photo, missing-asset, and decode-failure fallback.
- Decoded images are downsampled off-main to 1024 pixels, coalesced, and held in a 40-image `NSCache`;
  raw bytes are not retained.
- CloudKit image replacements revise only the affected summary token. Successful legacy regenerate,
  upload, and remove mutations invalidate only that recipe; failures do not invalidate.
- CloudKit regenerate/upload now also fail closed when the household writer rejects the save. The
  photo sheet remains open with the durability error instead of dismissing as if replacement worked.
- Per-recipe regenerate, upload, and remove controls are restored. Settings' bulk backfill action remains hidden.

## Commits

- `5e11dc2` — revision recipe image tokens
- `dc68e59` — add bounded image loader
- `b51d16a` — render stored recipe photos
- `fdd1c91` — refresh photos after image changes
- `607ea60` — surface rejected CloudKit image writes and invalidate after accepted writes
- `bb0c925` — prepare TestFlight build 175

## Verification

- Focused TDD: mapper 9 passed; loader 9 passed; loader + repository 13 passed; CloudKit/legacy
  mutation suite 4 passed. Rejected CloudKit save test was observed red before the repository fix.
- `swift test --package-path SimmerSmithKit`: 188-test run in 6 suites passed; entitled-host-only cases remained expected skips.
- `swift test --package-path SimmerSmithCloudKit`: 701 tests in 10 suites passed.
- Signed `SimmerSmithTests` on iPhone 17 Pro / iOS 26.5: 257/257 passed, 0 failed, 0 skipped.
- Signed iPhone 17 / iOS 26.5 simulator build: passed.
- `git diff --check`: passed.
- `scripts/release-ios.sh`: signed archive and upload passed; App Store Connect reported build 175 `VALID`.
- Feature branch fast-forwarded into local `main`; no push occurred.

Full-scheme note: the single launch UI smoke failed twice on the separate iPhone 17 Pro simulator
because CloudKit launch remained on `Opening your kitchen…` for 30 seconds. The app unit target is
green; the reproducible launch gate is outside the touched recipe-photo path and remains separate work.

## Human verification gate

- [ ] Existing photos render with the correct crop in recipe list, hero, compact, card, and detail
  surfaces. Verified: list/card/detail in simulator plus list/compact/detail on Sel and Roshar.
  Blocked: hero could not be populated because the household rejects favorite/week writes.
- [x] A recipe without a photo keeps the gradient and meal icon in list, card, and detail.
- [x] Rapid scrolling remains smooth and never flashes an empty rectangle. Two upward passes and
  one downward pass on Sel retained every row image or fallback.
- [ ] Regenerate and upload replace the visible photo; remove returns to the illustration. Initial
  upload rendered across list/card/detail on Sel, survived force-quit/relaunch, and synced to Roshar's
  list/detail. Replacement failed safely twice; removal failed safely on both Sel and Roshar with
  `Couldn't save this change safely`. A successful replacement/removal needs a healthy household
  writer. Regenerate was not invoked, avoiding AI spend.
- [ ] Offline relaunch shows locally available assets and safely falls back for unavailable assets.

Simulator evidence used disposable recipe `QA Photo Rendering` on iPhone 17 / iOS 26.5. Physical
evidence used Honey Garlic Butter Salmon en Papillote on Sel/iPadOS 26.6 and Roshar/iOS 26.6. No AI
image generation ran. The neutral uploaded test photo remains on Honey Garlic Butter Salmon because
cleanup is rejected by the household durability gate. Offline automation was not attempted because
WDA was reachable only through the devices' Wi-Fi addresses; severing the control path would not
produce trustworthy evidence.

This gate ships alongside build 175's onboarding and owner/participant crash-durability checks.

## Build 175 healthy-writer follow-up — 2026-08-14

The shared mutation blocker traced to fetched CloudKit photo assets expiring before asynchronous
checkpoint publication copied them. The repaired mirror stages callback-owned asset bytes while their
URLs are valid; the focused regression proves checkpoint publication and a later required WAL save both
succeed after the original asset disappears. Full CloudKit, Kit, signed app-target, and generic iOS
verification passed. Replacement/removal and cross-device rendering still need build 176 device proof.
