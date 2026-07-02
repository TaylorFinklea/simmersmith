import Foundation
import UserNotifications
import SimmerSmithKit

// simmersmith-990.6 — port push notifications off the retired Fly APScheduler
// (M18, app/services/push_scheduler.py) onto on-device local notifications.
//
// WHY: the Fly scheduler ticked every 5 minutes, read `profile_settings` rows over
// HTTP, and sent APNs pushes to a device registered via `POST /api/push/devices`.
// Every read/write in that path (`savePushPreference` → `apiClient.updateProfile`,
// `PushService` → `apiClient.registerPushDevice`) sat behind `hasSavedConnection`,
// which is false for every CloudKit-era user (SP-C pivot) — so this whole feature
// was silently dead. It's reimplemented here as two on-device reminders, scheduled
// from `currentWeek` / `weekRepository` (already kept live by the CloudKit session,
// independent of `hasSavedConnection`) via the pure decision function
// `LocalPushSchedule` (SimmerSmithKit) + `LocalNotificationService`.
//
// STORAGE: preferences (toggle + delivery time) move from the Fly `profile_settings`
// table to local `UserDefaults`. There is no longer a server that needs to know
// these values (the scheduler is gone), and `ProfileRepository` — the CloudKit-era
// non-AI settings store — only accepts its own fixed `nonAIKeys` allowlist
// (image_provider / unit_system / user_region / auto_grocery_from_meals), which is
// owned by a different work lane. Per-device local prefs are also arguably a better
// fit here: these reminders fire locally on whichever device the user is holding,
// so there's no cross-device sync requirement the way there was for a server-side
// schedule. `key` params below still use the same `push_*` strings SettingsView
// passes in (unchanged call sites) — they're just namespaced into a UserDefaults key.
//
// KNOWN GAP (flag for the integration pass, out of this lane's owned files):
// `rescheduleLocalNotifications()` only runs from three call sites in THIS file —
// `savePushPreference` / `savePushTime` (user edits a toggle or time in Settings) and
// `refreshPushAuthorizationStatus` (fires on `SettingsView`'s Notifications section
// `.onAppear`). None of these is an unconditional daily/foreground hook, so a
// reminder scheduled today can go stale if the app isn't reopened before the next
// day (tonight's meal) or Friday (Saturday plan). `ensurePushBootstrap()` below would
// be that hook, but its only call site (`AppState.swift` inside `refreshAll()`) is
// gated by `hasSavedConnection` — false for CloudKit-only users, same root cause as
// the rest of this bug. Fixing that gate, or adding an unconditional call to
// `ensurePushBootstrap()` (e.g. from `wireHouseholdRepositories()` or the app's
// `scenePhase == .active` handler), is outside this lane's owned files
// (AppState.swift / AppState+Recipes.swift / SimmerSmithApp.swift) — left for the
// orchestrator's integration pass.

extension AppState {
    // MARK: - Draft state (local UserDefaults, per-device)

