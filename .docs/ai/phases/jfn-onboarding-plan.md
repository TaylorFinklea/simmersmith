# Deterministic Onboarding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the owner-approved four-screen, keyless onboarding flow only for newly minted households, with crash-safe private persistence and immediate planning-context use.

**Architecture:** Carry an explicit mint origin through the existing household boot path and bridge its only crash window with a durable local receipt. Keep lifecycle, the staged completion draft, and planning inputs in the existing private profile plane; reconcile real ingredient-preference rows before marking completion. Present one root-owned SwiftUI flow and feed household size/cuisines into the existing planning and recipe prompt seams.

**Tech Stack:** Swift 6, SwiftUI, Observation, SwiftData private plane, CloudKit household boot, Swift Testing, XcodeGen, AIProviderKit.

## Global Constraints

- iOS deployment target remains 26.0; no new package dependency.
- Automatic onboarding is created only by an exact household mint; absent state means no automatic presentation.
- First automatic dismissal snoozes exactly 24 hours; second automatic dismissal retires the prompt.
- Four screens only: household size, avoids/allergies, favorite cuisines, Monday/timezone confirmation.
- Household size range is 1...12 and defaults to 4 when absent or invalid.
- Week start remains Monday and date serialization remains UTC.
- No AI call, conversational interview, shared CloudKit schema, new record type, backend, Fly.io, or web code.
- Completion stages a normalized private draft before domain writes and persists `completed` only after projection verification.
- Existing explicit servings and event attendee counts always override the household default.
- Do not push. Commit each task locally after its Verify command passes.

## File Map

- Create `SimmerSmith/SimmerSmith/App/OnboardingModel.swift` — pure draft, lifecycle, presentation, parsing, and policy types.
- Create `SimmerSmith/SimmerSmith/App/OnboardingMintReceiptStore.swift` — fsync-backed install-local mint receipt.
- Create `SimmerSmith/SimmerSmith/Data/OnboardingCompletionCoordinator.swift` — staged, idempotent private-plane completion.
- Create `SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift` — boot initialization, root presentation, dismissal, manual launch, and completion facade.
- Create `SimmerSmith/SimmerSmith/Features/Onboarding/OnboardingFlow.swift` — four-screen SwiftUI flow.
- Create `SimmerSmith/SimmerSmithTests/OnboardingPolicyTests.swift` — lifecycle and receipt tests.
- Create `SimmerSmith/SimmerSmithTests/OnboardingPersistenceTests.swift` — repository and completion-replay tests.
- Create `SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift` — mint/existing/manual presentation wiring tests.
- Modify `SimmerSmith/SimmerSmith/App/AppState.swift` — observable presentation state and receipt-store construction.
- Modify `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift` — typed owner resolution and onboarding initialization at private-plane readiness.
- Modify `SimmerSmith/SimmerSmith/App/RootView.swift` — root presentation arbitration and full-screen cover.
- Modify `SimmerSmith/SimmerSmith/Data/ProfileRepository.swift` — owned keys plus checked batch writes and fixed-store test seam.
- Modify `SimmerSmith/SimmerSmith/Data/PreferenceRepository.swift` — checked avoid/allergy set reconciliation.
- Modify `SimmerSmith/SimmerSmith/Data/WeekGenContextGatherer.swift` — explicit cuisine precedence and default servings.
- Modify `SimmerSmith/SimmerSmith/Data/ToolRegistry.swift` — expose default servings in `preferences_get`.
- Modify `SimmerSmith/SimmerSmith/App/AppState+WeekGen.swift` — gather the new private planning inputs.
- Modify `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift` — pass effective servings into recipe prompts.
- Modify `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift` — manual Meal planning setup entry.
- Modify `SimmerSmithCloudKit/Sources/AIProviderKit/WeekGenContext.swift` — `PlanningContext.defaultServings`.
- Modify `SimmerSmithCloudKit/Sources/AIProviderKit/WeekGenPrompt.swift` — serving directive and dynamic schema example.
- Modify `SimmerSmithCloudKit/Sources/AIProviderKit/AssistantSystemPrompt.swift` — assistant serving context.
- Modify `SimmerSmithCloudKit/Sources/AIProviderKit/RecipeAIPrompt.swift` — dynamic serving defaults for generated recipes.
- Modify focused tests in `SimmerSmith/SimmerSmithTests/WeekGenContextGathererTests.swift`, `SimmerSmith/SimmerSmithTests/ToolRegistryAssistantContextTests.swift`, `SimmerSmithCloudKit/Tests/AIProviderKitTests/WeekGenTests.swift`, `AssistantSystemPromptTests.swift`, and `RecipeAITests.swift`.
- Regenerate `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj` after adding source/test files.

---

### Task 1: Pure onboarding lifecycle and durable mint receipt

**Files:**
- Create: `SimmerSmith/SimmerSmith/App/OnboardingModel.swift`
- Create: `SimmerSmith/SimmerSmith/App/OnboardingMintReceiptStore.swift`
- Create: `SimmerSmith/SimmerSmithTests/OnboardingPolicyTests.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState.swift` (`HouseholdLifecyclePaths` only)
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `OnboardingSettings`, `OnboardingProfileValues`, `OnboardingDraft`, `OnboardingIngredientChoice`, `OnboardingLifecycle`, `OnboardingPolicy`, `OnboardingPresentation`, `OwnerHouseholdResolutionOrigin`.
- Produces: `OnboardingMintReceiptStore.load/save/clear` over `HouseholdLifecyclePaths.onboardingMintReceiptURL`.

