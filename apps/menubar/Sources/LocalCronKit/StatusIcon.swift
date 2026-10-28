import Foundation

/// What the menu bar icon shows. StatusItemController draws it: the clock,
/// then a column with a warning triangle (top) and a pause sign (bottom).
public struct StatusIcon: Equatable, Sendable {
    /// The clock, an SF Symbol name.
    public var symbol: String
    /// Scheduled runs do not start.
    public var paused: Bool
    /// The jobs whose last run failed or timed out. The warning stays until
    /// a run of the job ends well, or the job is removed.
    public var failedJobs: [String]

    public var warning: Bool { !failedJobs.isEmpty }

    public init(symbol: String, paused: Bool, failedJobs: [String]) {
        self.symbol = symbol
        self.paused = paused
        self.failedJobs = failedJobs
    }

    /// `status` is nil when the daemon does not answer; then `jobs` is old
    /// and only the problem is shown.
    public init(status: StatusResult?, jobs: [JobView]) {
        guard let status else {
            self.init(symbol: "clock.badge.exclamationmark", paused: false, failedJobs: [])
            return
        }
        self.init(symbol: status.running > 0 ? "clock.arrow.circlepath" : "clock",
                  paused: status.paused,
                  failedJobs: jobs.filter { $0.lastRun?.status.isFailure == true }.map(\.id))
    }

    public func toolTip(appName: String) -> String {
        var lines = [appName]
        if symbol == "clock.badge.exclamationmark" { lines.append("The daemon is not running.") }
        if paused { lines.append("Paused: scheduled runs do not start.") }
        if warning { lines.append("The last run failed: \(failedJobs.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }
}
