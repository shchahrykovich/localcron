// The tokens agent runs used, per day and per job: the Usage view of the
// Runs tab. Pure functions, so they are tested.

import Foundation

/// Which tokens a chart counts.
public enum TokenMetric: String, CaseIterable, Sendable {
    /// Every token: new input, cache write, cache read and output.
    case all = "All tokens"
    /// Only what the model wrote.
    case output = "Output"

    public func value(_ u: TokenUsage) -> UInt64 {
        switch self {
        case .all: u.total
        case .output: u.outputTokens
        }
    }
}

/// How far back the Usage view looks.
public enum UsagePeriod: Int, CaseIterable, Sendable {
    case week = 7, month = 30, quarter = 90

    public var title: String { "\(rawValue) days" }
}

/// The kinds of tokens, for the chart of one job.
public enum TokenKind: String, CaseIterable, Sendable {
    case input = "New input", cacheWrite = "Cache write", cacheRead = "Cache read", output = "Output"

    public func value(_ u: TokenUsage) -> UInt64 {
        switch self {
        case .input: u.inputTokens
        case .cacheWrite: u.cacheWriteTokens
        case .cacheRead: u.cacheReadTokens
        case .output: u.outputTokens
        }
    }
}

/// One part of a day's bar: the tokens of a job, or of a kind of tokens.
public struct TokenBar: Equatable, Sendable, Identifiable {
    public var day: Date
    /// A job id, `TokenStats.other`, or a `TokenKind` title.
    public var series: String
    public var tokens: UInt64

    public var id: String { "\(day.timeIntervalSince1970) \(series)" }
}

/// The tokens of one job in the period.
public struct JobTokens: Equatable, Sendable, Identifiable {
    public var jobID: String
    public var usage: TokenUsage
    public var runs: Int

    public var id: String { jobID }
}

public struct TokenStats: Equatable, Sendable {
    /// The series of the jobs after the largest ones.
    public static let other = "Other jobs"

    /// Each day of the period, the oldest first.
    public var days: [Date]
    /// The bars, in the order of `series`.
    public var bars: [TokenBar]
    /// The parts of a bar, the largest first: job ids then `other`, or the
    /// kinds of tokens for one job.
    public var series: [String]
    /// The jobs, the most tokens first.
    public var jobs: [JobTokens]
    public var total: TokenUsage
    /// The runs that have tokens.
    public var runs: Int

    /// `job`: one job, its bars split by kind of tokens. Without it the bars
    /// are split by job: the `top` largest ones, and the rest together.
    public init(runs all: [Run], now: Date, period: UsagePeriod, metric: TokenMetric, job: String? = nil, top: Int = 5,
                calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        days = (0..<period.rawValue).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let first = days.first ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let runs = all.filter { run in
            guard run.usage != nil, let at = run.shownAt else { return false }
            return at >= first && at < end && (job == nil || run.jobId == job)
        }
        self.runs = runs.count
        total = runs.compactMap(\.usage).reduce(TokenUsage(), +)

        var byJob: [String: JobTokens] = [:]
        for run in runs {
            guard let usage = run.usage else { continue }
            var entry = byJob[run.jobId] ?? JobTokens(jobID: run.jobId, usage: TokenUsage(), runs: 0)
            entry.usage = entry.usage + usage
            entry.runs += 1
            byJob[run.jobId] = entry
        }
        jobs = byJob.values.sorted { (metric.value($0.usage), $1.jobID) > (metric.value($1.usage), $0.jobID) }

        // The series of a run's tokens.
        let parts: (Run, TokenUsage) -> [(String, UInt64)]
        if job != nil {
            let kinds = metric == .output ? [TokenKind.output] : TokenKind.allCases
            series = kinds.map(\.rawValue)
            parts = { _, u in kinds.map { ($0.rawValue, $0.value(u)) } }
        } else {
            let named = jobs.prefix(top).map(\.jobID)
            let rest = jobs.count > top
            series = named + (rest ? [Self.other] : [])
            parts = { run, u in [(named.contains(run.jobId) ? run.jobId : Self.other, metric.value(u))] }
        }
        var sums: [Date: [String: UInt64]] = [:]
        for run in runs {
            guard let usage = run.usage, let at = run.shownAt else { continue }
            let day = calendar.startOfDay(for: at)
            for (name, n) in parts(run, usage) {
                sums[day, default: [:]][name, default: 0] += n
            }
        }
        let order = series
        bars = days.flatMap { day in
            order.compactMap { name in
                guard let n = sums[day]?[name], n > 0 else { return nil }
                return TokenBar(day: day, series: name, tokens: n)
            }
        }
    }

    /// The largest day.
    public var peak: UInt64 {
        Dictionary(grouping: bars, by: \.day).values.map { $0.reduce(0) { $0 + $1.tokens } }.max() ?? 0
    }
}

extension Formatting {
    /// A token count in a few characters: "812", "46K", "9.3M", "46M".
    public static func tokens(_ n: UInt64) -> String {
        let v = Double(n)
        if n < 1000 { return "\(n)" }
        if n < 999_500 { return "\(Int((v / 1e3).rounded()))K" }
        if n < 10_000_000 { return String(format: "%.1fM", v / 1e6) }
        return "\(Int((v / 1e6).rounded()))M"
    }

    /// "9.3M tokens, 46K out".
    public static func tokens(_ u: TokenUsage) -> String {
        "\(tokens(u.total)) tokens, \(tokens(u.outputTokens)) out"
    }
}

extension RunText {
    /// "9.3M: 138 new input, 206K cache write, 9.1M cache read, 46K output. 69 requests to claude-opus-5-5".
    public static func tokens(_ u: TokenUsage) -> String {
        let parts = [
            "\(Formatting.tokens(u.inputTokens)) new input",
            "\(Formatting.tokens(u.cacheWriteTokens)) cache write",
            "\(Formatting.tokens(u.cacheReadTokens)) cache read",
            "\(Formatting.tokens(u.outputTokens)) output",
        ]
        var text = "\(Formatting.tokens(u.total)): " + parts.joined(separator: ", ") + "."
        if u.requests > 0 {
            text += " \(u.requests) request\(u.requests == 1 ? "" : "s")"
            if !u.models.isEmpty { text += " to " + u.models.joined(separator: ", ") }
        }
        return text
    }
}
