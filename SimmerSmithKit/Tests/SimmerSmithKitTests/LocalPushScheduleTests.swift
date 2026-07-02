import Testing
import Foundation
@testable import SimmerSmithKit

// simmersmith-990.6 — LocalPushSchedule: pure decision logic for the on-device
// replacements of the Fly push scheduler's "tonight's meal" + "Saturday plan" pushes.

private let testCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/Chicago")!
    return c
}()

/// Build a local wall-clock `Date` in `testCalendar`'s time zone.
private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    testCalendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

/// Default input: both toggles on, default times (17:00 / 18:00), a dinner meal
/// tonight, and a next-week status that still needs planning. Individual tests
/// override just the field(s) under test.
private func makeInput(
    now: Date,
    tonightMealEnabled: Bool = true,
    saturdayPlanEnabled: Bool = true,
    tonightMealHour: Int = 17,
    tonightMealMinute: Int = 0,
    saturdayPlanHour: Int = 18,
    saturdayPlanMinute: Int = 0,
    tonightDinnerRecipeName: String? = "Chicken Tikka Masala",
    nextWeekStatus: String? = "staging"
) -> LocalPushSchedule.Input {
    LocalPushSchedule.Input(
        now: now,
        calendar: testCalendar,
        tonightMealEnabled: tonightMealEnabled,
        saturdayPlanEnabled: saturdayPlanEnabled,
        tonightMealHour: tonightMealHour,
        tonightMealMinute: tonightMealMinute,
        saturdayPlanHour: saturdayPlanHour,
        saturdayPlanMinute: saturdayPlanMinute,
        tonightDinnerRecipeName: tonightDinnerRecipeName,
        nextWeekStatus: nextWeekStatus
    )
}

// Reference: 2026-06-26 is a Friday; 2026-06-24 is a Wednesday.

// MARK: - Tonight's meal

@Test("tonight-has-meal: fires at the chosen time with the recipe name in the body")
func tonightHasMeal() {
    let now = local(2026, 6, 24, 9, 0)   // Wed 09:00 — well before the 17:00 target
    let result = LocalPushSchedule.decide(makeInput(now: now))
    #expect(result.tonightMeal?.title == "Tonight's meal")
    #expect(result.tonightMeal?.body == "Tonight: Chicken Tikka Masala")
    #expect(result.tonightMeal?.fireDate == local(2026, 6, 24, 17, 0))
}

@Test("tonight-empty: no dinner meal planned today — does not fire")
func tonightEmpty() {
    let now = local(2026, 6, 24, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, tonightDinnerRecipeName: nil))
    #expect(result.tonightMeal == nil)
}

@Test("tonight: already-passed delivery time today does not fire (no retroactive delivery)")
func tonightAlreadyPassed() {
    let now = local(2026, 6, 24, 20, 0)   // 20:00, after the default 17:00 target
    let result = LocalPushSchedule.decide(makeInput(now: now))
    #expect(result.tonightMeal == nil)
}

// MARK: - Saturday plan reminder

@Test("Friday-next-week-draft: fires when next week still needs planning")
func fridayNextWeekDraft() {
    let now = local(2026, 6, 26, 9, 0)   // Friday
    let result = LocalPushSchedule.decide(makeInput(now: now, nextWeekStatus: "staging"))
    #expect(result.saturdayPlan?.title == "Plan your week")
    #expect(result.saturdayPlan?.fireDate == local(2026, 6, 26, 18, 0))
}

@Test("Friday-next-week-draft: legacy 'draft' status (pre-CloudKit spelling) also fires")
func fridayNextWeekLegacyDraftSpelling() {
    let now = local(2026, 6, 26, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, nextWeekStatus: "draft"))
    #expect(result.saturdayPlan != nil)
}

@Test("Friday-next-week-draft: no row yet for next week still fires (needs planning)")
func fridayNextWeekMissing() {
    let now = local(2026, 6, 26, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, nextWeekStatus: nil))
    #expect(result.saturdayPlan != nil)
}

@Test("Friday-next-week-approved: does not fire once the upcoming week is approved")
func fridayNextWeekApproved() {
    let now = local(2026, 6, 26, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, nextWeekStatus: "approved"))
    #expect(result.saturdayPlan == nil)
}

@Test("Saturday plan only evaluates on Friday — a non-Friday reschedule pass arms nothing")
func nonFridayDoesNotArmSaturdayPlan() {
    let now = local(2026, 6, 24, 9, 0)   // Wednesday
    let result = LocalPushSchedule.decide(makeInput(now: now, nextWeekStatus: "staging"))
    #expect(result.saturdayPlan == nil)
}

// MARK: - Quiet hours (hard rule, independent of toggle)

@Test("quiet-hours: a chosen time inside 22:00-07:00 never fires, tonight's meal")
func quietHoursSuppressesTonightMeal() {
    let now = local(2026, 6, 24, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, tonightMealHour: 23, tonightMealMinute: 0))
    #expect(result.tonightMeal == nil)
}

@Test("quiet-hours: a chosen time inside 22:00-07:00 never fires, Saturday plan")
func quietHoursSuppressesSaturdayPlan() {
    let now = local(2026, 6, 26, 9, 0)   // Friday
    let result = LocalPushSchedule.decide(makeInput(now: now, saturdayPlanHour: 6, saturdayPlanMinute: 30))
    #expect(result.saturdayPlan == nil)
}

@Test("quiet-hours boundary: 07:00 is NOT quiet, 06:59 is")
func quietHoursBoundary() {
    #expect(!LocalPushSchedule.isQuietHour(7))
    #expect(LocalPushSchedule.isQuietHour(6))
    #expect(LocalPushSchedule.isQuietHour(22))
    #expect(!LocalPushSchedule.isQuietHour(21))
}

// MARK: - Toggle off

@Test("toggle-off: tonight's meal disabled does not fire even with a meal planned")
func toggleOffTonightMeal() {
    let now = local(2026, 6, 24, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, tonightMealEnabled: false))
    #expect(result.tonightMeal == nil)
}

@Test("toggle-off: Saturday plan disabled does not fire even on Friday with a draft week")
func toggleOffSaturdayPlan() {
    let now = local(2026, 6, 26, 9, 0)
    let result = LocalPushSchedule.decide(makeInput(now: now, saturdayPlanEnabled: false))
    #expect(result.saturdayPlan == nil)
}

// MARK: - Both decided independently in one pass

@Test("decide resolves both reminders independently in a single pass")
func decidesBothIndependently() {
    let now = local(2026, 6, 26, 9, 0)   // Friday, so both rules are in play
    let result = LocalPushSchedule.decide(makeInput(now: now))
    #expect(result.tonightMeal != nil)
    #expect(result.saturdayPlan != nil)
}
