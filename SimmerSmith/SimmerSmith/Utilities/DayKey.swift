import Foundation

/// Calendar-day helpers that match the server's semantics.
///
/// The SimmerSmith backend emits date fields (`week_start`, `meal_date`, etc.)
/// as "YYYY-MM-DD" calendar strings. The iOS JSON decoder parses those as
/// `Date` values at UTC midnight. Comparing those `Date`s with
/// `Calendar.current` in a non-UTC timezone shifts the wall-clock into the
/// previous (or next) calendar day and mis-attributes meals to the wrong day.
///
/// Use these helpers any time you need to ask "are these two server-supplied
/// dates the same calendar day?" or "is this server-supplied date 'today'?"
/// instead of reaching for `Calendar.current.isDate(_:inSameDayAs:)` or
/// `Calendar.current.isDateInToday(_:)`.
enum DayKey {
    /// "YYYY-MM-DD" string for a server-supplied `Date`, formatted in UTC.
    static func server(_ date: Date) -> String {
        serverFormatter.string(from: date)
    }

    /// "YYYY-MM-DD" string for a local `Date` (used for "now").
    static func local(_ date: Date) -> String {
        localFormatter.string(from: date)
    }

    /// True when a server-supplied `Date` represents today's local calendar day.
    static func isToday(_ date: Date) -> Bool {
        server(date) == local(Date())
    }

    /// True when two server-supplied `Date`s represent the same calendar day.
    static func isSameServerDay(_ a: Date, _ b: Date) -> Bool {
        server(a) == server(b)
    }

    /// Full weekday name ("Monday") for a server-supplied `Date`, in UTC.
    static func weekdayName(_ date: Date) -> String {
        weekdayFormatter.string(from: date)
    }

    /// Abbreviated month + day ("Apr 18") for a server-supplied `Date`, in UTC.
    static func shortMonthDay(_ date: Date) -> String {
        shortMonthDayFormatter.string(from: date)
    }

    /// Gregorian calendar pinned to UTC for iterating days without
    /// local-timezone drift.
    static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private static let serverFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEEE"
        return f
    }()

    private static let shortMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "MMM d"
        return f
    }()
}
