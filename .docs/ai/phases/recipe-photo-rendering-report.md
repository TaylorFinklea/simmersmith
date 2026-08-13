# Recipe Photo Rendering — Implementation Report

Date: 2026-08-12
Branch: `codex/recipe-photo-rendering`
Base: build-174 commit `72c4033`
Status: machine-complete; awaiting human UI verification

## Outcome

- Existing CloudKit recipe photos now render through the shared recipe visual on detail, hero,
  compact, card, and list-row surfaces.
- The editorial gradient and meal icon remain the immediate, no-photo, missing-asset, and decode-failure fallback.
- Decoded images are downsampled off-main to 1024 pixels, coalesced, and held in a 40-image `NSCache`;
  raw bytes are not retained.
- CloudKit image replacements revise only the affected summary token. Successful legacy regenerate,
  upload, and remove mutations invalidate only that recipe; failures do not invalidate.
- Per-recipe regenerate, upload, and remove controls are restored. Settings' bulk backfill action remains hidden.

## Commits

- `5e11dc2` — revision recipe image tokens
- `dc68e59` — add bounded image loader
- `b51d16a` — render stored recipe photos
- `fdd1c91` — refresh photos after image changes

## Verification

- Focused TDD: mapper 9 passed; loader 9 passed; loader + repository 13 passed; loader + mutation 11 passed.
- `swift test --package-path SimmerSmithKit`: 188-test run in 6 suites passed; entitled-host-only cases remained expected skips.
- `swift test --package-path SimmerSmithCloudKit`: 701 tests in 10 suites passed.
- Signed `SimmerSmithTests` on iPhone 17 Pro / iOS 26.5: 255/255 passed, 0 failed, 0 skipped.
- Generic iOS Simulator build with signing disabled: `BUILD SUCCEEDED`.
- `git diff --check`: passed.
- Local `main` remains clean at `72c4033`; no merge, push, build cut, build-number bump, or upload occurred.

## Human verification gate

- [ ] Existing photos render with the correct crop in recipe list, hero, compact, card, and detail surfaces.
- [ ] A recipe without a photo keeps the gradient and meal icon.
- [ ] Rapid scrolling remains smooth and never flashes an empty rectangle.
- [ ] Regenerate and upload replace the visible photo; remove returns to the illustration.
- [ ] Offline relaunch shows locally available assets and safely falls back for unavailable assets.

This gate is independent of build 174's onboarding and owner/participant crash-durability checks.
