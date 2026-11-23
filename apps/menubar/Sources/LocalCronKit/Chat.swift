// The Chat page of the app window: the runs of each job and the messages
// they sent, as a conversation, one channel per job, as in Slack. The user
// writes to the manager (Manager.swift), whose answers go in the same
// channel.

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

    /// A post: one run, with its status line and the messages it sent,
    /// oldest first; or what the user wrote, or the manager answered, in a
    /// row. `run` is nil when the daemon no longer keeps the run but still
    /// keeps its messages.
    public struct Group: Equatable, Sendable, Identifiable {
        public enum Author: Equatable, Sendable {
            case job, user, manager
        }

        public var author: Author = .job
        public var jobID: String
        public var runID: String
        /// When the run started (queued, if it never started), or the time
        /// of its first message without the run, or of the first entry.
        public var at: Date
        public var run: Run?
        public var messages: [Message]
        /// The user's or the manager's entries.
        public var talk: [ManagerEntry] = []
        /// The post comes a few minutes after one by the same author on the
        /// same day: as in Slack, it shows no name and picture.
        public var continues = false

        public var id: String { author == .job ? runID : "talk-\(runID)" }

        /// The time of its last part.
        public var end: Date {
            max(talk.last?.at ?? at, messages.compactMap { ApiDate.parse($0.at) }.max() ?? at)
        }

        public func contains(message id: UInt64?) -> Bool {
            messages.contains { $0.id == id }
        }

        func sameAuthor(as other: Group) -> Bool {
            author == other.author && (author != .job || jobID == other.jobID)
        }

        /// Its text has `query` (lowercased) in it.
        func matches(_ query: String, now: Date) -> Bool {
            if jobID.lowercased().contains(query) || runID.lowercased().contains(query) { return true }
            if let run, RunText.line(run, now: now).text.lowercased().contains(query) { return true }
            return messages.contains { $0.text.lowercased().contains(query) }
                || talk.contains { $0.text.lowercased().contains(query) }
        }
    }

    /// Posts by one author within this time join, as in Slack.
    public static let joinWithin: TimeInterval = 10 * 60

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
    /// messages it sent, and the conversation with the manager. With a
    /// `query`, only the posts whose text has it.
    public static func timeline(_ messages: [Message], runs: [Run] = [], talk: [ManagerEntry] = [], jobID: String?,
                                query: String = "", now: Date = Date(), calendar: Calendar = .current) -> [Day] {
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
        var posts = groups.values.sorted { ($0.at, $0.runID) < ($1.at, $1.runID) }
        // The conversation keeps its own order; each post goes in after the
        // runs that started before it.
        var said: [Group] = []
        for entry in talk {
            let author: Group.Author = entry.fromUser ? .user : .manager
            if var last = said.last, last.author == author, entry.at.timeIntervalSince(last.end) < joinWithin,
               calendar.isDate(entry.at, inSameDayAs: last.at) {
                last.talk.append(entry)
                said[said.count - 1] = last
            } else {
                said.append(Group(author: author, jobID: jobID ?? "", runID: entry.id, at: entry.at, run: nil,
                                  messages: [], talk: [entry]))
            }
        }
        for post in said {
            let i = posts.firstIndex { $0.at > post.at } ?? posts.endIndex
            posts.insert(post, at: i)
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { posts = posts.filter { $0.matches(q, now: now) } }
        var days: [Day] = []
        for var post in posts {
            let day = calendar.startOfDay(for: post.at)
            if days.last?.day != day {
                days.append(Day(day: day, title: Formatting.dayTitle(day, now: now, calendar: calendar), groups: []))
            } else if let previous = days.last?.groups.last {
                post.continues = post.sameAuthor(as: previous) && post.at.timeIntervalSince(previous.end) < joinWithin
            }
            days[days.count - 1].groups.append(post)
        }
        return days
    }
}