- [x] **Step 1: Write lifecycle and receipt tests**

Create `OnboardingPolicyTests.swift` with fixed-clock cases for pending, future snooze, due snooze, completed, retired, malformed, first dismissal, and second dismissal. Add a real temporary-file round trip:

```swift
import Foundation
import Testing

@testable import SimmerSmith

@Suite(.serialized)
struct OnboardingPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func firstDismissalSnoozesExactlyOneDay() throws {
        let update = try #require(OnboardingPolicy.dismissalUpdate(
            lifecycle: .pending,
            now: now
        ))
        #expect(update.state == .pending)
        #expect(update.dismissCount == 1)
        #expect(update.snoozeUntil == now.addingTimeInterval(86_400))
        #expect(OnboardingPolicy.automaticDecision(for: update, now: now) == .wait)
        #expect(OnboardingPolicy.automaticDecision(
            for: update,
            now: now.addingTimeInterval(86_400)
        ) == .present)
    }

    @Test func secondDismissalRetiresAutomaticPresentation() throws {
        let once = OnboardingLifecycle(
            version: 1,
            state: .pending,
            dismissCount: 1,
            snoozeUntil: now
        )
        let twice = try #require(OnboardingPolicy.dismissalUpdate(lifecycle: once, now: now))
        #expect(twice.state == .retired)
        #expect(twice.dismissCount == 2)
        #expect(twice.snoozeUntil == nil)
        #expect(OnboardingPolicy.automaticDecision(for: twice, now: now) == .none)
    }

    @Test func absentAndMalformedSettingsFailClosed() {
        #expect(OnboardingLifecycle(settings: [:]) == nil)
        #expect(OnboardingLifecycle(settings: [
            OnboardingSettings.version: "1",
            OnboardingSettings.state: "surprise",
        ]) == nil)
    }

    @Test func receiptRoundTripsAndMismatchIsVisibleToPolicy() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OnboardingMintReceiptStore(
            fileURL: directory.appendingPathComponent("receipt.json")
        )
        #expect(store.load() == .absent)
        try store.save(householdID: "household-new")
        #expect(store.load() == .valid(OnboardingMintReceipt(
            version: 1,
            householdID: "household-new"
        )))
        try store.clear()
        #expect(store.load() == .absent)
    }
}
```

- [x] **Step 2: Regenerate the Xcode project and prove the new tests fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate --spec SimmerSmith/project.yml
```

Then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/OnboardingPolicyTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: compilation fails because the onboarding types do not exist.

- [x] **Step 3: Implement the pure model and policy**

Define exact setting keys and strongly typed state in `OnboardingModel.swift`. Normalize sizes to 1...12, trim and deduplicate cuisine names case-insensitively, reject ingredient modes other than `avoid`/`allergy`, and validate the timezone with `TimeZone(identifier:)`.

```swift
enum OnboardingSettings {
    static let currentVersion = 1
    static let version = "onboarding_version"
    static let state = "onboarding_state"
    static let dismissCount = "onboarding_dismiss_count"
    static let snoozeUntil = "onboarding_snooze_until"
    static let draft = "onboarding_draft"
    static let householdSize = "household_size"
    static let likedCuisines = "liked_cuisines"
    static let timeZone = "timezone"

    static let ownedKeys: Set<String> = [
        version, state, dismissCount, snoozeUntil, draft,
        householdSize, likedCuisines, timeZone,
    ]
}

enum OnboardingProfileValues {
    static func householdSize(from settings: [String: String]) -> Int
    static func likedCuisines(from settings: [String: String]) -> [String]
}

enum OnboardingLifecycleState: String, Codable, Equatable {
    case pending
    case completed
    case retired
}

struct OnboardingLifecycle: Equatable {
    let version: Int
    let state: OnboardingLifecycleState
    let dismissCount: Int
    let snoozeUntil: Date?

    static let pending = Self(version: 1, state: .pending, dismissCount: 0, snoozeUntil: nil)
    init(version: Int, state: OnboardingLifecycleState, dismissCount: Int, snoozeUntil: Date?)
    init?(settings: [String: String])
    var settingValues: [String: String] { get }
}

enum OnboardingAutomaticDecision: Equatable { case present, wait, none }

enum OnboardingPolicy {
    static func automaticDecision(
        for lifecycle: OnboardingLifecycle,
        now: Date
    ) -> OnboardingAutomaticDecision

    static func dismissalUpdate(
        lifecycle: OnboardingLifecycle,
        now: Date
    ) -> OnboardingLifecycle?
}
```

Use these shared draft/presentation types so persistence, AppState, and SwiftUI do not invent parallel representations:

```swift
enum OnboardingIngredientMode: String, Codable, CaseIterable, Equatable {
    case avoid
    case allergy
}

enum OnboardingDraftError: Error, LocalizedError, Equatable {
    case householdSizeOutOfRange
    case invalidIngredient
    case invalidTimeZone
}

struct OnboardingIngredientChoice: Codable, Equatable, Hashable, Identifiable {
    let baseIngredientID: String
    let baseIngredientName: String
    var mode: OnboardingIngredientMode
    var id: String { baseIngredientID }
}

struct OnboardingDraft: Codable, Equatable {
    var householdSize: Int
    var ingredientChoices: [OnboardingIngredientChoice]
    var likedCuisines: [String]
    var timeZoneIdentifier: String

    func normalized() throws -> Self
    func encoded() throws -> String
    static func decode(_ value: String) throws -> Self
}

