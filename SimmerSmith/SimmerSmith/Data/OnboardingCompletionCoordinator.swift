#if canImport(CloudKit)
import Foundation

@MainActor
struct OnboardingCompletionCoordinator {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case projectionMismatch

        var errorDescription: String? {
            switch self {
            case .projectionMismatch: "Onboarding data did not round-trip to the private plane."
            }
        }
    }

    let profileRepository: ProfileRepository
    let preferenceRepository: PreferenceRepository

    @discardableResult
    func stage(_ draft: OnboardingDraft) throws -> OnboardingDraft {
        let normalized = try draft.normalized()
        try profileRepository.setSettings([
            OnboardingSettings.draft: try normalized.encoded(),
        ])
        return normalized
    }

    @discardableResult
    func resumeStagedCompletion() throws -> OnboardingDraft? {
        profileRepository.reload()
        guard let encodedDraft = profileRepository.settings[OnboardingSettings.draft],
              !encodedDraft.isEmpty else { return nil }
        let staged = try OnboardingDraft.decode(encodedDraft)

        try preferenceRepository.reconcileAvoidancePreferences(staged.ingredientChoices)
        try profileRepository.setSettings([
            OnboardingSettings.householdSize: String(staged.householdSize),
            OnboardingSettings.likedCuisines: try Self.encode(staged.likedCuisines),
            OnboardingSettings.timeZone: staged.timeZoneIdentifier,
        ])
        profileRepository.reload()
        preferenceRepository.reload()

        guard try projectedDraft() == staged else {
            throw Error.projectionMismatch
        }
        try profileRepository.setSettings([
            OnboardingSettings.version: "1",
            OnboardingSettings.state: OnboardingLifecycleState.completed.rawValue,
            OnboardingSettings.snoozeUntil: "",
            OnboardingSettings.draft: "",
        ])
        return staged
    }

    func complete(_ draft: OnboardingDraft) throws {
        _ = try stage(draft)
        guard try resumeStagedCompletion() != nil else {
            throw Error.projectionMismatch
        }
    }

    private func projectedDraft() throws -> OnboardingDraft {
        let choices = preferenceRepository.preferences.compactMap { preference -> OnboardingIngredientChoice? in
            guard preference.active,
                  let mode = OnboardingIngredientMode(rawValue: preference.choiceMode) else { return nil }
            return OnboardingIngredientChoice(
                baseIngredientID: preference.baseIngredientId,
                baseIngredientName: preference.baseIngredientName,
                mode: mode
            )
        }
        return try OnboardingDraft(
            householdSize: OnboardingProfileValues.householdSize(from: profileRepository.settings),
            ingredientChoices: choices,
            likedCuisines: OnboardingProfileValues.likedCuisines(from: profileRepository.settings),
            timeZoneIdentifier: profileRepository.settings[OnboardingSettings.timeZone] ?? ""
        ).normalized()
    }

    private static func encode(_ cuisines: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(cuisines), as: UTF8.self)
    }
}
#endif
