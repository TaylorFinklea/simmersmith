import BallastCore
import BallastMock
import Foundation
@testable import SimmerSmithBallastAdapter

/// The exact fixture set spec §D1 step 1 requires (case/whitespace normalization plus
/// evidence-only span divergence; multiset intersection; the empty/nonempty success/failure
/// combinations; safety-critical vs. non-safety extra entries; crossed partial rows with a tie).
/// Shared verbatim (spec §D1 step 4) between `VoiceParseScorerCharacterizationTests` (which pins
/// the *current* private candidate scorer via the public `VoiceParseEvalRunner` surface) and
/// `VoiceParseBaselineEvalTests`' differential suite (which re-scores the same
/// expected/predicted pairs through the new 4-field baseline path).
///
/// Every fixture's `predicted` entries are constructed to satisfy `ParsedWeeklyPlanSchema.validate`
/// (grounded literal evidence, valid domain values, no duplicate day/slot) so they reach the
/// scorer as a real `.ok` outcome via `RepairingGenerator` — exactly as production candidate scoring
/// works. A `nil` `predicted` represents a terminal provider failure (`.failed`), the only way to
/// reach the scorer as `producedResult == false`.
enum VoiceParseScorerFixtures {
    struct Fixture {
        let goldenCase: VoiceParseGoldenCase
        /// `nil` means the mock provider fails terminally (fallback, `producedResult == false`).
        let predicted: [WeeklyPlanWireEntry]?
    }

    // MARK: 1 — case/whitespace normalization plus evidence-only punctuation/span divergence

