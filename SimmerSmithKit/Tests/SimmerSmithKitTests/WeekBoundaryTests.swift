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

// MARK: - mondayStart (weeks run Monday–Sunday)

// Reference: 2026-06-22 is a Monday; 06-26 is Friday; 06-21 is Sunday; 06-29 is Monday.

@Test("mondayStart from a mid-week day returns that week's Monday")
func mondayStartMidWeek() {
    #expect(WeekBoundary.mondayStart(containing: utc(2026, 6, 26, 14)) == utc(2026, 6, 22))  // Fri → Mon 22
}

@Test("mondayStart from Monday returns the same Monday")
func mondayStartOnMonday() {
    #expect(WeekBoundary.mondayStart(containing: utc(2026, 6, 22)) == utc(2026, 6, 22))
    #expect(WeekBoundary.mondayStart(containing: utc(2026, 6, 29)) == utc(2026, 6, 29))
}

@Test("mondayStart from Sunday returns the PREVIOUS Monday (Sunday ends the week)")
func mondayStartOnSunday() {
    #expect(WeekBoundary.mondayStart(containing: utc(2026, 6, 21)) == utc(2026, 6, 15))  // Sun 21 → Mon 15
    #expect(WeekBoundary.mondayStart(containing: utc(2026, 6, 28)) == utc(2026, 6, 22))  // Sun 28 → Mon 22
}

@Test("mondayStart postcondition: the result always contains the day, and is a Monday")
func mondayStartInvariant() {
    for dayOffset in 0..<28 {
        let day = utc(2026, 6, 1).addingTimeInterval(Double(dayOffset) * 86_400)
        let start = WeekBoundary.mondayStart(containing: day)
        #expect(WeekBoundary.weekContains(start, day: day), "day \(day) → \(start)")
        #expect(WeekBoundary.isMonday(start), "start \(start) should be a Monday")
    }
}

@Test("isMonday")
func isMonday() {
    #expect(WeekBoundary.isMonday(utc(2026, 6, 22)))     // Monday
    #expect(WeekBoundary.isMonday(utc(2026, 6, 29)))     // Monday
    #expect(!WeekBoundary.isMonday(utc(2026, 6, 26)))    // Friday
    #expect(!WeekBoundary.isMonday(utc(2026, 6, 21)))    // Sunday
}

@Test("isSameUTCDay")
func isSameUTCDay() {
    #expect(WeekBoundary.isSameUTCDay(utc(2026, 6, 22), utc(2026, 6, 22, 18)))   // same day, diff hour
    #expect(!WeekBoundary.isSameUTCDay(utc(2026, 6, 22), utc(2026, 6, 23)))
}
