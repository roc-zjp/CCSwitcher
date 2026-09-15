import Foundation

/// When the daily pre-warm should fire, and whether today's has happened yet.
///
/// Kept as pure functions over an injected `now` so the scheduling rules - which
/// are entirely about wall-clock edge cases - are testable without waiting for
/// 8am to come around.
enum PrewarmSchedule {

    /// How late a missed pre-warm is still worth doing.
    ///
    /// The Mac may have been asleep at the scheduled time. Waking at 09:30 and
    /// igniting is still useful; waking at 23:00 and igniting is worse than
    /// doing nothing, because it would open a window nobody is awake to use and
    /// push tomorrow morning's boundary into the evening.
    static let catchUpWindow: TimeInterval = 3 * 3600

    /// Today's scheduled moment, or nil if today is not a day we fire on.
    static func fireDate(
        on day: Date,
        hour: Int,
        minute: Int,
        weekdaysOnly: Bool,
        calendar: Calendar = .current
    ) -> Date? {
        if weekdaysOnly {
            // Calendar weekday: 1 = Sunday ... 7 = Saturday.
            let weekday = calendar.component(.weekday, from: day)
            guard weekday != 1 && weekday != 7 else { return nil }
        }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }

    /// Should the pre-warm run right now?
    ///
    /// True only when we are inside the catch-up window that starts at today's
    /// fire time and the day has not already been warmed. `lastRunDay` is a day
    /// stamp rather than a timestamp so that "once per day" survives restarts
    /// and clock changes.
    static func shouldRun(
        now: Date,
        hour: Int,
        minute: Int,
        weekdaysOnly: Bool,
        lastRunDay: String?,
        calendar: Calendar = .current
    ) -> Bool {
        guard let fire = fireDate(on: now, hour: hour, minute: minute, weekdaysOnly: weekdaysOnly, calendar: calendar) else {
            return false
        }
        guard now >= fire, now.timeIntervalSince(fire) <= catchUpWindow else { return false }
        return lastRunDay != dayStamp(now, calendar: calendar)
    }

    /// Stable `yyyy-MM-dd` key for "which day has been warmed".
    static func dayStamp(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
