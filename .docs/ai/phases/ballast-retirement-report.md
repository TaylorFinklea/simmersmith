# Ballast Retirement Report

Date: 2026-08-06
Status: complete

## Result

- Deleted `SimmerSmithBallastAdapter`, its evaluator/preflight tools, resources, and tests.
- Removed the dormant Ballast parser branch; voice planning still falls through to `CloudParseService`.
- Removed the baseline runner UI/controller/tests and the Ballast-only AI identity lease.
- Removed the XcodeGen package/dependency and regenerated the project.
- Removed CI's private checkout, deploy-key dependency, trust flag, and conditional skips; app build and tests now run on every event.
- Corrected one stale recovery-path test setup exposed by the newly universal app-test gate: recovery now installs its durable plan before the test asserts post-recovery saves. Product code was unchanged by this correction.
- Build 174 no longer requires a sibling Ballast checkout and reached App Store Connect `VALID` on 2026-08-11.

## Verification

- `swift test --package-path SimmerSmithCloudKit`: 696 passed.
- `swift test --package-path SimmerSmithKit --skip-build`: 187 passed.
- `xcodebuild build ... generic/platform=iOS Simulator CODE_SIGNING_ALLOWED=NO`: succeeded without Ballast in the dependency graph.
- `bash scripts/dev-sim.sh`: created/selected `SimmerSmithSim` on iOS 26.5.
- App-host tests: 212 passed in 43 suites.
- Active app/project/CI Ballast reference scan: empty.
- Build 174 Release archive succeeded; automatic App Store export/upload succeeded; App Store Connect processing reached `VALID`.

## Remaining gates

- Physical-device cache-first-OFF owner/participant force-quit durability matrix.
