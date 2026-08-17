# Privacy + terms re-host report

Status: local implementation complete on `codex/privacy-terms-rehost`; not pushed/published.

## Shipped in branch

- GitHub Pages privacy policy rewritten for CloudKit, household sharing, BYO-key AI, permissions,
  Reminders, notifications, backups, retention/deletion, and tracking.
- Terms page added with current free-product language and conditional future purchase terms.
- Home/support content and navigation removed obsolete server-era claims.
- App legal URLs centralized and used by paywall plus Settings → About.
- Static site route/navigation tests and app URL contract tests added.

## Verification

- `python3 -m unittest tests/test_legal_site.py` — 3 tests passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path SimmerSmithKit`
  — 190 tests passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path SimmerSmithCloudKit`
  — 704 tests passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build-for-testing -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,id=DF72454E-C115-41E1-B12D-F9B5BF63C388' -derivedDataPath /private/tmp/simmersmith-privacy-final CODE_SIGNING_ALLOWED=NO`
  — test build succeeded.
- `git diff --check` — clean.

## External gates

- Human legal review.
- Human ASC privacy questionnaire decisions in `privacy-policy-asc-label-notes.md`.
- Merge/push, GitHub Pages deployment, and live URL verification.
- Build 177 Roshar device gate remains independent and pending on `main`.
