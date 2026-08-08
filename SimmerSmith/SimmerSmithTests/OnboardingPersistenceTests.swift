import Foundation
import SimmerSmithKit
import Testing

@testable import SimmerSmith

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
        let normalized = try draft.normalized()
        #expect(resumed == normalized)
        #expect(profile.settings[OnboardingSettings.state] == "completed")
        #expect(profile.settings[OnboardingSettings.draft] == "")
        #expect(profile.settings[OnboardingSettings.householdSize] == "2")
        #expect(preferences.preferences.map(\.baseIngredientName) == ["Shellfish"])
    }
}
