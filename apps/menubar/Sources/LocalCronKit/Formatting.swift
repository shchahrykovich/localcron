// Text for the views: when a job runs next, how long a run took, and the
// args field of the editor. Pure functions, so they are tested.

import Foundation

public enum Formatting {
    /// "in 5 min, 14:05", "today 17:00", "tomorrow 09:00", "in 6 days, Wed 09:00",
    /// "5 Nov 2026 09:00".
    public static func next(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = clock(date, calendar: calendar)
        let seconds = date.timeIntervalSince(now)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "in \(Int(seconds / 60)) min, \(time)" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case 0: return "today \(time)"
        case 1: return "tomorrow \(time)"
        case 2..<7: return "in \(days) days, \(weekday(date, calendar: calendar)) \(time)"
        default: return "\(day(date, calendar: calendar)) \(time)"
        }
    }

    /// "5 min ago", "today 09:00", "yesterday 09:00", "Wed 28 Oct 09:00".
    public static func past(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let time = clock(date, calendar: calendar)
        switch days {
        case 0: return "today \(time)"
        case 1: return "yesterday \(time)"
        default: return "\(weekday(date, calendar: calendar)) \(day(date, calendar: calendar, year: false)) \(time)"
        }
    }

    /// "0.4 s", "12 s", "3 min 5 s", "1 h 2 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", max(0, seconds)) }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// "12:00, in 1 h 20 min", "tomorrow 02:00", "Monday 09:00", "2 Nov 09:00":
    /// the next runs in the menu.
    public static func soon(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = clock(date, calendar: calendar)
        switch dayOffset(from: now, to: date, calendar: calendar) {
        case ...0: return "\(time), \(left(date.timeIntervalSince(now)))"
        case 1: return "tomorrow \(time)"
        case 2..<7: return "\(formatter("EEEE", calendar).string(from: date)) \(time)"
        default: return "\(day(date, calendar: calendar, year: false)) \(time)"
        }
    }

    /// "now", "in 20 min", "in 1 h 20 min", "in 3 h".
    public static func left(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    /// A past time, short: "02:00" today, "yesterday 18:00", "28 Oct 09:00".
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = clock(date, calendar: calendar)
        switch dayOffset(from: date, to: now, calendar: calendar) {
        case ...0: return time
        case 1: return "yesterday \(time)"
        default: return "\(day(date, calendar: calendar, year: false)) \(time)"
        }
    }

    /// The title of a day of runs: "Today, Friday 30 October", "Yesterday",
    /// "Wednesday 28 October", "Monday 3 November 2025".
    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let long = formatter(sameYear ? "EEEE d MMMM" : "EEEE d MMMM yyyy", calendar).string(from: date)
        switch dayOffset(from: date, to: now, calendar: calendar) {
        case 0: return "Today, \(long)"
        case 1: return "Yesterday"
        default: return long
        }
    }

    /// "HH:mm".
    public static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        formatter("HH:mm", calendar).string(from: date)
    }

    /// Sizes of logs, 1 MB = 1024 * 1024 bytes: "820 bytes", "12 KB",
    /// "38 MB", "1 GB", "1.5 GB".
    public static func bytes(_ n: UInt64) -> String {
        let kb: Double = 1024, mb = kb * 1024, gb = mb * 1024
        let v = Double(n)
        if v < kb { return "\(n) bytes" }
        if v < mb { return "\(Int((v / kb).rounded())) KB" }
        if v < gb { return "\(Int((v / mb).rounded())) MB" }
        let g = v / gb
        return g.rounded() == (g * 10).rounded() / 10 ? "\(Int(g.rounded())) GB" : String(format: "%.1f GB", g)
    }

    /// Whole days from the day of `a` to the day of `b`.
    static func dayOffset(from a: Date, to b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }

    /// The editor's args field: one argument per line, or words split by
    /// spaces on one line. Quotes group words: `--allowedTools "Bash(git *)"`.
    public static func splitArgs(_ text: String) -> [String] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.count > 1 { return lines }
        var out: [String] = []
        var current = ""
        var quote: Character?
        var started = false
        for ch in lines.first ?? "" {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                started = true
            } else if ch == " " {
                if started || !current.isEmpty { out.append(current) }
                current = ""
                started = false
            } else {
                current.append(ch)
            }
        }
        if started || !current.isEmpty { out.append(current) }
        return out
    }

    /// The args as the editor shows them: one per line when any has a space.
    public static func joinArgs(_ args: [String]) -> String {
        args.contains(where: { $0.contains(" ") }) ? args.joined(separator: "\n") : args.joined(separator: " ")
    }

    static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    private static func weekday(_ d: Date, calendar: Calendar) -> String { formatter("EEE", calendar).string(from: d) }
    private static func day(_ d: Date, calendar: Calendar, year: Bool = true) -> String {
        formatter(year ? "d MMM yyyy" : "d MMM", calendar).string(from: d)
    }
}
