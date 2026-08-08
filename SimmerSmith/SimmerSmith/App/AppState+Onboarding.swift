#if canImport(CloudKit)
import Foundation

enum OnboardingAppStateError: Error, LocalizedError, Equatable {
    case privatePlaneUnavailable
    case lifecycleDidNotPersist

    var errorDescription: String? {
        switch self {
        case .privatePlaneUnavailable:
            "Your personal meal-planning data is not ready yet."
        case .lifecycleDidNotPersist:
            "Your onboarding status did not save."
        }
    }
}

extension AppState {
    func initializeOnboardingIfNeeded(
        householdID: String,
        origin: OwnerHouseholdResolutionOrigin
    ) throws {
        guard let profileRepository else {
            throw OnboardingAppStateError.privatePlaneUnavailable
        }

        profileRepository.reload()
        let receiptState = onboardingMintReceiptStore.load()
        guard receiptState != .malformed else { return }

        let receipt: OnboardingMintReceipt?
        if case .valid(let storedReceipt) = receiptState {
            receipt = storedReceipt
        } else {
            receipt = nil
        }
        let receiptMatches = receipt?.householdID == householdID

        if OnboardingLifecycle(settings: profileRepository.settings) != nil {
            if receipt != nil {
                try onboardingMintReceiptStore.clear()
            }
            return
        }

        guard origin == .minted || receiptMatches else {
            if receipt != nil {
                try onboardingMintReceiptStore.clear()
            }
            return
        }

        let lifecycle = OnboardingLifecycle.pending
        try profileRepository.setSettings(lifecycle.settingValues)
        guard OnboardingLifecycle(settings: profileRepository.settings) == lifecycle else {
            throw OnboardingAppStateError.lifecycleDidNotPersist
        }
        if receipt != nil {
            try onboardingMintReceiptStore.clear()
        }
        mirrorProfileFromRepository()
    }

    func evaluatePendingOnboarding(now: Date = .now) {
        guard householdLaunchPhase == .ready,
              personalDataReadiness == .ready,
              pendingPaywall == nil,
              pendingOnboarding == nil,
              let profileRepository,
              let preferenceRepository else { return }

        profileRepository.reload()
        preferenceRepository.reload()
        guard let lifecycle = OnboardingLifecycle(settings: profileRepository.settings),
              OnboardingPolicy.automaticDecision(for: lifecycle, now: now) == .present,
              let draft = onboardingDraft(
                profileRepository: profileRepository,
                preferenceRepository: preferenceRepository
              ) else { return }

        markReleaseNotesSeen()
        pendingOnboarding = OnboardingPresentation(mode: .automatic, draft: draft)
    }

    func showOnboardingFromSettings() {
        guard pendingOnboarding == nil,
              let profileRepository,
              let preferenceRepository else { return }

        profileRepository.reload()
        preferenceRepository.reload()
        guard let draft = onboardingDraft(
            profileRepository: profileRepository,
            preferenceRepository: preferenceRepository
        ) else { return }
        pendingOnboarding = OnboardingPresentation(mode: .manual, draft: draft)
    }

    func dismissAutomaticOnboarding(now: Date = .now) throws {
        guard pendingOnboarding?.mode == .automatic,
              let profileRepository,
              let lifecycle = OnboardingLifecycle(settings: profileRepository.settings),
              let update = OnboardingPolicy.dismissalUpdate(lifecycle: lifecycle, now: now) else {
            return
        }
        try profileRepository.setSettings(update.settingValues)
        pendingOnboarding = nil
        mirrorProfileFromRepository()
    }

    func cancelOnboarding() {
        pendingOnboarding = nil
    }

    func completeOnboarding(_ draft: OnboardingDraft) throws {
        guard let profileRepository, let preferenceRepository else {
            throw OnboardingAppStateError.privatePlaneUnavailable
        }
        try OnboardingCompletionCoordinator(
            profileRepository: profileRepository,
            preferenceRepository: preferenceRepository
        ).complete(draft)
        pendingOnboarding = nil
        mirrorProfileFromRepository()
        mirrorPreferencesFromRepository()
    }

    private func onboardingDraft(
        profileRepository: ProfileRepository,
        preferenceRepository: PreferenceRepository
    ) -> OnboardingDraft? {
        if let encodedDraft = profileRepository.settings[OnboardingSettings.draft],
           !encodedDraft.isEmpty,
           let stagedDraft = try? OnboardingDraft.decode(encodedDraft) {
            return stagedDraft
        }

        let choices = preferenceRepository.preferences.compactMap { preference -> OnboardingIngredientChoice? in
            guard preference.active,
                  let mode = OnboardingIngredientMode(rawValue: preference.choiceMode) else {
                return nil
            }
            return OnboardingIngredientChoice(
                baseIngredientID: preference.baseIngredientId,
                baseIngredientName: preference.baseIngredientName,
                mode: mode
            )
        }
        let timeZoneIdentifier = profileRepository.settings[OnboardingSettings.timeZone]
            .flatMap(TimeZone.init(identifier:))?.identifier ?? TimeZone.current.identifier
        return try? OnboardingDraft(
            householdSize: OnboardingProfileValues.householdSize(from: profileRepository.settings),
            ingredientChoices: choices,
            likedCuisines: OnboardingProfileValues.likedCuisines(from: profileRepository.settings),
            timeZoneIdentifier: timeZoneIdentifier
        ).normalized()
    }
}
#endif