enum OnboardingPresentationMode: String, Equatable { case automatic, manual }

struct OnboardingPresentation: Identifiable, Equatable {
    let mode: OnboardingPresentationMode
    let draft: OnboardingDraft
    var id: String { mode.rawValue }
}

enum OwnerHouseholdResolutionOrigin: Equatable { case existing, minted }
```

`OnboardingProfileValues.householdSize` accepts only 1...12 and returns 4 otherwise.
`likedCuisines` decodes the stable JSON array, trims/deduplicates it case-insensitively, and returns
`[]` for missing or malformed JSON. `OnboardingDraft.normalized()` throws for an out-of-range size,
blank ingredient ID/name, unsupported mode, or invalid timezone rather than silently changing a
submitted value.

- [x] **Step 4: Implement the fsync-backed receipt**

Add `onboardingMintReceiptURL` beside the existing lifecycle files, then use `DurableLifecycleFileSupport.write/remove` rather than UserDefaults:

```swift
struct OnboardingMintReceipt: Codable, Equatable {
    let version: Int
    let householdID: String
}

final class OnboardingMintReceiptStore: @unchecked Sendable {
    enum Error: Swift.Error, Equatable { case invalidHouseholdID }

    enum State: Equatable {
        case absent
        case valid(OnboardingMintReceipt)
        case malformed
    }

    let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) { self.fileURL = fileURL }
    func load() -> State
    func save(householdID: String) throws
    func clear() throws
}
```

`save` must reject an empty household ID, encode sorted JSON with version 1, and durably write before returning. `load` maps unreadable/invalid bytes to `.malformed` and never fabricates eligibility.

- [x] **Step 5: Run the focused tests**

Run the Task 1 xcodebuild command again. Expected: `OnboardingPolicyTests` passes.

- [x] **Step 6: Commit Task 1**

```bash
git add SimmerSmith/SimmerSmith/App/OnboardingModel.swift SimmerSmith/SimmerSmith/App/OnboardingMintReceiptStore.swift SimmerSmith/SimmerSmith/App/AppState.swift SimmerSmith/SimmerSmithTests/OnboardingPolicyTests.swift SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "feat: add onboarding lifecycle policy"
```

---

### Task 2: Checked private-plane writes and crash-replay completion

**Files:**
- Modify: `SimmerSmith/SimmerSmith/Data/ProfileRepository.swift`
- Modify: `SimmerSmith/SimmerSmith/Data/PreferenceRepository.swift`
- Create: `SimmerSmith/SimmerSmith/Data/OnboardingCompletionCoordinator.swift`
- Create: `SimmerSmith/SimmerSmithTests/OnboardingPersistenceTests.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `OnboardingSettings`, `OnboardingDraft`, `OnboardingIngredientChoice` from Task 1.
- Produces: `ProfileRepository.setSettings(_:) throws` and fixed-store initializer.
- Produces: `PreferenceRepository.reconcileAvoidancePreferences(_:) throws`.
- Produces: `OnboardingCompletionCoordinator.complete(_:)` and `resumeStagedCompletion()`.

- [x] **Step 1: Write repository and completion tests**

Use `makeSimmerSmithPrivatePlaneContainer(inMemory: true)` and one `PrivatePlaneStore` for both repositories. Pin these behaviors:

```swift
@MainActor
@Suite(.serialized)
struct OnboardingPersistenceTests {
    @Test func checkedProfileBatchRoundTripsAllOwnedKeys() throws {
        let container = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
        let store = PrivatePlaneStore(context: container.mainContext)
        let profile = ProfileRepository(store: store)
        try profile.setSettings([
            OnboardingSettings.state: "pending",
            OnboardingSettings.householdSize: "3",
            OnboardingSettings.timeZone: "America/Chicago",
        ])
        #expect(profile.settings[OnboardingSettings.state] == "pending")
        #expect(profile.settings[OnboardingSettings.householdSize] == "3")
        #expect(profile.settings[OnboardingSettings.timeZone] == "America/Chicago")
        #expect(throws: ProfileRepositoryError.unsupportedKey("ai_openai_api_key")) {
            try profile.setSettings(["ai_openai_api_key": "forbidden"])
        }
    }

    @Test func avoidanceReconcileIsExactAndIdempotent() throws {
        let container = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
        let store = PrivatePlaneStore(context: container.mainContext)
        let preferences = PreferenceRepository(store: store)
        let choices = [
            OnboardingIngredientChoice(
                baseIngredientID: "peanut",
                baseIngredientName: "Peanuts",
                mode: .allergy
            ),
            OnboardingIngredientChoice(
                baseIngredientID: "cilantro",
                baseIngredientName: "Cilantro",
                mode: .avoid
            ),
        ]
        try preferences.reconcileAvoidancePreferences(choices)
        try preferences.reconcileAvoidancePreferences(choices)
        #expect(preferences.preferences.filter(\.active).count == 2)
        #expect(Set(preferences.preferences.map(\.baseIngredientId)) == ["peanut", "cilantro"])
    }

    @Test func stagedDraftResumesAfterPartialDomainWrites() throws {
        let container = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
        let store = PrivatePlaneStore(context: container.mainContext)
        let profile = ProfileRepository(store: store)
        let preferences = PreferenceRepository(store: store)
        let coordinator = OnboardingCompletionCoordinator(
            profileRepository: profile,
            preferenceRepository: preferences
        )
        let draft = OnboardingDraft(
            householdSize: 2,
            ingredientChoices: [.init(
                baseIngredientID: "shellfish",
                baseIngredientName: "Shellfish",
                mode: .allergy
            )],
            likedCuisines: ["Thai", "Italian"],
            timeZoneIdentifier: "America/Chicago"
        )
        try coordinator.stage(draft)
        try preferences.reconcileAvoidancePreferences(draft.ingredientChoices)
        let resumed = try coordinator.resumeStagedCompletion()
        #expect(resumed == try draft.normalized())
        #expect(profile.settings[OnboardingSettings.state] == "completed")
        #expect(profile.settings[OnboardingSettings.draft] == "")
        #expect(profile.settings[OnboardingSettings.householdSize] == "2")
        #expect(preferences.preferences.map(\.baseIngredientName) == ["Shellfish"])
    }
}
```

