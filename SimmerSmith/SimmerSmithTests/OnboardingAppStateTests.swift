import Foundation
import SimmerSmithKit
import SwiftData
import Testing

@testable import SimmerSmith

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

    @Test func loadingPrivateDataDefersOnboardingAndReleaseNotes() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        fixture.appState.personalDataReadiness = .loading

        fixture.appState.evaluateReadyPresentations()

        #expect(fixture.appState.pendingOnboarding == nil)
        #expect(fixture.appState.pendingReleaseNotes == nil)
    }

    @Test func readyPrivateDataPresentsOnboardingBeforeReleaseNotes() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        fixture.appState.pendingReleaseNotes = releaseNotesPresentation

        fixture.appState.evaluateReadyPresentations()

        #expect(fixture.appState.pendingOnboarding?.mode == .automatic)
        #expect(fixture.appState.pendingReleaseNotes == nil)
    }

    @Test func unavailablePrivateDataSkipsOnboardingAndEvaluatesReleaseNotes() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        fixture.appState.personalDataReadiness = .unavailable

        fixture.appState.evaluateReadyPresentations()

        #expect(fixture.appState.pendingOnboarding == nil)
        #expect(fixture.appState.pendingReleaseNotes != nil)
    }

    @Test func automaticPresentationMarksReleaseNotesSeen() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        fixture.appState.pendingReleaseNotes = releaseNotesPresentation

        fixture.appState.evaluateReadyPresentations()

        #expect(fixture.appState.pendingReleaseNotes == nil)
        #expect(ReleaseNotesStore().lastSeenBuild == ReleaseNotesStore().currentBuild)
    }

    @Test func firstAutomaticDismissalStoresTwentyFourHourSnooze() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        let firstDismissal = Date(timeIntervalSince1970: 2_000_000_000)
        fixture.appState.evaluatePendingOnboarding(now: firstDismissal)
        try fixture.appState.dismissAutomaticOnboarding(now: firstDismissal)

        fixture.profile.reload()
        let lifecycle = try #require(OnboardingLifecycle(settings: fixture.profile.settings))
        #expect(lifecycle.state == .pending)
        #expect(lifecycle.dismissCount == 1)
        #expect(lifecycle.snoozeUntil == firstDismissal.addingTimeInterval(86_400))
    }

    @Test func secondAutomaticDismissalStoresRetired() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )
        let firstDismissal = Date(timeIntervalSince1970: 2_000_000_000)
        let secondDismissal = firstDismissal.addingTimeInterval(86_400)
        fixture.appState.evaluatePendingOnboarding(now: firstDismissal)
        try fixture.appState.dismissAutomaticOnboarding(now: firstDismissal)
        fixture.appState.evaluatePendingOnboarding(now: secondDismissal)
        try fixture.appState.dismissAutomaticOnboarding(now: secondDismissal)

        fixture.profile.reload()
        let lifecycle = try #require(OnboardingLifecycle(settings: fixture.profile.settings))
        #expect(lifecycle.state == .retired)
        #expect(lifecycle.dismissCount == 2)
        #expect(lifecycle.snoozeUntil == nil)
    }

    @Test func manualCancelLeavesLifecycleUntouched() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.initializeOnboardingIfNeeded(
            householdID: "new-household",
            origin: .minted
        )

        fixture.appState.showOnboardingFromSettings()
        fixture.appState.cancelOnboarding()

        fixture.profile.reload()
        #expect(OnboardingLifecycle(settings: fixture.profile.settings) == .pending)
    }

    @Test func completionReloadsAsCompleted() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.appState.completeOnboarding(OnboardingDraft(
            householdSize: 2,
            ingredientChoices: [],
            likedCuisines: ["Thai"],
            timeZoneIdentifier: "UTC"
        ))

        fixture.profile.reload()
        let lifecycle = try #require(OnboardingLifecycle(settings: fixture.profile.settings))
        #expect(lifecycle.state == .completed)
        #expect(lifecycle.snoozeUntil == nil)
    }
    @Test func defaultHouseholdServingsFallsBackForAbsentAndInvalidSettings() throws {
        let absentFixture = try OnboardingAppStateFixture()
        #expect(absentFixture.appState.defaultHouseholdServings() == 4)

        let invalidFixture = try OnboardingAppStateFixture()
        try invalidFixture.profile.setSettings([OnboardingSettings.householdSize: "not-a-number"])
        #expect(invalidFixture.appState.defaultHouseholdServings() == 4)
    }

    @Test func defaultHouseholdServingsUsesPrivateSetting() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.profile.setSettings([OnboardingSettings.householdSize: "2"])
        #expect(fixture.appState.defaultHouseholdServings() == 2)
    }

    @Test func defaultHouseholdServingsPreservesExplicitPositiveValue() throws {
        let fixture = try OnboardingAppStateFixture()
        try fixture.profile.setSettings([OnboardingSettings.householdSize: "2"])
        #expect(fixture.appState.defaultHouseholdServings(explicit: 7) == 7)
    }
}

private let releaseNotesPresentation = ReleaseNotesPresentation(
    notes: [ReleaseNote(
        build: 174,
        version: "1.0.0",
        date: "August 3, 2026",
        headline: "Household edits stay put",
        new: [],
        improved: [],
        fixed: ["Shared household edits are more reliable."]
    )],
    previousNotes: []
)

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
        UserDefaults.standard.removeObject(forKey: ReleaseNotesStore.lastSeenBuildKey)
    }

    deinit {
        UserDefaults.standard.removeObject(forKey: ReleaseNotesStore.lastSeenBuildKey)
        try? FileManager.default.removeItem(at: directory)
    }
}
