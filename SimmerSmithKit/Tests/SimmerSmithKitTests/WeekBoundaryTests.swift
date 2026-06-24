import Testing
import Foundation
@testable import SimmerSmithKit

// SP-C — WeekBoundary: pure UTC week-boundary math for the CloudKit-owned current week.

private func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
    var c = Calendar(identifier: .iso8601)
    c.timeZone = TimeZone(secondsFromGMT: 0)!
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

// MARK: - weekContains

@Test("weekContains: start is inclusive, start+7 is exclusive")
func weekContainsRange() {
    let start = utc(2026, 6, 21)
    #expect(WeekBoundary.weekContains(start, day: utc(2026, 6, 21)))   // first day
    #expect(WeekBoundary.weekContains(start, day: utc(2026, 6, 24)))   // mid
    #expect(WeekBoundary.weekContains(start, day: utc(2026, 6, 27)))   // last day
    #expect(!WeekBoundary.weekContains(start, day: utc(2026, 6, 28)))  // start+7 excluded
    #expect(!WeekBoundary.weekContains(start, day: utc(2026, 6, 20)))  // before
}

@Test("weekContains normalizes a weekStart that carries a time-of-day")
func weekContainsIgnoresTimeOfDay() {
    let start = utc(2026, 6, 21, 5)   // 05:00 UTC
    #expect(WeekBoundary.weekContains(start, day: utc(2026, 6, 21)))
    #expect(WeekBoundary.weekContains(start, day: utc(2026, 6, 27, 23)))
    #expect(!WeekBoundary.weekContains(start, day: utc(2026, 6, 28)))
}

// MARK: - currentWeekStart

@Test("currentWeekStart with no anchor is today's UTC day")
func currentWeekStartNoAnchor() {
    let today = utc(2026, 6, 24, 14)
    #expect(WeekBoundary.currentWeekStart(today: today, anchor: nil) == utc(2026, 6, 24))
}

@Test("currentWeekStart steps forward from a past anchor, preserving phase")
func currentWeekStartPastAnchor() {
    // anchor two+ weeks back; phase 06-07,06-14,06-21,06-28…
    let target = WeekBoundary.currentWeekStart(today: utc(2026, 6, 24), anchor: utc(2026, 6, 7))
    #expect(target == utc(2026, 6, 21))
    #expect(WeekBoundary.weekContains(target, day: utc(2026, 6, 24)))
}

@Test("currentWeekStart steps back from a future anchor, preserving phase")
func currentWeekStartFutureAnchor() {
    // anchor in the future on the same phase → lands on the same 06-21 week.
    let target = WeekBoundary.currentWeekStart(today: utc(2026, 6, 24), anchor: utc(2026, 7, 5))
    #expect(target == utc(2026, 6, 21))
    #expect(WeekBoundary.weekContains(target, day: utc(2026, 6, 24)))
}

@Test("currentWeekStart returns the anchor's own period when it already covers today")
func currentWeekStartAnchorCoversToday() {
    let target = WeekBoundary.currentWeekStart(today: utc(2026, 6, 24), anchor: utc(2026, 6, 22))
    #expect(target == utc(2026, 6, 22))
    #expect(WeekBoundary.weekContains(target, day: utc(2026, 6, 24)))
}

@Test("currentWeekStart postcondition: the result always contains today, for many anchors")
func currentWeekStartContainsTodayInvariant() {
    let today = utc(2026, 6, 24)
    // Sweep anchors across many weeks on a fixed phase, plus off-phase anchors.
    for deltaWeeks in -8...8 {
        let anchor = utc(2026, 6, 21).addingTimeInterval(Double(deltaWeeks) * 7 * 86_400)
        let target = WeekBoundary.currentWeekStart(today: today, anchor: anchor)
        #expect(WeekBoundary.weekContains(target, day: today), "anchor \(anchor) → \(target)")
    }
    // Off-phase anchors (e.g. a Wednesday-started week) still produce a covering week.
    for offset in [-3, -1, 1, 3] {
        let anchor = utc(2026, 6, 21).addingTimeInterval(Double(offset) * 86_400)
        let target = WeekBoundary.currentWeekStart(today: today, anchor: anchor)
        #expect(WeekBoundary.weekContains(target, day: today), "off-phase anchor \(anchor) → \(target)")
    }
}