- [x] **Step 2: Regenerate and prove the persistence tests fail**

Run xcodegen, then:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests/OnboardingPersistenceTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
```

Expected: compilation fails on the missing checked repository and coordinator APIs.

- [x] **Step 3: Add checked profile writes**

Mirror `PreferenceRepository.StoreSource` so `ProfileRepository` supports both a live `HouseholdSession` and a fixed `PrivatePlaneStore?`. Expand the owned allowlist with all `OnboardingSettings.ownedKeys` and implement one-save batch writes:

```swift
enum ProfileRepositoryError: Error, Equatable {
    case storeUnavailable
    case unsupportedKey(String)
}

func setSettings(_ values: [String: String]) throws {
    for key in values.keys where !Self.nonAIKeys.contains(key) {
        throw ProfileRepositoryError.unsupportedKey(key)
    }
    guard let store else { throw ProfileRepositoryError.storeUnavailable }
    for key in values.keys.sorted() {
        try store.upsertProfileSetting(key: key, value: values[key] ?? "")
    }
    try store.save()
    reload()
}
```

Keep the existing `setSetting` call sites source-compatible by wrapping `setSettings([key: value])`, logging the thrown error, and preserving their nonthrowing signature.

- [x] **Step 4: Add exact avoid/allergy reconciliation**

Implement a throwing method that:

- normalizes every input through `OnboardingDraft.normalized()` semantics;
- filters existing rows to `choiceMode == "avoid" || choiceMode == "allergy"`;
- treats `(baseIngredientID, choiceMode)` as the logical key;
- reuses the lowest-rank/record-key row for a desired logical key;
- deletes duplicate logical rows and rows absent from the desired set;
- leaves `preferred` and every other choice mode untouched;
- saves once, reloads once, and throws `storeUnavailable` when no private store exists.

Use this exact public seam:

```swift
func reconcileAvoidancePreferences(
    _ choices: [OnboardingIngredientChoice]
) throws
```

- [x] **Step 5: Implement staged completion**

`OnboardingCompletionCoordinator` is `@MainActor` and concrete over the two repositories:

```swift
@MainActor
struct OnboardingCompletionCoordinator {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case projectionMismatch
    }

    let profileRepository: ProfileRepository
    let preferenceRepository: PreferenceRepository

    @discardableResult
    func stage(_ draft: OnboardingDraft) throws -> OnboardingDraft

    @discardableResult
    func resumeStagedCompletion() throws -> OnboardingDraft?

    func complete(_ draft: OnboardingDraft) throws
}
```

`stage` persists only `onboarding_draft`. `resumeStagedCompletion` decodes it, reconciles preferences, writes size/cuisines/timezone, reloads both repositories, compares normalized projections to the staged draft, then writes this final private batch:

```swift
[
    OnboardingSettings.version: "1",
    OnboardingSettings.state: OnboardingLifecycleState.completed.rawValue,
    OnboardingSettings.snoozeUntil: "",
    OnboardingSettings.draft: "",
]
```

`complete` calls `stage` then `resumeStagedCompletion`. Never clear the draft after a mismatch or thrown repository error.

- [x] **Step 6: Run the focused tests and commit**

Run the Task 2 test command. Expected: all `OnboardingPersistenceTests` pass.

```bash
git add SimmerSmith/SimmerSmith/Data/ProfileRepository.swift SimmerSmith/SimmerSmith/Data/PreferenceRepository.swift SimmerSmith/SimmerSmith/Data/OnboardingCompletionCoordinator.swift SimmerSmith/SimmerSmithTests/OnboardingPersistenceTests.swift SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "feat: persist onboarding atomically"
```

---

### Task 3: Mint-aware AppState lifecycle and boot integration

**Files:**
- Modify: `SimmerSmith/SimmerSmith/App/AppState.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift`
- Create: `SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift`
- Create: `SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: receipt, policy, repositories, and completion coordinator from Tasks 1-2.
- Produces: `pendingOnboarding`, `initializeOnboardingIfNeeded`, `evaluatePendingOnboarding`, `showOnboardingFromSettings`, `dismissAutomaticOnboarding`, `cancelOnboarding`, and `completeOnboarding`.
- Changes `resolveHouseholdID` from an optional string to an optional typed resolution carrying `.existing` or `.minted`.

- [x] **Step 1: Write AppState lifecycle tests**

Build AppState with an in-memory app model container, an injected lifecycle directory, and fixed private repositories. Test these exact cases:

