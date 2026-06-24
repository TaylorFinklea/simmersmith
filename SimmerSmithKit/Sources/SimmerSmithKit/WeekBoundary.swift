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

    /// The `weekStart` (UTC midnight) of the 7-day period containing `today`.
    ///
    /// With an `anchor` (an existing week's start) the result preserves that week's
    /// 7-day phase by stepping in 7-day increments toward today. With no anchor it is
    /// simply today's UTC day (the first week establishes the phase).
    ///
    /// Postcondition: `weekContains(currentWeekStart(today:anchor:), day: today) == true`.
    public static func currentWeekStart(today: Date, anchor: Date?) -> Date {
        let cal = utcCalendar
        let todayUTC = cal.startOfDay(for: today)
        guard let anchor else { return todayUTC }
        var target = cal.startOfDay(for: anchor)

        if let endExclusive = cal.date(byAdding: .day, value: 7, to: target), todayUTC >= endExclusive {
            // Anchor's week ended before today → step forward to today's period.
            for _ in 0..<520 {
                guard let next = cal.date(byAdding: .day, value: 7, to: target) else { break }
                if todayUTC < next { break }
                target = next
            }
        } else if todayUTC < target {
            // Anchor is in the future → step back to today's period.
            for _ in 0..<520 {
                guard let prev = cal.date(byAdding: .day, value: -7, to: target) else { break }
                target = prev
                if todayUTC >= target { break }
            }
        }
        return target
    }
}
