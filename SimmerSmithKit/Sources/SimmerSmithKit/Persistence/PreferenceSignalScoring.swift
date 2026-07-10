import Foundation

// bead simmersmith-b9z — feedback -> signal scoring. Implements the rule recorded in
// the ADR "feedback→signal scoring is deliberately simple and inspectable"
// (.docs/ai/decisions.md): a meal rating writes a signal for the recipe name AND
// (when known) the meal's cuisine, as separate signalTypes; score += sentiment,
// clamped to [scoreMin, scoreMax]; strongLikes = recipe signals >= strongLikeThreshold;
// likedCuisines = cuisine signals >= strongLikeThreshold; dislikedCuisines = cuisine
// signals <= dislikeThreshold.
//
// Kept dependency-free and pure (no SwiftData / CloudKit) so it's host-testable without
// a ModelContainer — a CloudKit-capable Schema traps in an unentitled `swift test`
// binary (see PrivatePlaneStoreTests.swift), so the accumulate/clamp/threshold math
// lives here instead of only inside the @Model-touching store path.

/// A flat, Codable projection of `PrivatePreferenceSignal` for consumption outside the
/// private-plane store — mirrors the role `IngredientPreference` plays for
/// `PrivateIngredientPreference`.
public struct PreferenceSignal: Codable, Hashable, Sendable {
    public let signalType: String
    public let name: String
    public let normalizedName: String
    public let score: Double
    public let active: Bool
    public let updatedAt: Date

    public init(
        signalType: String,
        name: String,
        normalizedName: String,
        score: Double,
        active: Bool,
        updatedAt: Date = .now
    ) {
        self.signalType = signalType
        self.name = name
        self.normalizedName = normalizedName
        self.score = score
        self.active = active
        self.updatedAt = updatedAt
    }
}

public enum PreferenceSignalScoring {
    /// `signalType` written for a rated recipe.
    public static let recipeSignalType = "recipe"
    /// `signalType` written for a rated meal's cuisine.
    public static let cuisineSignalType = "cuisine"

    /// Score accumulation bounds.
    public static let scoreMin: Double = -3
    public static let scoreMax: Double = 3

    /// A recipe/cuisine signal at or above this score counts as a strong like.
    public static let strongLikeThreshold: Double = 2
    /// A cuisine signal at or below this score counts as disliked.
    public static let dislikeThreshold: Double = -2

    /// The sentiment range `FeedbackComposerView`'s five-way picker actually emits:
    /// Avoid = -2 · Bad = -1 · Neutral = 0 · Good = +1 · Great = +2.
    public static let sentimentMin = -2
    public static let sentimentMax = 2

    /// Accumulate `sentiment` onto `currentScore`, clamped to `[scoreMin, scoreMax]`.
    ///
    /// `sentiment` is clamped to `[sentimentMin, sentimentMax]` first. Note that a single
    /// emphatic tap is *meant* to land on a threshold: `Great` (+2) reaches
    /// `strongLikeThreshold` and `Avoid` (-2) reaches `dislikeThreshold` in one go, while
    /// `Good`/`Bad` (±1) require repetition. The input clamp exists so no future caller can
    /// leapfrog further than the UI allows. See the "feedback→signal scoring" ADR in
    /// `.docs/ai/decisions.md` — its first draft wrongly claimed the picker emitted only ±1.
    public static func accumulate(currentScore: Double, sentiment: Int) -> Double {
        let bounded = min(sentimentMax, max(sentimentMin, sentiment))
        return min(scoreMax, max(scoreMin, currentScore + Double(bounded)))
    }

    /// Derive the planner-facing like/dislike lists from a flat signal list. Only
    /// `active` signals count; order follows input order (no additional sorting).
    public static func derive(
        signals: [PreferenceSignal]
    ) -> (strongLikes: [String], likedCuisines: [String], dislikedCuisines: [String]) {
        var strongLikes: [String] = []
        var likedCuisines: [String] = []
        var dislikedCuisines: [String] = []
        for signal in signals where signal.active {
            switch signal.signalType {
            case recipeSignalType:
                if signal.score >= strongLikeThreshold { strongLikes.append(signal.name) }
            case cuisineSignalType:
                if signal.score >= strongLikeThreshold {
                    likedCuisines.append(signal.name)
                } else if signal.score <= dislikeThreshold {
                    dislikedCuisines.append(signal.name)
                }
            default:
                break
            }
        }
        return (strongLikes, likedCuisines, dislikedCuisines)
    }
}