```swift
@MainActor
@Suite(.serialized)
struct OnboardingAppStateTests {
    @Test func mintedHouseholdInitializesPendingAndClearsReceipt() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.onboardingMintReceiptStore.save(householdID: "new-household")
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        #expect(fixture.profile.settings[OnboardingSettings.state] == "pending")
        #expect(fixture.appState.onboardingMintReceiptStore.load() == .absent)
    }

    @Test func existingHouseholdWithoutReceiptNeverInitializes() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "existing-household",
            origin: .existing
        )
        #expect(fixture.profile.settings[OnboardingSettings.state] == nil)
    }

    @Test func matchingCrashReceiptRecoversOnDiscoveredHousehold() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.onboardingMintReceiptStore.save(householdID: "recovered-household")
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "recovered-household",
            origin: .existing
        )
        #expect(fixture.profile.settings[OnboardingSettings.state] == "pending")
    }

    @Test func manualLaunchWorksWithoutAutomaticEligibility() throws {
        let fixture = try OnboardingAppStateFixture()
        fixture.appState.showOnboardingFromSettings()
        #expect(fixture.appState.pendingOnboarding?.mode == .manual)
        fixture.appState.cancelOnboarding()
        #expect(fixture.appState.pendingOnboarding == nil)
    }
}
```

Define the fixture in the same test file so no test depends on a live iCloud account:

```swift
@MainActor
private final class OnboardingAppStateFixture {
    let directory: URL
    let privateContainer: ModelContainer
    let appState: AppState
    let profile: ProfileRepository
    let preferences: PreferenceRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-app-state-\(UUID().uuidString)")
        let appContainer = try makeSimmerSmithModelContainer(inMemory: true)
        privateContainer = try makeSimmerSmithPrivatePlaneContainer(inMemory: true)
        let store = PrivatePlaneStore(context: privateContainer.mainContext)
        profile = ProfileRepository(store: store)
        preferences = PreferenceRepository(store: store)
        let suite = "OnboardingAppStateTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        appState = AppState(
            modelContainer: appContainer,
            settingsStore: ConnectionSettingsStore(
                defaults: defaults,
                keychain: KeychainStore(service: suite)
            ),
            householdLifecycleDirectoryURL: directory
        )
        appState.profileRepository = profile
        appState.preferenceRepository = preferences
        appState.householdLaunchPhase = .ready
        appState.personalDataReadiness = .ready
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
```

Import `SwiftData` in this test file for `ModelContainer`.

- [x] **Step 2: Regenerate and prove the AppState tests fail**

Run xcodegen, then the app-test command from Task 2 with `-only-testing:SimmerSmithTests/OnboardingAppStateTests`. Expected: compilation fails on missing AppState seams.

- [x] **Step 3: Add AppState-owned onboarding state**

In `AppState` add:

```swift
@ObservationIgnored let onboardingMintReceiptStore: OnboardingMintReceiptStore
var pendingOnboarding: OnboardingPresentation?
```

Construct the store from `householdLifecyclePaths.onboardingMintReceiptURL` in the existing initializer. Do not clear it during ordinary teardown or account change; only authoritative resolution can classify a receipt as matching or mismatched.

Create `AppState+Onboarding.swift` with these exact main-actor methods:

```swift
func initializeOnboardingIfNeeded(
    householdID: String,
    origin: OwnerHouseholdResolutionOrigin
) throws

func evaluatePendingOnboarding(now: Date = .now)
func showOnboardingFromSettings()
func dismissAutomaticOnboarding(now: Date = .now) throws
func cancelOnboarding()
func completeOnboarding(_ draft: OnboardingDraft) throws
```

Initialization rules:

- existing lifecycle state always wins and a matching stale receipt is cleared;
- `.minted` or a matching valid receipt initializes version 1 pending;
- a valid receipt for another household is cleared only after authoritative household resolution;
- malformed receipt bytes do not initialize or delete private state;
- clearing the receipt happens only after checked private settings persist.

`evaluatePendingOnboarding` requires `householdLaunchPhase == .ready`, `personalDataReadiness == .ready`, no paywall/onboarding presentation, and a parsed `.present` decision. It builds the draft from a valid staged draft first, otherwise from current profile settings and active avoid/allergy preferences. Immediately before assigning an automatic presentation, it calls `markReleaseNotesSeen()`, which also clears any stale pending release-notes value.

- [x] **Step 4: Carry exact mint origin through owner boot**

In `AppState+Recipes.swift`, introduce:

```swift
struct OwnerHouseholdResolution: Equatable {
    let householdID: String
    let origin: OwnerHouseholdResolutionOrigin
}
```

Cached/recovery selection and discovered zones construct `.existing`. The zero-zone mint branch must:

1. generate the UUID;
2. durably save the matching onboarding receipt;
3. stop without creating a CloudKit zone if receipt persistence throws;
4. ensure the zone/profile;
5. return `.minted`.

Thread the resolution alongside `householdID` until repositories are wired. Call `initializeOnboardingIfNeeded` after `profileRepo.reload()` and before direct `.ready` publication. For cached boot, call it from `reloadPrivatePlaneIfCurrent` after the deferred private store opens so a crash receipt can recover on the next launch. Leave a matching receipt in place and surface a retryable `lastErrorMessage` when private initialization fails.

- [x] **Step 5: Run AppState tests and commit**

Run the focused `OnboardingAppStateTests` command. Expected: all tests pass.

```bash
git add SimmerSmith/SimmerSmith/App/AppState.swift SimmerSmith/SimmerSmith/App/AppState+Recipes.swift SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "feat: gate onboarding on household mint"
```

---

### Task 4: Root presentation, Settings entry, and four-screen SwiftUI flow

