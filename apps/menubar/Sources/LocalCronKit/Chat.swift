// The Chat page of the app window: the runs of each job and the messages
// they sent, as a conversation, one channel per job, as in Slack. Only jobs
// write; the user reads.

import Foundation

public enum Chat {
    /// A job: one that exists, or one whose runs or messages the daemon
    /// still keeps.
    public struct Channel: Equatable, Sendable, Identifiable {
        public var jobID: String
        public var unread: Int
        /// The time of its newest run or message; nil when it has neither.
        public var last: Date?
        /// Its run that works or waits for a free slot now.
        public var working: Run?
        public var id: String { jobID }
    }

    /// One run as a post: its status line, then the messages it sent,
    /// oldest first. `run` is nil when the daemon no longer keeps the run
    /// but still keeps its messages.
    public struct Group: Equatable, Sendable, Identifiable {
        public var jobID: String
        public var runID: String
        /// When the run started (queued, if it never started), or the time
        /// of its first message without the run.
        public var at: Date
        public var run: Run?
        public var messages: [Message]
        public var id: String { runID }

        public func contains(message id: UInt64?) -> Bool {
            messages.contains { $0.id == id }
        }
    }

    /// The posts of one day, oldest first.
    public struct Day: Equatable, Sendable, Identifiable {
        public var day: Date
        public var title: String
        public var groups: [Group]
        public var id: Date { day }
    }

    /// One channel per job: those that run now first, then those with the
    /// newest run or message, then the jobs with neither, by name.
    public static func channels(_ messages: [Message], runs: [Run] = [], jobIDs: [String] = []) -> [Channel] {
        var byJob: [String: Channel] = [:]
        func touch(_ jobID: String, _ at: Date?) {
            var channel = byJob[jobID] ?? Channel(jobID: jobID, unread: 0, last: nil, working: nil)
            if let at { channel.last = max(channel.last ?? at, at) }
            byJob[jobID] = channel
        }
        for jobID in jobIDs { touch(jobID, nil) }
        for run in runs {
            touch(run.jobId, run.shownAt)
            if !run.status.isFinished, byJob[run.jobId]?.working == nil { byJob[run.jobId]?.working = run }
        }
        for message in messages {
            guard let at = ApiDate.parse(message.at) else { continue }
            touch(message.jobId, at)
            if !message.read { byJob[message.jobId]?.unread += 1 }
        }
        return byJob.values.sorted { a, b in
            if (a.working == nil) != (b.working == nil) { return a.working != nil }
            return switch (a.last, b.last) {
            case let (x?, y?) where x != y: x > y
            case (_?, nil): true
            case (nil, _?): false
            default: a.jobID < b.jobID
            }
        }
    }

    /// The messages of a channel (all jobs with nil), oldest first.
    public static func messages(_ messages: [Message], jobID: String?) -> [(message: Message, at: Date)] {
        messages
            .filter { jobID == nil || $0.jobId == jobID }
            .compactMap { m in ApiDate.parse(m.at).map { (message: m, at: $0) } }
            .sorted { ($0.at, $0.message.id) < ($1.at, $1.message.id) }
    }

    /// The oldest unread message of a channel: the "New" line goes above
    /// the post that holds it.
    public static func firstUnread(_ messages: [Message], jobID: String?) -> UInt64? {
        Self.messages(messages, jobID: jobID).first { !$0.message.read }?.message.id
    }

    /// A channel as days of posts, oldest first: one post per run, with the
    /// messages it sent.
    public static func timeline(_ messages: [Message], runs: [Run] = [], jobID: String?, now: Date = Date(),
                                calendar: Calendar = .current) -> [Day] {
        var groups: [String: Group] = [:]
        for run in runs where jobID == nil || run.jobId == jobID {
            guard let at = run.shownAt, groups[run.id] == nil else { continue }
            groups[run.id] = Group(jobID: run.jobId, runID: run.id, at: at, run: run, messages: [])
        }
        for (message, at) in Self.messages(messages, jobID: jobID) {
            if groups[message.runId] == nil {
                groups[message.runId] = Group(jobID: message.jobId, runID: message.runId, at: at, run: nil, messages: [])
            }
            groups[message.runId]?.messages.append(message)
        }
        var days: [Day] = []
        for group in groups.values.sorted(by: { ($0.at, $0.runID) < ($1.at, $1.runID) }) {
            let day = calendar.startOfDay(for: group.at)
            if days.last?.day != day {
                days.append(Day(day: day, title: Formatting.dayTitle(day, now: now, calendar: calendar), groups: []))
            }
            days[days.count - 1].groups.append(group)
        }
        return days
    }
}
