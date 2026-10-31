// What the Runs tab, the calendar and the run log say about a run, in
// words. Pure functions, so they are tested.

import Foundation

extension Run {
    public var queued: Date? { ApiDate.parse(queuedAt) }
    public var start: Date? { ApiDate.parse(startedAt) }
    public var end: Date? { ApiDate.parse(endedAt) }
    /// When the run started, or was queued when it never started.
    public var shownAt: Date? { start ?? queued }

    /// Seconds from start to end, or to `now` while it runs.
    public func seconds(now: Date = Date()) -> TimeInterval? {
        guard let start else { return nil }
        return (end ?? now).timeIntervalSince(start)
    }

    /// It did not run at all: it was skipped, or failed before it started.
    public var neverStarted: Bool { startedAt == nil && status.isFinished }
}

public enum RunText {
    /// The color of a line of text.
    public enum Tone: Sendable {
        case plain, accent, danger, warning
    }

    /// "Working for 3 min 12 s", "Succeeded in 6 min 40 s", "Failed with exit
    /// code 2 after 1 min 48 s", "Stopped after 60 min, its time limit".
    public static func line(_ run: Run, now: Date = Date(), calendar: Calendar = .current) -> (text: String, tone: Tone) {
        let took = run.seconds(now: now).map(Formatting.duration)
        switch run.status {
        case .queued:
            return ("Waits for a free slot", .plain)
        case .running:
            return ("Working for \(took ?? "a moment")", .accent)
        case .succeeded:
            var text = "Succeeded" + (took.map { " in \($0)" } ?? "")
            if run.trigger == .catchUp, let due = ApiDate.parse(run.dueAt) {
                text = "Due at \(Formatting.clock(due, calendar: calendar)), the Mac was asleep. " + text
            }
            return (text, .plain)
        case .failed:
            if run.neverStarted { return ("Did not start: \(reason(run.message))", .danger) }
            if let code = run.exitCode {
                return ("Failed with exit code \(code)" + (took.map { " after \($0)" } ?? ""), .danger)
            }
            return ("Failed" + (took.map { " after \($0)" } ?? "") + (run.message.isEmpty ? "" : ": \(reason(run.message))"), .danger)
        case .timedOut:
            let minutes = Int(((run.seconds(now: now) ?? 0) / 60).rounded())
            return ("Stopped after \(minutes) min, its time limit", .warning)
        case .canceled:
            let after = took.map { " after \($0)" } ?? ""
            if run.message.isEmpty || run.message == "canceled" { return ("Stopped by you\(after)", .plain) }
            return ("Stopped\(after): \(reason(run.message))", .plain)
        case .skipped:
            return ("Did not start: \(reason(run.message))", .plain)
        }
    }

    /// A short label next to the job name: who or what started the run.
    public static func chip(_ run: Run) -> String? {
        switch run.trigger {
        case .manual: "Run by you"
        case .catchUp: "Caught up"
        case .early: "Run early"
        case .schedule: nil
        }
    }

    /// "The schedule", "You, from the app or an agent", "Caught up after sleep".
    public static func startedBy(_ run: Run, scheduleText: String?) -> String {
        switch run.trigger {
        case .schedule: scheduleText.map { "The schedule, \($0.prefix(1).lowercased() + $0.dropFirst())" } ?? "The schedule"
        case .catchUp: "Caught up: the Mac slept or was off at its time"
        case .manual: "You, or an agent: an extra run"
        case .early: "You, or an agent: the next scheduled run, early"
        }
    }

    /// The daemon's message with a capital letter removed and no full stop:
    /// it follows a colon.
    private static func reason(_ message: String) -> String {
        let m = message.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return m.isEmpty ? "no reason given" : m
    }
}

/// The Runs tab's filter.
public enum RunFilter: String, CaseIterable, Identifiable, Sendable {
    case all, failed, working

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .failed: "Failed"
        case .working: "Working"
        }
    }

    public func matches(_ run: Run) -> Bool {
        switch self {
        case .all: true
        case .failed: run.status.isFailure
        case .working: !run.status.isFinished
        }
    }
}

/// Runs of one day, newest first.
public struct RunDay: Equatable, Sendable, Identifiable {
    public var day: Date
    public var title: String
    public var runs: [Run]
    public var id: Date { day }
}

public enum RunGroups {
    /// Runs grouped by the day they started, newest day first. Runs keep
    /// their order inside a day (the daemon sends newest first).
    public static func byDay(_ runs: [Run], now: Date = Date(), calendar: Calendar = .current) -> [RunDay] {
        var days: [RunDay] = []
        for run in runs {
            guard let at = run.shownAt else { continue }
            let day = calendar.startOfDay(for: at)
            if let i = days.firstIndex(where: { $0.day == day }) {
                days[i].runs.append(run)
            } else {
                days.append(RunDay(day: day, title: Formatting.dayTitle(day, now: now, calendar: calendar), runs: [run]))
            }
        }
        return days.sorted { $0.day > $1.day }
    }

    /// "5 runs", "1 run".
    public static func count(_ n: Int) -> String { n == 1 ? "1 run" : "\(n) runs" }
}

/// The jobs of one folder in the Jobs tab.
public struct JobFolder: Equatable, Sendable, Identifiable {
    /// The folder as the job has it.
    public var dir: String
    /// `~/Projects/shop`.
    public var title: String
    /// "3 jobs, 1 running", "1 job, off".
    public var summary: String
    public var jobs: [JobView]
    public var id: String { dir }
}

public enum JobGroups {
    /// Jobs grouped by folder, folders in the order of their names. Inside a
    /// folder: running jobs first, then by the next run, then off.
    public static func byFolder(_ jobs: [JobView], home: String = NSHomeDirectory()) -> [JobFolder] {
        let groups = Dictionary(grouping: jobs, by: \.job.dir)
        return groups.keys.sorted().map { dir in
            let list = groups[dir]!.sorted(by: order)
            let running = list.filter { $0.activeRun != nil }.count
            var summary = list.count == 1 ? "1 job" : "\(list.count) jobs"
            if running > 0 { summary += ", \(running) running" }
            if list.allSatisfy({ !$0.job.enabled }) { summary += ", off" }
            return JobFolder(dir: dir, title: tilde(dir, home: home), summary: summary, jobs: list)
        }
    }

    /// `/Users/me/Projects/shop` → `~/Projects/shop`.
    public static func tilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func order(_ a: JobView, _ b: JobView) -> Bool {
        func rank(_ j: JobView) -> Int { j.activeRun != nil ? 0 : j.job.enabled ? 1 : 2 }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        let na = ApiDate.parse(a.nextRun) ?? .distantFuture, nb = ApiDate.parse(b.nextRun) ?? .distantFuture
        return na != nb ? na < nb : a.id < b.id
    }
}
