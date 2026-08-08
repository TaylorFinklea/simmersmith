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
}

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
