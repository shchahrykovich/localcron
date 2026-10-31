// Where runs go in time: the Today strip of the Jobs tab, the month in the
// Runs tab and the week window. Positions are fractions (0 to 1), so the
// views only scale them. Pure functions, so they are tested.

import Foundation

/// How a run looks in the strip and the calendars.
public enum RunMark: String, CaseIterable, Sendable {
    case succeeded, failed, timedOut, stopped, working, planned

    public init(_ run: Run) {
        switch run.status {
        case .succeeded: self = .succeeded
        case .failed: self = .failed
        case .timedOut: self = .timedOut
        case .canceled, .skipped: self = .stopped
        case .queued, .running: self = .working
        }
    }

    public var title: String {
        switch self {
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .timedOut: "Timed out"
        case .stopped: "Stopped"
        case .working: "Working"
        case .planned: "Planned"
        }
    }

    /// Not OK: failed or timed out.
    public var isProblem: Bool { self == .failed || self == .timedOut }
}

/// A run, past, going on or planned, on a time line.
public struct TimeMark: Equatable, Sendable, Identifiable {
    public var id: String
    public var jobID: String
    public var mark: RunMark
    public var start: Date
    /// Planned runs and runs that go on have no end yet.
    public var end: Date?
    /// The run, for a past or running mark.
    public var runID: String?

    public init(id: String, jobID: String, mark: RunMark, start: Date, end: Date? = nil, runID: String? = nil) {
        self.id = id
        self.jobID = jobID
        self.mark = mark
        self.start = start
        self.end = end
        self.runID = runID
    }

    public init?(_ run: Run) {
        guard let start = run.shownAt else { return nil }
        self.init(id: run.id, jobID: run.jobId, mark: RunMark(run), start: start, end: run.end, runID: run.id)
    }

    /// Planned times of jobs: one mark for each time.
    public static func planned(_ times: [String: [Date]]) -> [TimeMark] {
        times.flatMap { job, dates in
            dates.map { TimeMark(id: "\(job)@\($0.timeIntervalSince1970)", jobID: job, mark: .planned, start: $0) }
        }
        .sorted { $0.start < $1.start }
    }
}

/// The Today strip: 12 hours around now, now a third of the way in.
public struct DayStrip: Equatable, Sendable {
    public var start: Date
    public var end: Date

    /// From the hour 4 hours before now, for 12 hours.
    public init(now: Date, calendar: Calendar = .current) {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        start = hour.addingTimeInterval(-4 * 3600)
        end = start.addingTimeInterval(12 * 3600)
    }

    public func fraction(_ date: Date) -> Double {
        date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }

    /// The labels under the strip: every 3 hours, start and end included.
    public var labels: [Date] { (0...4).map { start.addingTimeInterval(Double($0) * 3 * 3600) } }

    /// The marks in the strip, oldest first.
    public func marks(_ marks: [TimeMark]) -> [TimeMark] {
        marks.filter { contains($0.start) }.sorted { $0.start < $1.start }
    }
}

/// A day in the month grid.
public struct MonthDay: Equatable, Sendable, Identifiable {
    public var date: Date
    public var number: Int
    /// A day of the month before or after, to fill the first and last week.
    public var outside: Bool
    public var id: Date { date }
}

public enum MonthGrid {
    /// The weeks that hold the month of `date`, Monday first: 35 or 42 days.
    public static func days(of date: Date, calendar: Calendar = .current) -> [MonthDay] {
        var cal = calendar
        cal.firstWeekday = 2
        guard let month = cal.dateInterval(of: .month, for: date) else { return [] }
        let weekday = cal.component(.weekday, from: month.start)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        let count = cal.range(of: .day, in: .month, for: month.start)?.count ?? 30
        let cells = (lead + count + 6) / 7 * 7
        return (0..<cells).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i - lead, to: month.start) else { return nil }
            return MonthDay(date: day, number: cal.component(.day, from: day), outside: i < lead || i >= lead + count)
        }
    }

    /// How many marks of each kind, in a fixed order, for the bar of a day.
    public static func counts(_ marks: [TimeMark]) -> [(mark: RunMark, count: Int)] {
        RunMark.allCases.compactMap { kind in
            let n = marks.filter { $0.mark == kind }.count
            return n > 0 ? (kind, n) : nil
        }
    }

    /// "9 runs, 1 failed, 2 planned".
    public static func summary(_ marks: [TimeMark]) -> String {
        let past = marks.filter { $0.mark != .planned }.count
        var parts: [String] = []
        if past > 0 { parts.append(RunGroups.count(past)) }
        for kind in [RunMark.failed, .timedOut, .working, .planned] {
            let n = marks.filter { $0.mark == kind }.count
            if n > 0 { parts.append("\(n) \(kind.title.lowercased())") }
        }
        return parts.joined(separator: ", ")
    }

    /// The marks that start on the day of `date`.
    public static func marks(_ marks: [TimeMark], on date: Date, calendar: Calendar = .current) -> [TimeMark] {
        marks.filter { calendar.isDate($0.start, inSameDayAs: date) }
    }
}

/// A block of the week view: where it is in its day column.
public struct WeekBlock: Equatable, Sendable {
    /// Minutes from the start of the day.
    public var top: Double
    public var bottom: Double
    /// Its column among blocks that overlap, and how many columns they need.
    public var column: Int
    public var columns: Int
}

public enum WeekLayout {
    /// Blocks for the marks of one day. A block is at least `minMinutes`
    /// tall, so a short run stays readable; blocks that overlap share the
    /// width of the column side by side.
    public static func blocks(_ marks: [TimeMark], day: Date, minMinutes: Double = 40, now: Date = Date()) -> [WeekBlock] {
        let items = marks.map { m -> (Double, Double) in
            let top = max(0, m.start.timeIntervalSince(day) / 60)
            let end = m.end ?? (m.mark == .working ? now : m.start)
            return (top, min(24 * 60, max(top + minMinutes, end.timeIntervalSince(day) / 60)))
        }
        var out = items.map { WeekBlock(top: $0.0, bottom: $0.1, column: 0, columns: 1) }
        let order = out.indices.sorted { out[$0].top < out[$1].top }
        var cluster: [Int] = []
        var clusterEnd = -Double.infinity
        func close() {
            var ends: [Double] = []
            for i in cluster {
                if let k = ends.firstIndex(where: { $0 <= out[i].top }) {
                    out[i].column = k
                    ends[k] = out[i].bottom
                } else {
                    out[i].column = ends.count
                    ends.append(out[i].bottom)
                }
            }
            for i in cluster { out[i].columns = ends.count }
        }
        for i in order {
            if !cluster.isEmpty, out[i].top >= clusterEnd {
                close()
                cluster = []
                clusterEnd = -Double.infinity
            }
            cluster.append(i)
            clusterEnd = max(clusterEnd, out[i].bottom)
        }
        if !cluster.isEmpty { close() }
        return out
    }
}
