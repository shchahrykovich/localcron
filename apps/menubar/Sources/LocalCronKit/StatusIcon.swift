import Foundation

/// The look of the menu bar icon, chosen in Settings, General.
public enum IconStyle: String, CaseIterable, Identifiable, Sendable {
    /// A clock; a small sign on its corner says what is going on.
    case clock
    /// A ring that fills during the 2 hours before the next run.
    case ring
    /// The clock and a short text: the next time, or what is wrong.
    case clockText = "text"
    /// A filled square with the sign cut out of it.
    case tile

    public static let defaultsKey = "menuBarIconStyle"
    /// "Show problems in color". On by default.
    public static let colorKey = "menuBarIconColor"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clock: "Clock"
        case .ring: "Countdown ring"
        case .clockText: "Clock and text"
        case .tile: "Tile"
        }
    }

    public var detail: String {
        switch self {
        case .clock: "A small sign on the corner: a run works, a run failed, a job waits, or all jobs are paused."
        case .ring: "The ring fills during the 2 hours before the next run. While a run works, an arc goes round."
        case .clockText: "The time of the next run, or what is wrong, in words. Takes the most space."
        case .tile: "A filled square, easy to find in a full menu bar."
        }
    }

    public static func saved(_ raw: String?) -> IconStyle {
        raw.flatMap(IconStyle.init(rawValue:)) ?? .clock
    }
}

/// What the menu bar icon shows. One state at a time; the tooltip lists
/// everything.
public enum IconState: String, CaseIterable, Sendable {
    case idle, working, failed, waiting, paused
    /// The daemon does not answer.
    case down
}

public struct StatusIcon: Equatable, Sendable {
    /// The daemon does not answer.
    public var down: Bool
    /// Runs that are running now (queued runs are not counted).
    public var running: Int
    /// Scheduled runs do not start.
    public var paused: Bool
    /// The jobs whose last run failed or timed out. The warning stays until
    /// a run of the job ends well, or the job is removed.
    public var failedJobs: [String]
    /// Jobs that may not read their secrets until the user allows them.
    public var waitingJobs: [String]
    /// The next scheduled run; nil when there is none.
    public var next: Date?
    /// When the oldest run that is running now started.
    public var runningSince: Date?

    public init(down: Bool = false, running: Int = 0, paused: Bool = false, failedJobs: [String] = [],
                waitingJobs: [String] = [], next: Date? = nil, runningSince: Date? = nil) {
        self.down = down
        self.running = running
        self.paused = paused
        self.failedJobs = failedJobs
        self.waitingJobs = waitingJobs
        self.next = next
        self.runningSince = runningSince
    }

    /// `status` is nil when the daemon does not answer; then `jobs` is old
    /// and only the problem is shown.
    public init(status: StatusResult?, jobs: [JobView]) {
        guard let status else {
            self.init(down: true)
            return
        }
        let starts = jobs.compactMap { $0.activeRun?.status == .running ? ApiDate.parse($0.activeRun?.startedAt) : nil }
        self.init(running: status.running,
                  paused: status.paused,
                  failedJobs: jobs.filter { $0.lastRun?.status.isFailure == true }.map(\.id),
                  waitingJobs: jobs.filter { $0.secretsAllowed == false }.map(\.id),
                  next: status.paused ? nil : ApiDate.parse(status.next?.at),
                  runningSince: starts.min())
    }

    /// A job that waits for its secrets failed for that reason: it counts
    /// as waiting, not as failed.
    public var failedOnly: [String] { failedJobs.filter { !waitingJobs.contains($0) } }

    public var warning: Bool { !failedJobs.isEmpty || !waitingJobs.isEmpty }

    /// A run that works is shown first: it is what changes now. A failure
    /// shows again when it ends.
    public var state: IconState {
        if down { return .down }
        if running > 0 { return .working }
        if !failedOnly.isEmpty { return .failed }
        if !waitingJobs.isEmpty { return .waiting }
        if paused { return .paused }
        return .idle
    }

    /// The text of the "Clock and text" style: "12:00", "3 min", "1 failed",
    /// "1 waits", "Paused", "Off". Empty when there is nothing to say.
    public func label(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch state {
        case .idle:
            guard let next else { return "" }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.dateFormat = next.timeIntervalSince(now) < 24 * 3600 ? "HH:mm" : "EEE"
            return f.string(from: next)
        case .working:
            let seconds = runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
            return seconds < 3600 ? "\(max(1, Int(seconds / 60))) min" : "\(Int(seconds / 3600)) h"
        case .failed: return "\(failedOnly.count) failed"
        case .waiting: return "\(waitingJobs.count) waits"
        case .paused: return "Paused"
        case .down: return "Off"
        }
    }

    /// How full the countdown ring is: 0 two hours or more before the next
    /// run, 1 at its time.
    public func ringFraction(now: Date = Date()) -> Double {
        guard let next else { return 0 }
        return min(1, max(0, 1 - next.timeIntervalSince(now) / (2 * 3600)))
    }

    public func toolTip(appName: String, now: Date = Date()) -> String {
        var lines = [appName]
        if down { lines.append("The daemon is not running.") }
        if running > 0 { lines.append(running == 1 ? "1 run is running." : "\(running) runs are running.") }
        if paused { lines.append("Paused: scheduled runs do not start.") }
        if !waitingJobs.isEmpty { lines.append("Waiting for your OK to read secrets: \(waitingJobs.joined(separator: ", "))") }
        if !failedOnly.isEmpty { lines.append("The last run failed: \(failedOnly.joined(separator: ", "))") }
        if !down, !paused, let next { lines.append("Next run \(Formatting.next(next, now: now)).") }
        return lines.joined(separator: "\n")
    }
}
