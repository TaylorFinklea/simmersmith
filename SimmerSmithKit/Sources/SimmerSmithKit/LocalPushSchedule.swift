import Foundation

// simmersmith-990.6 — LocalPushSchedule: pure "should we fire, and with what copy"
// decision for the two on-device reminders that replace the retired Fly APScheduler
// (M18, decisions.md 2026-04-30): "tonight's meal" and "Saturday plan reminder". No
// CloudKit, no UNUserNotificationCenter, no I/O — the caller (AppState+Push.swift)
// resolves the week + clock inputs (from `currentWeek` / `weekRepository`) and applies
// the result via LocalNotificationService. Host-testable by design.
//
// Reproduces the Fly scheduler's rules (`app/services/push_scheduler.py`), not its
// mechanism: no server tick, no per-user profile_settings row, no APNs. Each rule below
// cites the server behavior it mirrors.
public enum LocalPushSchedule {

    /// One resolved reminder: an absolute local fire date + the copy to show.
    public struct Reminder: Equatable, Sendable {
        public let fireDate: Date
        public let title: String
        public let body: String

        public init(fireDate: Date, title: String, body: String) {
            self.fireDate = fireDate
            self.title = title
            self.body = body
        }
    }

    /// Inputs needed to decide both reminders in one pass.
    public struct Input {
        /// Current wall-clock time. Only used to resolve "today" (for the tonight's-meal
        /// fire date) and "is today Friday" (for the Saturday-plan gate) — NOT compared
        /// against quiet hours (see `isQuietHour`, which checks the chosen delivery hour).
        public let now: Date
        /// Calendar to resolve day-of-week / hour-minute components against. Pass one
        /// with the user's local time zone (the call site defaults to `.current`).
        public let calendar: Calendar

        public let tonightMealEnabled: Bool
        public let saturdayPlanEnabled: Bool

        /// Parsed "HH:mm" hour/minute for each reminder's chosen local delivery time.
        public let tonightMealHour: Int
        public let tonightMealMinute: Int
        public let saturdayPlanHour: Int
        public let saturdayPlanMinute: Int

        /// Tonight's dinner-slot recipe name, or nil when no dinner meal is planned for
        /// today (mirrors `_process_tonights_meal`'s "no dinner meal" skip).
        public let tonightDinnerRecipeName: String?

        /// `status` of the week starting next Monday, or nil when that week doesn't
        /// exist yet in the store (mirrors `_process_saturday_plan`: an absent row is
        /// treated the same as "still needs planning", i.e. it still fires).
        public let nextWeekStatus: String?

        public init(
            now: Date,
            calendar: Calendar = .current,
            tonightMealEnabled: Bool,
            saturdayPlanEnabled: Bool,
            tonightMealHour: Int,
            tonightMealMinute: Int,
            saturdayPlanHour: Int,
            saturdayPlanMinute: Int,
            tonightDinnerRecipeName: String?,
            nextWeekStatus: String?
        ) {
            self.now = now
            self.calendar = calendar
            self.tonightMealEnabled = tonightMealEnabled
            self.saturdayPlanEnabled = saturdayPlanEnabled
            self.tonightMealHour = tonightMealHour
            self.tonightMealMinute = tonightMealMinute
            self.saturdayPlanHour = saturdayPlanHour
            self.saturdayPlanMinute = saturdayPlanMinute
            self.tonightDinnerRecipeName = tonightDinnerRecipeName
            self.nextWeekStatus = nextWeekStatus
        }
    }

    /// Both reminders' decisions for this pass. `nil` means "don't schedule one for
    /// this kind" — the caller is expected to cancel any previously-scheduled pending
    /// request for that kind when its slot comes back nil (toggle turned off, week
    /// approved, etc.).
    public struct Result: Equatable {
        public let tonightMeal: Reminder?
        public let saturdayPlan: Reminder?
    }

    /// Week statuses that mean "still needs planning". Covers both the legacy Fly
    /// scheduler's `"draft"` and the CloudKit `WeekRepository.createWeek` default of
    /// `"staging"`, so this keeps matching across the schema rename.
    static let unplannedStatuses: Set<String> = ["staging", "draft"]

    /// `Calendar.component(.weekday:)` value for Friday (1 = Sunday … 7 = Saturday,
    /// stable across calendar identifiers — matches `WeekBoundary`'s convention).
    static let fridayWeekday = 6

    /// Hard-rule quiet hours — never deliver between 22:00 and 07:00 local, regardless
    /// of toggle state. Mirrors `_is_quiet_hours` for the case that matters here: since
    /// the on-device trigger only fires at the user's CHOSEN hour (there is no 5-minute
    /// server tick to catch), checking the chosen hour is equivalent to the server's
    /// "now is within the quiet window" check.
    public static func isQuietHour(_ hour: Int) -> Bool {
        hour >= 22 || hour < 7
    }

    /// Decide both reminders for this pass.
    public static func decide(_ input: Input) -> Result {
        Result(
            tonightMeal: decideTonightMeal(input),
            saturdayPlan: decideSaturdayPlan(input)
        )
    }

    // MARK: - Tonight's meal

    private static func decideTonightMeal(_ input: Input) -> Reminder? {
        guard input.tonightMealEnabled else { return nil }
        guard let recipeName = input.tonightDinnerRecipeName, !recipeName.isEmpty else { return nil }
        guard !isQuietHour(input.tonightMealHour) else { return nil }
        guard let fireDate = todayAt(hour: input.tonightMealHour, minute: input.tonightMealMinute, input: input),
              fireDate > input.now
        else { return nil }
        return Reminder(fireDate: fireDate, title: "Tonight's meal", body: "Tonight: \(recipeName)")
    }

    // MARK: - Saturday plan reminder

    private static func decideSaturdayPlan(_ input: Input) -> Reminder? {
        guard input.saturdayPlanEnabled else { return nil }
        // Fly-parity: only fires when evaluated ON Friday (`now.weekday() != 4: return`
        // in `_process_saturday_plan`) — a reschedule pass on any other day of the week
        // arms nothing for this kind.
        guard input.calendar.component(.weekday, from: input.now) == fridayWeekday else { return nil }
        guard !isQuietHour(input.saturdayPlanHour) else { return nil }
        if let status = input.nextWeekStatus, !unplannedStatuses.contains(status) { return nil }
        guard let fireDate = todayAt(hour: input.saturdayPlanHour, minute: input.saturdayPlanMinute, input: input),
              fireDate > input.now
        else { return nil }
        return Reminder(
            fireDate: fireDate,
            title: "Plan your week",
            body: "Your upcoming week is still open — plan it now."
        )
    }

    // MARK: - Helpers

    /// `input.now`'s calendar day at `hour:minute:00`, or nil if the calendar can't
    /// represent it (should not happen for valid 0-23 / 0-59 inputs).
    private static func todayAt(hour: Int, minute: Int, input: Input) -> Date? {
        input.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: input.now)
    }
}
