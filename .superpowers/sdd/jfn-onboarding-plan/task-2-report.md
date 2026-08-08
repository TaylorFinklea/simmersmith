# Task 2 report — checked private-plane writes and crash-replay completion

Provenance: role worker; model gpt-5.6-luna; reasoning high.

## Implementation

- Added `ProfileRepository` fixed-store initialization and checked `setSettings(_:) throws` with the onboarding-owned allowlist, one-save batch persistence, reload-after-write, and `ProfileRepositoryError`.
- Added `PreferenceRepository.reconcileAvoidancePreferences(_:) throws` with normalized onboarding choices, deterministic lowest-rank/record-key reuse, duplicate/absent avoid/allergy cleanup, preservation of preferred/other modes, one save, and one reload.
- Added `OnboardingCompletionCoordinator` staging, replay after partial domain writes, projection verification, and final completion batch that clears the draft only after a successful match.
- Added three persistence/replay tests and regenerated the Xcode project to include the new source/test files.

## Files

- `SimmerSmith/SimmerSmith/Data/ProfileRepository.swift`
- `SimmerSmith/SimmerSmith/Data/PreferenceRepository.swift`
- `SimmerSmith/SimmerSmith/Data/OnboardingCompletionCoordinator.swift`
- `SimmerSmith/SimmerSmithTests/OnboardingPersistenceTests.swift`
- `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

## Verification

RED (before implementation, after xcodegen):

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/OnboardingPersistenceTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Compilation failed as expected for the missing fixed profile initializer/error, avoidance reconciliation, and completion coordinator APIs.

GREEN (after implementation and project regeneration): the same command passed. `OnboardingPersistenceTests` ran 3 tests with 0 failures.

## Self-review

- Checked repository writes remain scoped to the existing profile allowlist plus `OnboardingSettings.ownedKeys`.
- Checked replay ordering: stage → avoidance reconciliation → domain settings → reload/projection check → final completion batch; draft remains until the final batch.
- Checked reconciliation does not mutate preferred or unknown choice modes and chooses the lowest rank/record key for duplicates.

## Concerns

- The focused build emits pre-existing app warnings and simulator background-task/app-launch diagnostics; no Task 2 test failures.

## Commit

- `a318a57` — `feat: persist onboarding atomically`