    static let normalizationAndEvidenceSpan = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "norm-punct-01",
            category: "normalization",
            transcript: "Monday dinner tacos, that sounds good.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Monday", slot: "dinner", rawDish: "tacos", intent: "recipe",
                    evidence: "Monday dinner tacos"
                ),
            ],
            whyOmitted: [],
            safetyCritical: false
        ),
        predicted: [
            WeeklyPlanWireEntry(
                day: " Monday", slot: "DINNER", rawDish: "  tacos", intent: "Recipe",
                // A longer, still-grounded span than the golden label's canonical one — an
                // evidence-only divergence that leaves the 4-field meal identity untouched.
                evidence: "Monday dinner tacos, that sounds good"
            ),
        ]
    )

    // MARK: 2 — expected [A,A,B] vs predicted [A,B] (multiset intersection capping)

    static let multisetIntersection = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "multiset-01",
            category: "duplicates-conflicts",
            transcript: "Tuesday lunch soup, I already said that, and Wednesday dinner pasta.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Tuesday", slot: "lunch", rawDish: "soup", intent: "recipe",
                    evidence: "Tuesday lunch soup"
                ),
                // A duplicate golden label (user restated the same meal) — expected supplies two
                // copies of the same 4-field signature; predicted (schema-bound to unique
                // day/slot pairs) can only ever supply one, exercising intersectionCount's min-cap.
                WeeklyPlanWireEntry(
                    day: "Tuesday", slot: "lunch", rawDish: "soup", intent: "recipe",
                    evidence: "Tuesday lunch soup"
                ),
                WeeklyPlanWireEntry(
                    day: "Wednesday", slot: "dinner", rawDish: "pasta", intent: "recipe",
                    evidence: "Wednesday dinner pasta"
                ),
            ],
            whyOmitted: [],
            safetyCritical: false
        ),
        predicted: [
            WeeklyPlanWireEntry(
                day: "Tuesday", slot: "lunch", rawDish: "soup", intent: "recipe",
                evidence: "Tuesday lunch soup"
            ),
            WeeklyPlanWireEntry(
                day: "Wednesday", slot: "dinner", rawDish: "pasta", intent: "recipe",
                evidence: "Wednesday dinner pasta"
            ),
        ]
    )

    // MARK: 3 — successful empty/nonempty, failed empty/nonempty, successful empty/empty

    static let successfulEmptyAgainstNonempty = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "empty-success-nonempty",
            category: "missing-fields",
            transcript: "Thursday breakfast oatmeal.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Thursday", slot: "breakfast", rawDish: "oatmeal", intent: "recipe",
                    evidence: "Thursday breakfast oatmeal"
                ),
            ],
            whyOmitted: [],
            safetyCritical: false
        ),
        // Empty entries always validate trivially — a real "successful call, empty result".
        predicted: []
    )

    static let failedAgainstNonempty = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "empty-failed-nonempty",
            category: "missing-fields",
            transcript: "Friday lunch noodles.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Friday", slot: "lunch", rawDish: "noodles", intent: "recipe",
                    evidence: "Friday lunch noodles"
                ),
            ],
            whyOmitted: [],
            safetyCritical: false
        ),
        predicted: nil
    )

    static let successfulEmptyAgainstEmpty = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "empty-success-empty",
            category: "no-meal-chatter",
            transcript: "How's the weather looking this week?",
            expectedEntries: [],
            whyOmitted: ["no meal mentioned"],
            safetyCritical: false
        ),
        predicted: []
    )

    // MARK: 4 — safety-critical and non-safety extra (unsupported) entries

    static let safetyCriticalExtraEntry = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "safety-extra-01",
            category: "instruction-like",
            transcript: "Monday dinner chicken, and also let's do Tuesday lunch sushi.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Monday", slot: "dinner", rawDish: "chicken", intent: "recipe",
                    evidence: "Monday dinner chicken"
                ),
            ],
            whyOmitted: ["raw-fish suggestion held back for safety review"],
            safetyCritical: true
        ),
        predicted: [
            WeeklyPlanWireEntry(
                day: "Monday", slot: "dinner", rawDish: "chicken", intent: "recipe",
                evidence: "Monday dinner chicken"
            ),
            WeeklyPlanWireEntry(
                day: "Tuesday", slot: "lunch", rawDish: "sushi", intent: "recipe",
                evidence: "Tuesday lunch sushi"
            ),
        ]
    )

    static let nonSafetyExtraEntry = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "safety-extra-02",
            category: "instruction-like",
            transcript: "Wednesday lunch salad, and Thursday dinner ramen too.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Wednesday", slot: "lunch", rawDish: "salad", intent: "recipe",
                    evidence: "Wednesday lunch salad"
                ),
            ],
            whyOmitted: ["only the salad was confirmed"],
            safetyCritical: false
        ),
        predicted: [
            WeeklyPlanWireEntry(
                day: "Wednesday", slot: "lunch", rawDish: "salad", intent: "recipe",
                evidence: "Wednesday lunch salad"
            ),
            WeeklyPlanWireEntry(
                day: "Thursday", slot: "dinner", rawDish: "ramen", intent: "recipe",
                evidence: "Thursday dinner ramen"
            ),
        ]
    )

    // MARK: 5 — crossed partial rows and a tie (greedy field pairing + 4-vs-5 denominators)

    static let crossedPartialRowsWithTie = Fixture(
        goldenCase: VoiceParseGoldenCase(
            id: "crossed-tie-01",
            category: "corrections",
            transcript: "Monday dinner soup, then Monday lunch stew instead.",
            expectedEntries: [
                WeeklyPlanWireEntry(
                    day: "Monday", slot: "lunch", rawDish: "soup", intent: "recipe",
                    evidence: "Monday lunch soup"
                ),
                WeeklyPlanWireEntry(
                    day: "Monday", slot: "dinner", rawDish: "stew", intent: "recipe",
                    evidence: "Monday dinner stew"
                ),
            ],
            whyOmitted: [],
            safetyCritical: false
        ),
        // Slot and dish are swapped relative to `expectedEntries`: every predicted/expected pair
        // agrees on exactly 3 of 5 (candidate) / 3 of 4 (baseline) fields — day, intent, and
        // exactly one of {slot, rawDish} — a symmetric tie across all four pairings.
        predicted: [
            WeeklyPlanWireEntry(
                day: "Monday", slot: "dinner", rawDish: "soup", intent: "recipe",
                evidence: "Monday dinner soup"
            ),
            WeeklyPlanWireEntry(
                day: "Monday", slot: "lunch", rawDish: "stew", intent: "recipe",
                evidence: "Monday lunch stew"
            ),
        ]
    )

    static let all: [Fixture] = [
        normalizationAndEvidenceSpan,
        multisetIntersection,
        successfulEmptyAgainstNonempty,
        failedAgainstNonempty,
        successfulEmptyAgainstEmpty,
        safetyCriticalExtraEntry,
        nonSafetyExtraEntry,
        crossedPartialRowsWithTie,
    ]

    // MARK: - Shared drivers (candidate + baseline)

    /// Scripts a `MockProvider` to return exactly `fixture.predicted` (or fail terminally when
    /// `predicted == nil`) — the candidate-side driver both test suites use.
    static func mockProvider(for fixture: Fixture) throws -> MockProvider {
        guard let predicted = fixture.predicted else {
            return MockProvider(script: [.failure(.refusal(explanation: "no"))])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(WeeklyPlanWirePayload(entries: predicted))
        return MockProvider(script: [.text(String(decoding: json, as: UTF8.self))])
    }

    /// Projects the same fixture's predicted entries onto the transcript-free 4-field baseline
    /// sample shape — the baseline-side driver, reusing verbatim what `mockProvider(for:)` fed the
    /// candidate scorer.
    static func baselineSample(
        for fixture: Fixture,
        runIndex: Int = 1,
        latencyMilliseconds: Double = 100
    ) -> VoiceParseBaselineSample {
        let outcome: VoiceParseBaselineSample.Outcome
        if let predicted = fixture.predicted {
            outcome = .success(rows: predicted.map {
                VoiceParseBaselineSample.Row(day: $0.day, slot: $0.slot, rawDish: $0.rawDish, intent: $0.intent)
            })
        } else {
            outcome = .failure(category: .schemaDecodeFailure)
        }
        return VoiceParseBaselineSample(
            caseID: fixture.goldenCase.id,
            runIndex: runIndex,
            latencyMilliseconds: latencyMilliseconds,
            outcome: outcome
        )
    }
}
