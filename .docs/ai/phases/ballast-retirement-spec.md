# Ballast Retirement Spec

Date: 2026-08-06
Status: approved by owner direction

## Goal

- SimmerSmith builds, tests, archives, and runs without a Ballast checkout or credential.
- Voice week planning keeps the existing shipping parse path: on-device parsing when separately enabled and available, otherwise `CloudParseService`.

## Scope

- Remove `SimmerSmithBallastAdapter` and its evaluator/preflight executables, resources, and tests.
- Remove the app-target package dependency and regenerate the Xcode project.
- Remove the dormant Ballast branch from `VoicePlanningCoordinator`.
- Remove the Ballast-only baseline runner UI/controller/tests and AI-service identity-lease scaffolding.
- Remove CI's private Ballast checkout, secret, trust flag, and conditional app-build/test skips; app checks run for every CI event.
- Supersede the Ballast quarantine ADR and retire its roadmap/device gate. Keep historical phase specs/reports as evidence, not active instructions.
- Remove Ballast from build-174 blockers; Apple signing and App Store Connect assets remain independent release gates.

## Exclusions

- No change to `CloudParseService`, provider selection, prompts, or user API keys.
- No re-enablement or redesign of `OnDeviceParseService`; its existing default-off policy remains.
- No TestFlight upload or Git push in this change.

## Acceptance

- No shipping source, project, package, test, or CI workflow depends on or imports Ballast.
- Normal voice planning still compiles through the existing cloud fallback path.
- Project generation succeeds with no sibling `ballast/` directory.
- Swift package suites and the app build/test gate pass without Ballast.
- Build 174 metadata and crash-durability changes remain intact.

## Verify

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate --spec SimmerSmith/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
bash scripts/dev-sim.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
git diff --check
```