**Files:**
- Create: `SimmerSmith/SimmerSmith/Features/Onboarding/OnboardingFlow.swift`
- Modify: `SimmerSmith/SimmerSmith/App/RootView.swift`
- Modify: `SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift`
- Modify: `SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift`
- Regenerate: `SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `pendingOnboarding` and AppState lifecycle methods from Task 3.
- Produces: `OnboardingFlow`, root arbitration through `evaluateReadyPresentations`, and Settings manual launch.

- [x] **Step 1: Extend AppState tests for root arbitration**

Add tests proving:

- `.loading` private data defers both onboarding and release notes;
- `.ready` evaluates onboarding first;
- `.unavailable` cannot show onboarding and may evaluate release notes;
- automatic presentation calls `markReleaseNotesSeen()` before assigning `pendingOnboarding`;
- first dismissal stores a 24-hour snooze, second stores retired, and manual cancel changes neither.

Expose one root-facing method:

```swift
func evaluateReadyPresentations(now: Date = .now)
```

- [x] **Step 2: Implement deterministic root arbitration**

Replace RootView's release-notes-only ready callback with calls to `evaluateReadyPresentations()` on `householdLaunchPhase` and `personalDataReadiness` changes. Also observe `pendingPaywall`; when it changes to nil, call the same method so a launch-time paywall cannot permanently suppress onboarding. The method applies this order:

1. require `.ready` and no pending paywall;
2. if personal data is `.loading`, return;
3. if personal data is `.ready`, evaluate onboarding and stop if it presents;
4. if personal data is `.unavailable` or ready-without-onboarding, evaluate release notes.

Attach the root-owned full-screen cover before the sheets:

```swift
.fullScreenCover(item: $appState.pendingOnboarding) { presentation in
    OnboardingFlow(presentation: presentation)
        .environment(appState)
}
```

When an automatic flow is chosen, mark the current release notes seen before setting the presentation so a later Skip does not reveal What's New.

- [x] **Step 3: Build the four-screen flow**

`OnboardingFlow` owns `@State private var draft`, `step`, `ingredientSearch`, `ingredientResults`, `isSearching`, `isCompleting`, and `errorMessage`. Its initializer seeds draft from `presentation.draft`.

Use one `NavigationStack` and these exact step behaviors:

- size: Stepper bound to 1...12 with a VoiceOver value of “N people”;
- avoids/allergies: searchable catalog results from `appState.searchBaseIngredients(query:limit:)`, tap-to-add, segmented Avoid/Allergy mode, and Remove for selected rows;
- cuisines: buttons over `appState.recipeMetadata?.cuisines`, keyed by `ManagedListItem.id`, with checkmark plus selected accessibility trait; an unavailable/empty catalog shows Retry, which calls `await appState.refreshRecipeMetadata()`;
- plan setup: Monday–Sunday copy, detected timezone identifier, and a summary of size/constraint/cuisine counts.

Toolbar behavior:

- Back on steps 2-4;
- **Skip for now** only in automatic mode, calling `dismissAutomaticOnboarding()`;
- **Cancel** only in manual mode, calling `cancelOnboarding()`;
- Continue on steps 1-3;
- Done on step 4, calling `completeOnboarding(draft)`.

On completion error, keep the cover open, restore the Done button, and render `error.localizedDescription`. Never call an AI API. Avoid fixed text heights, add semantic labels/values and non-color selection indicators, and do not require animation so Dynamic Type, VoiceOver, and Reduce Motion remain usable.

- [x] **Step 4: Add the Settings entry**

Add a section before Ingredient Preferences:

```swift
Section {
    Button {
        appState.showOnboardingFromSettings()
    } label: {
        Label("Meal planning setup", systemImage: "person.2.crop.square.stack")
    }
} header: {
    SmithSectionHeader("meal planning")
}
```

The button must use the root-owned presentation rather than attaching another Settings sheet.

- [x] **Step 5: Build and run focused tests**

Run xcodegen, `OnboardingAppStateTests`, then:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: tests pass and the app builds with the new SwiftUI source.

- [x] **Step 6: Commit Task 4**

```bash
git add SimmerSmith/SimmerSmith/Features/Onboarding/OnboardingFlow.swift SimmerSmith/SimmerSmith/App/RootView.swift SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift SimmerSmith/SimmerSmith/Features/Settings/SettingsView.swift SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "feat: add deterministic onboarding flow"
```

---

### Task 5: Planning context, cuisine precedence, and week/assistant servings

**Files:**
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/WeekGenContext.swift`
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/WeekGenPrompt.swift`
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/AssistantSystemPrompt.swift`
- Modify: `SimmerSmith/SimmerSmith/Data/WeekGenContextGatherer.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+WeekGen.swift`
- Modify: `SimmerSmith/SimmerSmith/Data/ToolRegistry.swift`
- Modify tests: `SimmerSmith/SimmerSmithTests/WeekGenContextGathererTests.swift`
- Modify tests: `SimmerSmith/SimmerSmithTests/ToolRegistryAssistantContextTests.swift`
- Modify tests: `SimmerSmithCloudKit/Tests/AIProviderKitTests/WeekGenTests.swift`
- Modify tests: `SimmerSmithCloudKit/Tests/AIProviderKitTests/AssistantSystemPromptTests.swift`

**Interfaces:**
- Consumes: profile parsing helpers from Task 1.
- Produces: `PlanningContext.defaultServings: Int`, explicit cuisine merge, and dynamic week/assistant prompt text.

