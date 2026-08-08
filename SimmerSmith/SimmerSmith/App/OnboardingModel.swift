import Foundation

enum OnboardingSettings {
    static let currentVersion = 1
    static let version = "onboarding_version"
    static let state = "onboarding_state"
    static let dismissCount = "onboarding_dismiss_count"
    static let snoozeUntil = "onboarding_snooze_until"
    static let noSnoozeUntil = ""
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
    static func householdSize(from settings: [String: String]) -> Int {
        guard let value = settings[OnboardingSettings.householdSize],
              let size = Int(value),
              (1...12).contains(size) else { return 4 }
        return size
    }

    static func likedCuisines(from settings: [String: String]) -> [String] {
        guard let value = settings[OnboardingSettings.likedCuisines],
              let data = value.data(using: .utf8),
              let cuisines = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalizeCuisines(cuisines)
    }

    fileprivate static func normalizeCuisines(_ cuisines: [String]) -> [String] {
        var seen = Set<String>()
        return cuisines.compactMap { cuisine in
            let trimmed = cuisine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
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

    init(version: Int, state: OnboardingLifecycleState, dismissCount: Int, snoozeUntil: Date?) {
        self.version = version
        self.state = state
        self.dismissCount = dismissCount
        self.snoozeUntil = snoozeUntil
    }

    init?(settings: [String: String]) {
        guard let versionValue = settings[OnboardingSettings.version],
              let version = Int(versionValue),
              version == OnboardingSettings.currentVersion,
              let stateValue = settings[OnboardingSettings.state],
              let state = OnboardingLifecycleState(rawValue: stateValue),
              let dismissValue = settings[OnboardingSettings.dismissCount],
              let dismissCount = Int(dismissValue),
              dismissCount >= 0 else { return nil }

        let snoozeUntil: Date?
        if let value = settings[OnboardingSettings.snoozeUntil],
           value != OnboardingSettings.noSnoozeUntil {
            guard let date = Self.parseDate(value) else { return nil }
            snoozeUntil = date
        } else {
            snoozeUntil = nil
        }
        guard Self.isValid(
            version: version,
            state: state,
            dismissCount: dismissCount,
            snoozeUntil: snoozeUntil
        ) else { return nil }

        self.init(version: version, state: state, dismissCount: dismissCount, snoozeUntil: snoozeUntil)
    }

    var settingValues: [String: String] {
        [
            OnboardingSettings.version: String(version),
            OnboardingSettings.state: state.rawValue,
            OnboardingSettings.dismissCount: String(dismissCount),
            OnboardingSettings.snoozeUntil: snoozeUntil.map(Self.formatDate)
                ?? OnboardingSettings.noSnoozeUntil,
        ]
    }

    fileprivate var isValid: Bool {
        Self.isValid(
            version: version,
            state: state,
            dismissCount: dismissCount,
            snoozeUntil: snoozeUntil
        )
    }

    private static func isValid(
        version: Int,
        state: OnboardingLifecycleState,
        dismissCount: Int,
        snoozeUntil: Date?
    ) -> Bool {
        guard version == OnboardingSettings.currentVersion, dismissCount >= 0 else { return false }
        switch state {
        case .pending:
            return (dismissCount == 0 && snoozeUntil == nil)
                || (dismissCount == 1 && snoozeUntil != nil)
        case .completed:
            return snoozeUntil == nil
        case .retired:
            return dismissCount >= 2 && snoozeUntil == nil
        }
    }

    fileprivate static func formatDate(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }

    fileprivate static func parseDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        guard let seconds = Double(value), seconds.isFinite else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum OnboardingAutomaticDecision: Equatable {
    case present
    case wait
    case none
}

enum OnboardingPolicy {
    static func automaticDecision(
        for lifecycle: OnboardingLifecycle,
        now: Date
    ) -> OnboardingAutomaticDecision {
        guard lifecycle.isValid, lifecycle.state == .pending else { return .none }
        guard let snoozeUntil = lifecycle.snoozeUntil else { return .present }
        return now >= snoozeUntil ? .present : .wait
    }

    static func dismissalUpdate(
        lifecycle: OnboardingLifecycle,
        now: Date
    ) -> OnboardingLifecycle? {
        guard lifecycle.isValid, lifecycle.state == .pending else { return nil }
        if lifecycle.dismissCount == 1 {
            return OnboardingLifecycle(
                version: lifecycle.version,
                state: .retired,
                dismissCount: 2,
                snoozeUntil: nil
            )
        }
        return OnboardingLifecycle(
            version: lifecycle.version,
            state: .pending,
            dismissCount: lifecycle.dismissCount + 1,
            snoozeUntil: now.addingTimeInterval(86_400)
        )
    }
}

enum OnboardingIngredientMode: String, Codable, CaseIterable, Equatable {
    case avoid
    case allergy
}

enum OnboardingDraftError: Error, LocalizedError, Equatable {
    case householdSizeOutOfRange
    case invalidIngredient
    case invalidTimeZone

    var errorDescription: String? {
        switch self {
        case .householdSizeOutOfRange: "Household size must be between 1 and 12."
        case .invalidIngredient: "Ingredient choices must have an ID and name."
        case .invalidTimeZone: "The selected timezone is invalid."
        }
    }
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

    func normalized() throws -> Self {
        guard (1...12).contains(householdSize) else {
            throw OnboardingDraftError.householdSizeOutOfRange
        }
        let ingredients = try ingredientChoices.map { choice -> OnboardingIngredientChoice in
            let id = choice.baseIngredientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = choice.baseIngredientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else { throw OnboardingDraftError.invalidIngredient }
            switch choice.mode {
            case .avoid, .allergy: break
            }
            return OnboardingIngredientChoice(baseIngredientID: id, baseIngredientName: name, mode: choice.mode)
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw OnboardingDraftError.invalidTimeZone
        }
        return Self(
            householdSize: householdSize,
            ingredientChoices: ingredients,
            likedCuisines: OnboardingProfileValues.normalizeCuisines(likedCuisines),
            timeZoneIdentifier: timeZoneIdentifier
        )
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(normalized()), as: UTF8.self)
    }

    static func decode(_ value: String) throws -> Self {
        let draft = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        return try draft.normalized()
    }
}

enum OnboardingPresentationMode: String, Equatable {
    case automatic
    case manual
}

struct OnboardingPresentation: Identifiable, Equatable {
    let mode: OnboardingPresentationMode
    let draft: OnboardingDraft
    var id: String { mode.rawValue }
}

enum OwnerHouseholdResolutionOrigin: Equatable {
    case existing
    case minted
}
