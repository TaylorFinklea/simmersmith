# JFN Deterministic Onboarding — Closeout Report

Date: 2026-08-08
Provenance: role worker; model gpt-5.6-luna; reasoning high
Status: deterministic implementation complete; named human UI gate pending

## Shipped behavior

- Newly minted households receive a four-screen, keyless onboarding flow.
- Lifecycle is receipt-backed and private-plane durable: pending, 24-hour first-dismiss snooze,
  retired second dismissal, completed after verified writes, and manual Settings relaunch.
- Household size, avoids/allergies, cuisines, and timezone feed the existing planning and recipe
  serving seams without an AI call or shared-schema/backend/web change.
- Exact implementation commits (oldest first): `02576b7` lifecycle; `bdf5dcc` lifecycle persistence;
  `8405ef0` atomic completion; `1a7879e` mint gating; `1ac0e65` terminal-state persistence;
  `220f35f` four-screen flow; `f1db02e` planning inputs; `ed0fbfa` generated-recipe defaults;
  `78f5189` fractional servings preservation.

## Files and architecture at a glance

- App model/receipt/boot: `OnboardingModel.swift`, `OnboardingMintReceiptStore.swift`,
  `AppState+Onboarding.swift`, `AppState.swift`, `AppState+Recipes.swift`, `RootView.swift`.
- Private persistence: `OnboardingCompletionCoordinator.swift`, `ProfileRepository.swift`,
  `PreferenceRepository.swift`.
- UI and settings entry: `Features/Onboarding/OnboardingFlow.swift`, `SettingsView.swift`.
- Planning/recipe seams: `WeekGenContextGatherer.swift`, `AppState+WeekGen.swift`,
  `ToolRegistry.swift`, and `AIProviderKit` planning/prompt files.
- Focused coverage: onboarding app-state, persistence, policy, planning, and prompt tests.

## Deterministic verification

Commands were run serially with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` where
specified:

1. `swift test --package-path SimmerSmithCloudKit` — **passed**, 701 tests in 10 suites.
2. `swift test --package-path SimmerSmithKit` — **passed**, 187 tests in 6 suites; entitlement-only
   private-plane cases were skipped by the existing test guard.
3. `xcodegen generate --spec SimmerSmith/project.yml` — **passed**, project regenerated with no
   tracked diff.
4. `xcodebuild test ... -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests ...` — **passed**, 242 tests in 46 suites. Simulator emitted expected no-iCloud-account and background-task registration diagnostics; no test failures.
5. `xcodebuild build ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` —
   **passed**. Existing compiler warnings remain outside this phase.
6. `git diff --check` — **passed**.

## Boundary audit

- `rg -n "AIService|AIRequest|generate\(" SimmerSmith/SimmerSmith/Features/Onboarding SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift` — no matches (expected exit 1).
- `git diff --stat cd0c2ae..HEAD -- SimmerSmithCloudKit/Sources/HouseholdRecords SimmerSmithCloudKit/Sources/CloudKitProvisioning .docs/ai/phases/phase0-schema.ckdb app web` — no output; no shared schema, backend, or web changes attributable to onboarding.

## Remaining human verification and parked gates

The current UI target only provides an account-agnostic launch-settles smoke. Do not add a shipping
debug bypass solely for onboarding. Human gate, verbatim: **clean account mints household -> four
screens -> first Skip -> no immediate return/What's New -> due after clock/device-date advance ->
second Skip -> no auto return -> Settings relaunch.**

Build 174 upload and the crash-durability device matrix remain separate parked gates and are not
claimed by this closeout.

## Self-review

- Scope limited to the prescribed handoff/report files plus the already-generated Xcode project.
- No product code changes were made during closeout; `.superpowers/` is intentionally gitignored SDD
  scratch and is not part of the tracked worktree.
- Deterministic gates are green; simulator entitlement/account diagnostics are expected environment
  noise, not product failures.

## Final repository state

After closeout, `git status --short` produced no output. The clean Git status is compatible with the
intentionally gitignored `.superpowers/` SDD workspace, which is not force-added or tracked.

## Final-review repair — 2026-08-08

- Commit `944250d` corrects the final-review findings in the ingredient onboarding step: opening the
  step now browses the canonical empty-query catalog, catalog failures expose a retry for the current
  query, and ingredient selections are keyed and managed by `(baseIngredientID, choiceMode)`.
- The Settings/manual-relaunch regression persists both `peanut/avoid` and `peanut/allergy`, then
  verifies that both draft rows and distinct SwiftUI identities survive the relaunch.
- Fresh app-host verification: the focused `OnboardingAppStateTests` target passed 16 tests; the full
  `SimmerSmithTests` run passed **243 tests in 46 suites** with the existing no-iCloud and
  background-task simulator diagnostics; generic iOS Simulator build passed.
- The signed-device human UI gate above remains unchanged and pending. After this report commit,
  `git status --short` is clean; `.superpowers/` remains ignored local SDD scratch.