- [x] **Step 1: Write failing context and prompt tests**

Extend `WeekGenContextGathererTests`:

```swift
@Test func explicitCuisinesLeadAndOverrideLearnedDislikes() {
    let context = WeekGenContextGatherer.build(
        pantryStaples: [],
        dietaryGoal: nil,
        ingredientPreferences: [],
        preferenceSignals: [
            .init(signalType: "cuisine", name: "Thai", normalizedName: "thai", score: -2, active: true),
            .init(signalType: "cuisine", name: "Italian", normalizedName: "italian", score: 2, active: true),
        ],
        explicitLikedCuisines: ["Thai", "Mexican"],
        defaultServings: 3,
        recentWeeks: [],
        termAliases: [:]
    )
    #expect(context.likedCuisines == ["Thai", "Mexican", "Italian"])
    #expect(context.dislikedCuisines.isEmpty)
    #expect(context.defaultServings == 3)
}
```

Add AIProviderKit assertions that a context with `defaultServings: 3` produces both `"servings": 3` and an explicit “3 people” rule in WeekGenPrompt, and `Default household servings: 3` in AssistantSystemPrompt. Add a ToolRegistry assertion that `preferences_get` JSON contains `"default_servings":3`.

- [x] **Step 2: Prove the new tests fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit --filter 'WeekGen|AssistantSystemPrompt'
```

Then run the app tests filtered to `WeekGenContextGathererTests` and `ToolRegistryAssistantContextTests`. Expected: compilation or assertions fail because default servings and explicit cuisines are not wired.

- [x] **Step 3: Extend PlanningContext and gather inputs**

Add a defaulted property without breaking existing initializers:

```swift
public var defaultServings: Int

public init(
    hardAvoids: [String] = [],
    strongLikes: [String] = [],
    likedCuisines: [String] = [],
    dislikedCuisines: [String] = [],
    brands: [String] = [],
    staples: [String] = [],
    recentMeals: [String] = [],
    rules: [String] = [],
    dietaryGoal: DietaryGoalContext? = nil,
    allergies: [String] = [],
    termAliases: [String: String] = [:],
    defaultServings: Int = 4
)
```

Extend `WeekGenContextGatherer.build` with defaulted `explicitLikedCuisines: [String] = []` and `defaultServings: Int = 4`. Normalize names case-insensitively, keep explicit order first, append learned likes not already present, and remove explicit names from learned dislikes.

In `AppState.gatherWeekGenContext`, parse `profileRepository?.settings` through Task 1 helpers and pass both values. Invalid/absent size remains 4; invalid cuisine JSON becomes an empty explicit list.

- [x] **Step 4: Render servings through week and assistant seams**

In WeekGenPrompt use `context?.defaultServings ?? 4` in the JSON example and add this rule:

```swift
extraLines.append(
    "- Set every generated recipe's servings to \(defaultServings) unless the user explicitly requests another amount"
)
```

In `AssistantSystemPrompt.renderPlanningContext`, add `Default household servings: N` before Today's date. In `ToolRegistry.preferencesGet`, add `"default_servings": context.defaultServings`.

- [x] **Step 5: Run package and app tests; commit**

Run the Task 5 package command and the two focused app suites. Expected: all pass.

```bash
git add SimmerSmithCloudKit/Sources/AIProviderKit/WeekGenContext.swift SimmerSmithCloudKit/Sources/AIProviderKit/WeekGenPrompt.swift SimmerSmithCloudKit/Sources/AIProviderKit/AssistantSystemPrompt.swift SimmerSmithCloudKit/Tests/AIProviderKitTests/WeekGenTests.swift SimmerSmithCloudKit/Tests/AIProviderKitTests/AssistantSystemPromptTests.swift SimmerSmith/SimmerSmith/Data/WeekGenContextGatherer.swift SimmerSmith/SimmerSmith/App/AppState+WeekGen.swift SimmerSmith/SimmerSmith/Data/ToolRegistry.swift SimmerSmith/SimmerSmithTests/WeekGenContextGathererTests.swift SimmerSmith/SimmerSmithTests/ToolRegistryAssistantContextTests.swift
git commit -m "feat: apply onboarding preferences to planning"
```

---

### Task 6: Household default servings in recipe generation

**Files:**
- Modify: `SimmerSmithCloudKit/Sources/AIProviderKit/RecipeAIPrompt.swift`
- Modify: `SimmerSmithCloudKit/Tests/AIProviderKitTests/RecipeAITests.swift`
- Modify: `SimmerSmith/SimmerSmith/App/AppState+Recipes.swift`
- Modify: `SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift`

**Interfaces:**
- Consumes: `OnboardingProfileValues.householdSize(from:)` parsing from Task 1.
- Produces: `AppState.defaultHouseholdServings()` and prompt-builder `defaultServings` parameters.

- [x] **Step 1: Write failing recipe-serving tests**

Add RecipeAIPrompt tests proving:

```swift
@Test func suggestionUsesSuppliedHouseholdServings() {
    let prompt = RecipeAIPrompt.suggestionPrompt(
        goal: "weeknight dinner",
        defaultServings: 2
    )
    #expect(prompt.contains("\"servings\": 2"))
    #expect(prompt.contains("serve 2 people"))
}

@Test func variationPreservesPositiveRecipeServingsOverDefault() {
    let prompt = RecipeAIPrompt.variationPrompt(
        recipe: sampleRecipe(),
        goal: "vegetarian",
        defaultServings: 2
    )
    #expect(prompt.contains("\"servings\": 4"))
}
```

Add AppState helper tests for absent/invalid -> 4, private setting 2 -> 2, and explicit positive argument -> explicit.

- [x] **Step 2: Prove the recipe tests fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit --filter RecipeAI
```

