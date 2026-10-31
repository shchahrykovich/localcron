// The "When" buttons of the job editor. Each writes a schedule; the field
// below shows it and can be changed by hand. Pure, so it is tested.

import Foundation

public enum SchedulePreset: String, CaseIterable, Identifiable, Sendable {
    case everyDay, weekdays, everyWeek, everyHour, once, in20Minutes

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .everyDay: "Every day"
        case .weekdays: "Weekdays"
        case .everyWeek: "Every week"
        case .everyHour: "Every hour"
        case .once: "Once"
        case .in20Minutes: "In 20 min"
        }
    }

    /// The schedule for this button. It keeps the time of day of `current`
    /// when it has one (09:00 otherwise). "Once" is tomorrow at that time.
    public func schedule(from current: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let (hour, minute) = Self.timeOfDay(current) ?? (9, 0)
        switch self {
        case .everyDay: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * mon-fri"
        case .everyWeek:
            let day = Self.weekday(current) ?? "mon"
            return "\(minute) \(hour) * * \(day)"
        case .everyHour: return "\(minute) * * * *"
        case .once:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            let at = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: tomorrow) ?? tomorrow
            return "@at " + Formatting.formatter("yyyy-MM-dd HH:mm", calendar).string(from: at)
        case .in20Minutes: return "@in 20m"
        }
    }

    /// The button that wrote this schedule, if one did.
    public static func matching(_ schedule: String) -> SchedulePreset? {
        let s = schedule.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@at ") { return .once }
        if s.hasPrefix("@in ") { return .in20Minutes }
        let f = s.split(separator: " ").map(String.init)
        guard f.count == 5, f[2] == "*", f[3] == "*", Int(f[0]) != nil else { return nil }
        if f[1] == "*" { return f[4] == "*" ? .everyHour : nil }
        guard Int(f[1]) != nil else { return nil }
        switch f[4] {
        case "*": return .everyDay
        case "mon-fri", "1-5": return .weekdays
        default: return weekday(s) != nil ? .everyWeek : nil
        }
    }

    /// The hour and minute of a cron schedule with one fixed time, or of `@at`.
    static func timeOfDay(_ schedule: String) -> (Int, Int)? {
        let s = schedule.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("@at ") {
            let time = s.split(separator: " ").dropFirst(2).first ?? ""
            let parts = time.split(separator: ":").compactMap { Int($0) }
            return parts.count >= 2 ? (parts[0], parts[1]) : nil
        }
        let f = s.split(separator: " ")
        guard f.count == 5, let minute = Int(f[0]) else { return nil }
        return Int(f[1]).map { ($0, minute) } ?? (f[1] == "*" ? (9, minute) : nil)
    }

    /// One day of the week, as a cron day name: "wed".
    static func weekday(_ schedule: String) -> String? {
        let f = schedule.split(separator: " ")
        guard f.count == 5 else { return nil }
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let day = f[4].lowercased()
        if names.contains(day) { return day }
        if let n = Int(day), (0...7).contains(n) { return names[n % 7] }
        return nil
    }
}
