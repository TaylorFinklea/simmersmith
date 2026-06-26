import Foundation

/// Pure week-boundary math for the planner's 7-day weeks.
///
/// Weeks are anchored to a `weekStart` and span `[weekStart, weekStart+7)` at UTC-day
/// granularity. There is no absolute "first day of the week" — the 7-day phase is
/// whatever an existing week established (the Fly server worked the same way). When the
/// CloudKit store has to create today's week on-device, it steps from an existing week's
/// start so the new week lines up with imported/older weeks instead of drifting.
///
/// Mirrors the proven Fly advance logic (`advanceCurrentWeekToTodayIfStaleOrNil`). Pure
/// value math — no store, no I/O — so it unit-tests headlessly.
public enum WeekBoundary {

    /// UTC ISO-8601 calendar. Weeks are reasoned about in UTC days everywhere (matches
    /// `WeekRepository.utcDayKey`), so there is no DST/timezone drift in the stepping.
    public static var utcCalendar: Calendar {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }

    /// True iff `day` falls in `[weekStart, weekStart+7)` at UTC-day granularity.
    /// Both ends are normalized to UTC start-of-day, so a stored `weekStart` carrying a
    /// time-of-day (as some Fly payloads do) still matches correctly.
    public static func weekContains(_ weekStart: Date, day: Date) -> Bool {
        let cal = utcCalendar
        let start = cal.startOfDay(for: weekStart)
        guard let end = cal.date(byAdding: .day, value: 7, to: start) else { return false }
        let d = cal.startOfDay(for: day)
        return d >= start && d < end
    }

    /// The Monday (UTC midnight) that starts the calendar week containing `day`.
    ///
    /// SimmerSmith weeks run Monday–Sunday (household default `week_start_day = Monday`;
    /// the iOS create paths all snap to Monday — `firstWeekday = 2`). This mirrors the
    /// WeekView Monday math so an auto-created current week lines up with the day grid.
    ///
    /// Postcondition: `weekContains(mondayStart(containing: day), day: day) == true`.
    public static func mondayStart(containing day: Date) -> Date {
        let cal = utcCalendar
        let d = cal.startOfDay(for: day)
        // iso8601 `.weekday`: 1 = Sunday … 2 = Monday … 7 = Saturday.
        let weekday = cal.component(.weekday, from: d)
        let daysToMonday = (weekday == 1 ? -6 : 2 - weekday)
        return cal.date(byAdding: .day, value: daysToMonday, to: d) ?? d
    }

    /// True iff `date`'s UTC day is a Monday (a valid week start).
    public static func isMonday(_ date: Date) -> Bool {
        utcCalendar.component(.weekday, from: utcCalendar.startOfDay(for: date)) == 2
    }
}