Expected: compilation fails on the new `defaultServings` parameters.

- [x] **Step 3: Make recipe schema examples serving-aware**

Replace the constant schema with a function:

```swift
static func recipeSchemaHint(servings: Int = 4) -> String
```

Clamp nonpositive defaults to 4. Add `defaultServings: Int = 4` after the existing defaulted arguments on `variationPrompt`, `suggestionPrompt`, `companionPrompt`, and `refinePrompt`. Use a positive source recipe/draft serving count when present; otherwise use the supplied default. Add an explicit instruction that the generated recipe serves that count unless the user's text requests another amount. Extraction/web-search retain the existing 4-person schema example because they must extract source truth rather than impose household defaults.

- [x] **Step 4: Pass the private default from AppState**

Add:

```swift
func defaultHouseholdServings(explicit: Int = 0) -> Int {
    if explicit > 0 { return explicit }
    return OnboardingProfileValues.householdSize(
        from: profileRepository?.settings ?? [:]
    )
}
```

Change `generateRecipeSuggestionDraft` to `func generateRecipeSuggestionDraft(goal: String, servings: Int = 0) async throws -> RecipeAIDraft`, preserving every existing caller through the default argument. Pass the effective value to variation, suggestion, companion, and refine prompt builders. In `generateSideRecipeDraft`, forward its existing `servings` argument into `generateRecipeSuggestionDraft`; a positive value wins and zero falls back to the household default. Do not change event-generation code.

- [x] **Step 5: Run tests and commit**

Run RecipeAI package tests and focused `OnboardingAppStateTests`. Expected: all pass.

```bash
git add SimmerSmithCloudKit/Sources/AIProviderKit/RecipeAIPrompt.swift SimmerSmithCloudKit/Tests/AIProviderKitTests/RecipeAITests.swift SimmerSmith/SimmerSmith/App/AppState+Recipes.swift SimmerSmith/SimmerSmithTests/OnboardingAppStateTests.swift
git commit -m "feat: default generated recipes to household size"
```

---

### Task 7: Full verification, report, and durable closeout

**Files:**
- Create: `.docs/ai/phases/jfn-onboarding-report.md`
- Modify: `.docs/ai/phases/jfn-onboarding-plan.md`
- Modify: `.docs/ai/phases/jfn-onboarding-spec.md`
- Modify: `.docs/ai/current-state.md`
- Modify: `.docs/ai/roadmap.md`
- Modify: `.docs/ai/decisions.md` only if implementation changed a non-obvious approved decision.

**Interfaces:**
- Consumes: all prior task deliverables.
- Produces: complete verification evidence and exact remaining human gate, if any.

- [x] **Step 1: Record the named human UI gate**

The current UI-test target has only an account-agnostic launch-settles smoke and no deterministic household/private-plane launch injection. Do not add a shipping debug bypass solely for onboarding. Record this exact human gate in the report: clean account mints household -> four screens -> first Skip -> no immediate return/What's New -> due after clock/device-date advance -> second Skip -> no auto return -> Settings relaunch.

- [x] **Step 2: Run all deterministic verification**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodegen generate --spec SimmerSmith/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=SimmerSmithSim' -only-testing:SimmerSmithTests CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM='' PROVISIONING_PROFILE_SPECIFIER=''
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
git diff --check
```

Expected: both Swift packages, the complete app-host suite, generic simulator build, and whitespace check pass.

- [x] **Step 3: Audit the no-AI/no-shared-schema boundary**

Run:

```bash
rg -n "AIService|AIRequest|generate\(" SimmerSmith/SimmerSmith/Features/Onboarding SimmerSmith/SimmerSmith/App/AppState+Onboarding.swift
```

Expected: no matches.

Run:

```bash
git diff cd0c2ae..HEAD -- SimmerSmithCloudKit/Sources/HouseholdRecords SimmerSmithCloudKit/Sources/CloudKitProvisioning .docs/ai/phases/phase0-schema.ckdb app web
```

Expected: no shared schema, backend, or web changes attributable to onboarding.

- [x] **Step 4: Write the report and update handoff state**

`jfn-onboarding-report.md` records:

- behavior shipped and exact commits;
- files/architecture at a glance;
- test counts and commands from Step 2;
- no-AI/no-shared-schema audit result;
- any human UI/device verification still pending;
- explicit note that build 174 upload and crash-durability device matrix remain separate parked gates.

Mark the spec `implemented` only after deterministic verification passes. Check every completed plan box. Update roadmap Wk4 `jfn` as implemented or awaiting only its named human gate. Keep `current-state.md` at 20 lines or fewer and point to the report rather than restating history.

- [x] **Step 5: Commit closeout docs**

```bash
git add .docs/ai/phases/jfn-onboarding-report.md .docs/ai/phases/jfn-onboarding-plan.md .docs/ai/phases/jfn-onboarding-spec.md .docs/ai/current-state.md .docs/ai/roadmap.md .docs/ai/decisions.md SimmerSmith/SimmerSmith.xcodeproj/project.pbxproj
git commit -m "docs: close deterministic onboarding phase"
```

- [x] **Step 6: Confirm final repository state**

Run:

```bash
git status --short
git log --oneline -10
```

Expected: clean worktree, onboarding task commits present, no push performed.
