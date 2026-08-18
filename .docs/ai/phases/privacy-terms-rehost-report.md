# Privacy + terms re-host report

Status: published from `main`; GitHub Pages built commit `a96095f` on 2026-08-17.

## Published scope

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
- Post-merge generic iOS Simulator build from `main` — succeeded.
- `git diff --check` — clean.
- Locked backend suite — 597 passed, 1 skipped, 4 subtests passed. Full Ruff retains 21
  pre-existing findings in untouched legacy files; `tests/test_legal_site.py` is clean.
- GitHub Pages build `1158246062` — `built` from `a96095f`; live Privacy and Terms pages returned
  HTTP 200 and contained the expected release content.

## External gates

- Human legal review.
- Human ASC privacy questionnaire decisions in `privacy-policy-asc-label-notes.md`.
- Build 177 Roshar device gate remains independent and pending on `main`.
