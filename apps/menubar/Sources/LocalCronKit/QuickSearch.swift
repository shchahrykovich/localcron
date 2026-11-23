// The search palette of the app window (⌘F on any page), as Spotlight: one
// field, and the jobs, runs, secrets, messages and pages whose text has
// every word typed, best matches first.

import Foundation

public enum QuickSearch {
    public enum Section: String, CaseIterable, Sendable {
        case pages = "Pages", jobs = "Jobs", runs = "Runs", secrets = "Secrets", messages = "Messages"

        /// The most results a section shows.
        var limit: Int {
            switch self {
            case .pages: 3
            case .jobs: 6
            case .runs: 6
            case .secrets: 4
            case .messages: 4
            }
        }
    }

    /// What a result opens.
    public enum Target: Equatable, Hashable, Sendable {
        case page(String)
        case job(String)
        case run(String)
        case secret(String)
        case message(id: UInt64, jobID: String)
    }

    public struct Item: Equatable, Identifiable, Sendable {
        public var section: Section
        public var title: String
        public var detail: String
        public var target: Target
        public var id: Target { target }
        /// Lower is better: the title is the query, starts with it, has it,
        /// has a word that starts with it, or only the detail has it.
        var score: Int
    }

    /// The results for `query`: by section, then best match, then the
    /// order given (runs and messages newest first). An empty query gives
    /// the pages and the first jobs.
    public static func search(_ query: String, pages: [String], jobs: [JobView], runs: [Run], secrets: [SecretInfo],
                              messages: [Message], now: Date = Date(), calendar: Calendar = .current) -> [Item] {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let words = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var items: [Item] = []
        func add(_ section: Section, _ title: String, _ detail: String, _ more: String, _ target: Target) {
            guard let score = score(title: title, rest: detail + " " + more, query: q, words: words) else { return }
            items.append(Item(section: section, title: title, detail: detail, target: target, score: score))
        }
        for page in pages { add(.pages, page, "Page", "", .page(page)) }
        for job in jobs {
            let what = job.job.prompt ?? job.job.command ?? ""
            add(.jobs, job.id, "\(job.job.kind.title) · \(job.scheduleText)", what + " " + job.job.note, .job(job.id))
        }
        if !words.isEmpty {
            let newest = runs.sorted { ($0.shownAt ?? .distantPast) > ($1.shownAt ?? .distantPast) }
            for run in newest {
                let line = RunText.line(run, now: now, calendar: calendar).text
                let when = run.shownAt.map {
                    "\(Formatting.dayTitle($0, now: now, calendar: calendar)), \(Formatting.clock($0, calendar: calendar))"
                } ?? ""
                add(.runs, run.id, [when, line].filter { !$0.isEmpty }.joined(separator: " · "), run.status.rawValue, .run(run.id))
            }
            for secret in secrets {
                add(.secrets, secret.name, secret.description, secret.usedBy.joined(separator: " "), .secret(secret.name))
            }
            let newestMessages = messages.sorted { $0.id > $1.id }
            for message in newestMessages {
                let text = message.text.replacingOccurrences(of: "\n", with: " ")
                add(.messages, String(text.prefix(90)), message.runId, text + " " + message.jobId,
                    .message(id: message.id, jobID: message.jobId))
            }
        }
        var out: [Item] = []
        for section in Section.allCases {
            let hits = items.enumerated().filter { $0.element.section == section }
                .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
                .map(\.element)
            let limit = words.isEmpty && section == .jobs ? 8 : words.isEmpty ? Int.max : section.limit
            out += hits.prefix(limit)
        }
        return out
    }

    /// Lowercased, without accents.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func score(title: String, rest: String, query: String, words: [String]) -> Int? {
        if words.isEmpty { return 9 }
        let t = fold(title)
        let all = t + " " + fold(rest)
        guard words.allSatisfy({ all.contains($0) }) else { return nil }
        if t == query { return 0 }
        if t.hasPrefix(query) { return 1 }
        if t.contains(query) { return 2 }
        let parts = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.allSatisfy({ w in parts.contains { $0.hasPrefix(w) } }) { return 3 }
        if words.allSatisfy({ t.contains($0) }) { return 4 }
        return 5
    }
}
