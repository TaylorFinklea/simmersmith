import Foundation
import Testing

@testable import SimmerSmith

@Suite(.serialized)
struct OnboardingPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func pendingWithoutSnoozePresents() {
        #expect(OnboardingPolicy.automaticDecision(
            for: .pending,
            now: now
        ) == .present)
    }

    @Test func futureSnoozeWaitsAndDueSnoozePresents() {
        let lifecycle = OnboardingLifecycle(
            version: 1,
            state: .pending,
            dismissCount: 1,
            snoozeUntil: now.addingTimeInterval(86_400)
        )
        #expect(OnboardingPolicy.automaticDecision(for: lifecycle, now: now) == .wait)
        #expect(OnboardingPolicy.automaticDecision(
            for: lifecycle,
            now: now.addingTimeInterval(86_400)
        ) == .present)
    }

    @Test func completedAndRetiredDoNotPresent() {
        let completed = OnboardingLifecycle(
            version: 1,
            state: .completed,
            dismissCount: 0,
            snoozeUntil: nil
        )
        let retired = OnboardingLifecycle(
            version: 1,
            state: .retired,
            dismissCount: 2,
            snoozeUntil: nil
        )
        #expect(OnboardingPolicy.automaticDecision(for: completed, now: now) == .none)
        #expect(OnboardingPolicy.automaticDecision(for: retired, now: now) == .none)
    }

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

    @Test func malformedAndAbsentSettingsFailClosed() {
        #expect(OnboardingLifecycle(settings: [:]) == nil)
        #expect(OnboardingLifecycle(settings: [
            OnboardingSettings.version: "1",
            OnboardingSettings.state: "surprise",
        ]) == nil)
        #expect(OnboardingLifecycle(settings: [
            OnboardingSettings.version: "1",
            OnboardingSettings.state: OnboardingLifecycleState.pending.rawValue,
            OnboardingSettings.dismissCount: "-1",
        ]) == nil)
        #expect(OnboardingLifecycle(settings: [
            OnboardingSettings.version: "1",
            OnboardingSettings.state: OnboardingLifecycleState.pending.rawValue,
            OnboardingSettings.dismissCount: "2",
        ]) == nil)
        #expect(OnboardingLifecycle(settings: [
            OnboardingSettings.version: "1",
            OnboardingSettings.state: OnboardingLifecycleState.pending.rawValue,
            OnboardingSettings.dismissCount: String(Int.max),
        ]) == nil)
    }

    @Test func fractionalSnoozeRoundTripsWithoutEarlyPresentation() throws {
        let fractionalNow = Date(timeIntervalSince1970: 2_000_000_000.123456)
        let update = try #require(OnboardingPolicy.dismissalUpdate(
            lifecycle: .pending,
            now: fractionalNow
        ))
        let restored = try #require(OnboardingLifecycle(settings: update.settingValues))
        #expect(restored.snoozeUntil == update.snoozeUntil)
        #expect(OnboardingPolicy.automaticDecision(
            for: restored,
            now: update.snoozeUntil!.addingTimeInterval(-0.000001)
        ) == .wait)
    }

    @Test func profileValuesNormalizeAndFailClosed() {
        #expect(OnboardingProfileValues.householdSize(from: [
            OnboardingSettings.householdSize: "9",
        ]) == 9)
        #expect(OnboardingProfileValues.householdSize(from: [
            OnboardingSettings.householdSize: "13",
        ]) == 4)
        #expect(OnboardingProfileValues.likedCuisines(from: [
            OnboardingSettings.likedCuisines: "[\" Italian \",\"italian\",\"Thai\"]",
        ]) == ["Italian", "Thai"])
        #expect(OnboardingProfileValues.likedCuisines(from: [
            OnboardingSettings.likedCuisines: "not-json",
        ]) == [])
    }

    @Test func draftNormalizesAndValidates() throws {
        let draft = OnboardingDraft(
            householdSize: 3,
            ingredientChoices: [OnboardingIngredientChoice(
                baseIngredientID: "  garlic ",
                baseIngredientName: " Garlic ",
                mode: .avoid
            )],
            likedCuisines: [" Italian ", "italian", "Thai"],
            timeZoneIdentifier: "America/Chicago"
        )
        let normalized = try draft.normalized()
        #expect(normalized.ingredientChoices[0].baseIngredientID == "garlic")
        #expect(normalized.ingredientChoices[0].baseIngredientName == "Garlic")
        #expect(normalized.likedCuisines == ["Italian", "Thai"])
        #expect(try OnboardingDraft.decode(try draft.encoded()) == normalized)
        #expect(throws: OnboardingDraftError.householdSizeOutOfRange) {
            try OnboardingDraft(householdSize: 0, ingredientChoices: [], likedCuisines: [], timeZoneIdentifier: "UTC").normalized()
        }
        #expect(throws: OnboardingDraftError.invalidIngredient) {
            try OnboardingDraft(householdSize: 1, ingredientChoices: [OnboardingIngredientChoice(baseIngredientID: " ", baseIngredientName: "Salt", mode: .avoid)], likedCuisines: [], timeZoneIdentifier: "UTC").normalized()
        }
        #expect(throws: OnboardingDraftError.invalidTimeZone) {
            try OnboardingDraft(householdSize: 1, ingredientChoices: [], likedCuisines: [], timeZoneIdentifier: "Not/AZone").normalized()
        }
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
