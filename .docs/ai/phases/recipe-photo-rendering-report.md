# Recipe Photo Rendering — Implementation Report

Date: 2026-08-12
Branch: `codex/recipe-photo-rendering`
Base: build-174 commit `72c4033`
Status: machine-complete; simulator UI gate partially verified, environment-blocked checks remain

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
- Branch tip follow-up — surface rejected CloudKit image writes and invalidate after accepted writes

## Verification

- Focused TDD: mapper 9 passed; loader 9 passed; loader + repository 13 passed; CloudKit/legacy
  mutation suite 4 passed. Rejected CloudKit save test was observed red before the repository fix.
- `swift test --package-path SimmerSmithKit`: 188-test run in 6 suites passed; entitled-host-only cases remained expected skips.
- `swift test --package-path SimmerSmithCloudKit`: 701 tests in 10 suites passed.
- Signed `SimmerSmithTests` on iPhone 17 Pro / iOS 26.5: 257/257 passed, 0 failed, 0 skipped.
- Signed iPhone 17 / iOS 26.5 simulator build: passed.
- `git diff --check`: passed.
- Local `main` remains clean at `72c4033`; no merge, push, build cut, build-number bump, or upload occurred.

Full-scheme note: the single launch UI smoke failed twice on the separate iPhone 17 Pro simulator
because CloudKit launch remained on `Opening your kitchen…` for 30 seconds. The app unit target is
green; the reproducible launch gate is outside the touched recipe-photo path and remains separate work.

## Human verification gate

- [ ] Existing photos render with the correct crop in recipe list, hero, compact, card, and detail
  surfaces. Verified: list, card, detail. Blocked: hero/compact could not be populated because the
  simulator household rejects favorite/week writes.
- [x] A recipe without a photo keeps the gradient and meal icon in list, card, and detail.
- [ ] Rapid scrolling remains smooth and never flashes an empty rectangle.
- [ ] Regenerate and upload replace the visible photo; remove returns to the illustration. Initial
  upload rendered across list/card/detail. Replacement and removal correctly surface the existing
  `Couldn't save this change safely` durability failure and preserve the current image; a successful
  replacement/removal needs a healthy household writer. Regenerate was not invoked, avoiding AI spend.
- [ ] Offline relaunch shows locally available assets and safely falls back for unavailable assets.

Simulator evidence used disposable recipe `QA Photo Rendering` on iPhone 17 / iOS 26.5. No AI image
generation ran. The test recipe remains; the accepted original image remains because later writes were
rejected by the household durability gate.

This gate is independent of build 174's onboarding and owner/participant crash-durability checks.