    /// Whether "Tonight's meal" push is enabled. Default: on.
    var pushTonightsMealEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.pushDefaultsKey("push_tonights_meal")) as? Bool ?? true }
    }

    /// Whether "Saturday plan reminder" push is enabled. Default: on.
    var pushSaturdayPlanEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.pushDefaultsKey("push_saturday_plan")) as? Bool ?? true }
    }

    /// User-local delivery time for tonight's-meal push. Default: "17:00".
    var pushTonightsMealTime: String {
        get { UserDefaults.standard.string(forKey: Self.pushDefaultsKey("push_tonights_meal_time")) ?? "17:00" }
    }

    /// User-local delivery time for Saturday plan push. Default: "18:00".
    var pushSaturdayPlanTime: String {
        get { UserDefaults.standard.string(forKey: Self.pushDefaultsKey("push_saturday_plan_time")) ?? "18:00" }
    }

    /// Whether the AI-finished-thinking push fires after a planning turn
    /// that ran tools (e.g. `generate_week_plan`). Default: on. iOS
    /// suppresses banners while foregrounded automatically, so this is
    /// only visible when the user has the app backgrounded mid-turn.
    ///
    /// NOTE: unlike the two reminders above, this toggle isn't wired to
    /// anything local yet — it was originally an Fly/APNs push, same as the
    /// rest of this file, and reimplementing it isn't in scope for
    /// simmersmith-990.6 (which covers only "tonight's meal" + "Saturday
    /// plan"). The preference is preserved (now local) so the Settings
    /// toggle keeps working; it just has no effect until a future ticket
    /// wires it to something.
    var pushAssistantDoneEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.pushDefaultsKey("push_assistant_done")) as? Bool ?? true }
    }

    /// True iff iOS has the user's notifications-denied state on record. The
    /// Settings UI surfaces an "Open iOS Settings" affordance when this is
    /// true so the user can recover from a prior denial (toggling the in-app
    /// switches won't re-trigger the system prompt once iOS has decided).
    var pushAuthorizationDenied: Bool {
        get { pushAuthorizationStatus == .denied }
    }

    // MARK: - Persist

    /// Persist a push preference locally (UserDefaults — see file header). On
    /// enable, also (re-)request iOS authorization. If iOS reports
    /// `.notDetermined` this fires the system prompt; if `.authorized`
    /// it re-registers for remote notifications (CloudKit's transport); if
    /// `.denied` it's a no-op and the UI shows the "Open iOS Settings" hint.
    /// Either way, reschedules the two local reminders so a toggle flip takes
    /// effect immediately.
    func savePushPreference(_ key: String, enabled: Bool) async {
        UserDefaults.standard.set(enabled, forKey: Self.pushDefaultsKey(key))
        if enabled {
            await PushService.shared.requestAuthorizationAndRegister()
            await refreshPushAuthorizationStatus()
        }
        rescheduleLocalNotifications()
    }

    /// Persist a push time string (HH:mm) locally (UserDefaults) and
    /// reschedule the two local reminders so the new time takes effect.
    func savePushTime(_ key: String, date: Date) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeString = formatter.string(from: date)
        UserDefaults.standard.set(timeString, forKey: Self.pushDefaultsKey(key))
        rescheduleLocalNotifications()
    }

    // MARK: - Bootstrap

    /// Re-read the system authorization status into `pushAuthorizationStatus`,
    /// then reschedule the two local reminders. This is the one call site
    /// SettingsView already invokes unconditionally (Notifications section
    /// `.onAppear`), so it doubles as the main "keep the schedule fresh" hook
    /// today — see the file-level KNOWN GAP note for why that isn't enough on
    /// its own.
    func refreshPushAuthorizationStatus() async {
        pushAuthorizationStatus = await PushService.shared.currentAuthorizationStatus()
        rescheduleLocalNotifications()
    }

    /// Called after `refreshAll()` hydrates the profile. Reads the real iOS
    /// authorization status (not a UserDefaults flag) and reacts:
    ///
    ///   - `.notDetermined` + at least one toggle enabled → show the
    ///     system prompt. This is the fresh-install / first-launch path.
    ///   - `.authorized` / `.provisional` / `.ephemeral` → re-register
    ///     for remote notifications so a token rotation or restore from
    ///     backup keeps CloudKit's silent-push transport alive.
    ///   - `.denied` → no-op. The Settings UI surfaces an "Open iOS
    ///     Settings" affordance via `pushAuthorizationDenied`.
    ///
    /// Best-effort: a failure here must never crash bootstrap. See the
    /// file-level KNOWN GAP note — this function's only call site
    /// (`AppState.swift`'s `refreshAll()`) is gated by `hasSavedConnection`,
    /// which is unreachable for CloudKit-only users today.
    func ensurePushBootstrap() async {
        await refreshPushAuthorizationStatus()
        let status = pushAuthorizationStatus
        let toggleEnabled = pushTonightsMealEnabled || pushSaturdayPlanEnabled
        switch status {
        case .notDetermined:
            if toggleEnabled {
                await PushService.shared.requestAuthorizationAndRegister()
                await refreshPushAuthorizationStatus()
            }
        case .authorized, .provisional, .ephemeral:
            await PushService.shared.requestAuthorizationAndRegister()
        case .denied:
            break
        @unknown default:
            break
        }
        rescheduleLocalNotifications()
    }

    // MARK: - Local scheduling (simmersmith-990.6)

    /// Recompute + (re)schedule the two on-device reminders that replaced the
    /// Fly push scheduler, from LOCAL CloudKit data: `currentWeek` (today's
    /// dinner meal) and the week starting next Monday (the "still needs
    /// planning" check for the Saturday reminder). Cheap, local-only, and
    /// idempotent — `LocalNotificationService` uses fixed identifiers, so
    /// calling this repeatedly just replaces the prior pending request for
    /// each kind (or cancels it, when the decision flips to nil).
    ///
    /// No-ops when the CloudKit session isn't wired yet (`weekRepository ==
    /// nil`) rather than treating "no data yet" as "no week exists" — the
    /// latter would wrongly fire the Saturday reminder before the household's
    /// real week data has loaded.
    func rescheduleLocalNotifications() {
        #if canImport(CloudKit)
        guard weekRepository != nil else { return }

        let now = Date()
        let (tonightHour, tonightMinute) = Self.parsePushTime(pushTonightsMealTime, default: (17, 0))
        let (saturdayHour, saturdayMinute) = Self.parsePushTime(pushSaturdayPlanTime, default: (18, 0))

        let input = LocalPushSchedule.Input(
            now: now,
            calendar: .current,
            tonightMealEnabled: pushTonightsMealEnabled,
            saturdayPlanEnabled: pushSaturdayPlanEnabled,
            tonightMealHour: tonightHour,
            tonightMealMinute: tonightMinute,
            saturdayPlanHour: saturdayHour,
            saturdayPlanMinute: saturdayMinute,
            tonightDinnerRecipeName: todaysDinnerRecipeName(),
            nextWeekStatus: nextMondayWeekStatus()
        )
        let result = LocalPushSchedule.decide(input)

        if let reminder = result.tonightMeal {
            LocalNotificationService.scheduleTonightsMeal(
                deadline: reminder.fireDate, title: reminder.title, body: reminder.body
            )
        } else {
            LocalNotificationService.cancelTonightsMeal()
        }

        if let reminder = result.saturdayPlan {
            LocalNotificationService.scheduleSaturdayPlan(
                deadline: reminder.fireDate, title: reminder.title, body: reminder.body
            )
        } else {
            LocalNotificationService.cancelSaturdayPlan()
        }
        #endif
    }

    #if canImport(CloudKit)
    /// Tonight's dinner-slot recipe name from `currentWeek`, or nil when
    /// there's no dinner meal planned for today (UTC-day match — mealDate is
    /// stored at UTC midnight, matching `WeekRepository`'s convention).
    private func todaysDinnerRecipeName() -> String? {
        guard let week = currentWeek else { return nil }
        let today = Date()
        return week.meals.first { $0.slot == "dinner" && WeekBoundary.isSameUTCDay($0.mealDate, today) }?.recipeName
    }

    /// `status` of the week starting next Monday, or nil when that week
    /// doesn't exist in the store yet (mirrors the Fly scheduler treating an
    /// absent row the same as "still needs planning" — see `LocalPushSchedule`).
    private func nextMondayWeekStatus() -> String? {
        guard let repo = weekRepository else { return nil }
        let thisMonday = WeekBoundary.mondayStart(containing: Date())
        guard let nextMonday = WeekBoundary.utcCalendar.date(byAdding: .day, value: 7, to: thisMonday) else {
            return nil
        }
        return repo.week(forStart: nextMonday)?.status
    }
    #endif

    // MARK: - UserDefaults key helper

    private static func pushDefaultsKey(_ settingKey: String) -> String {
        "simmersmith.\(settingKey)"
    }

    /// Parse "HH:mm" → (hour, minute), falling back to `fallback` on
    /// malformed input (mirrors the Fly scheduler's `_parse_time` skip-on-
    /// malformed rule, except defaulting instead of skipping — in practice
    /// this can't happen today since the Settings `DatePicker` always emits
    /// valid HH:mm, so this is a defensive-only fallback).
    private static func parsePushTime(_ s: String, default fallback: (Int, Int)) -> (Int, Int) {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            return fallback
        }
        return (parts[0], parts[1])
    }
}
