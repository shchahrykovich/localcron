import Foundation
import XCTest
@testable import LocalCronKit

final class QuickSearchTests: XCTestCase {
    private let now = ApiDate.parse("2026-11-23T12:00:00Z")!

    private func job(_ id: String, kind: String = "claude", prompt: String = "Do the work") throws -> JobView {
        let json = #"{"id":"\#(id)","schedule":"@daily","kind":"\#(kind)","prompt":"\#(prompt)","command":"true","dir":"/tmp","enabled":true,"schedule_text":"Every day"}"#
        return try Api.decoder.decode(JobView.self, from: Data(json.utf8))
    }

    private func secret(_ name: String, _ description: String, usedBy: [String] = []) throws -> SecretInfo {
        let users = usedBy.map { "\"\($0)\"" }.joined(separator: ",")
        let json = #"{"name":"\#(name)","description":"\#(description)","updated_at":"2026-11-01T10:00:00Z","state":"ok","used_by":[\#(users)],"set_command":"x"}"#
        return try Api.decoder.decode(SecretInfo.self, from: Data(json.utf8))
    }

    private func search(_ query: String) throws -> [QuickSearch.Item] {
        QuickSearch.search(
            query,
            pages: ["Jobs", "Runs", "Calendar", "Logs", "Chat", "Secrets", "Settings"],
            jobs: [try job("wiki-drafts-to-pages", prompt: "Turn the wiki drafts into pages"),
                   try job("apple-books-charts", kind: "shell"),
                   try job("daily-deal-check", prompt: "Check new deals on Acquire")],
            runs: [makeRun("apple-books-charts.40", .failed, start: "2026-11-23T09:05:00Z", end: "2026-11-23T09:06:00Z", exit: 3),
                   makeRun("apple-books-charts.41", .succeeded, start: "2026-11-23T10:05:00Z", end: "2026-11-23T10:30:00Z", exit: 0)],
            secrets: [try secret("github-token", "GitHub token for the wiki repo", usedBy: ["wiki-drafts-to-pages"])],
            messages: [Message(id: 7, jobId: "daily-deal-check", runId: "daily-deal-check.9", at: "2026-11-23T08:00:00Z",
                               text: "Please sign in to Acquire in Chrome.", read: true)],
            now: now, calendar: utcCalendar)
    }

    func testAnEmptyQueryShowsThePagesAndTheJobs() throws {
        let items = try search("  ")
        XCTAssertEqual(items.filter { $0.section == .pages }.count, 7)
        XCTAssertEqual(items.filter { $0.section == .jobs }.map(\.title), ["wiki-drafts-to-pages", "apple-books-charts", "daily-deal-check"])
        XCTAssertTrue(items.allSatisfy { $0.section == .pages || $0.section == .jobs })
    }

    func testEveryWordMustBeThereInAnyCaseAndTheBestMatchComesFirst() throws {
        let items = try search("BOOKS")
        XCTAssertEqual(items.map(\.target), [.job("apple-books-charts"), .run("apple-books-charts.41"), .run("apple-books-charts.40")],
                       "runs newest first")
        XCTAssertEqual(try search("wiki").map(\.target), [.job("wiki-drafts-to-pages"), .secret("github-token")],
                       "the secret has it only in its description")
        XCTAssertEqual(try search("drafts pages").map(\.target), [.job("wiki-drafts-to-pages"), .secret("github-token")],
                       "a secret is found by the jobs that use it")
        XCTAssertEqual(try search("acquire").map(\.target), [.job("daily-deal-check"), .message(id: 7, jobID: "daily-deal-check")],
                       "a job is found by its prompt")
        XCTAssertEqual(try search("nothing like this"), [])
    }

    func testATitleThatStartsWithTheQueryGoesFirst() throws {
        let items = try search("ch")
        XCTAssertEqual(items.filter { $0.section == .pages }.map(\.title), ["Chat"])
        XCTAssertEqual(items.filter { $0.section == .jobs }.map(\.title).first, "apple-books-charts",
                       "a word of the title starts with it")
    }

    func testARunShowsWhenAndHowItEnded() throws {
        let run = try XCTUnwrap(try search("charts.40").first)
        XCTAssertEqual(run.target, .run("apple-books-charts.40"))
        XCTAssertEqual(run.detail, "Today, Monday 23 November, 09:05 · Failed with exit code 3 after 1 min 0 s")
        XCTAssertEqual(try search("failed").map(\.target), [.run("apple-books-charts.40")])
    }
}

final class ChannelOrderTests: XCTestCase {
    func testChannelsSortByLastRunRunsMessagesOrName() {
        let runs = [makeRun("a.1", .succeeded, start: "2026-11-20T10:00:00Z", end: "2026-11-20T10:01:00Z", exit: 0),
                    makeRun("a.2", .succeeded, start: "2026-11-21T10:00:00Z", end: "2026-11-21T10:01:00Z", exit: 0),
                    makeRun("a.3", .succeeded, start: "2026-11-21T11:00:00Z", end: "2026-11-21T11:01:00Z", exit: 0),
                    makeRun("b.1", .succeeded, start: "2026-11-22T10:00:00Z", end: "2026-11-22T10:01:00Z", exit: 0),
                    makeRun("c.1", .running, start: "2026-11-19T10:00:00Z")]
        let messages = [Message(id: 1, jobId: "c", runId: "c.1", at: "2026-11-19T10:00:10Z", text: "x", read: true),
                        Message(id: 2, jobId: "c", runId: "c.1", at: "2026-11-23T10:00:10Z", text: "y", read: true),
                        Message(id: 3, jobId: "b", runId: "b.1", at: "2026-11-22T10:00:10Z", text: "z", read: false)]
        func order(_ o: Chat.Order) -> [String] {
            Chat.channels(messages, runs: runs, jobIDs: ["a", "b", "c", "d"], order: o).map(\.jobID)
        }
        XCTAssertEqual(order(.activity), ["c", "b", "a", "d"], "running first, then the newest run or message")
        XCTAssertEqual(order(.lastRun), ["b", "a", "c", "d"], "c's message is newer, but its run is older")
        XCTAssertEqual(order(.runs), ["a", "b", "c", "d"])
        XCTAssertEqual(order(.messages), ["c", "b", "a", "d"])
        XCTAssertEqual(order(.name), ["a", "b", "c", "d"])
        let a = Chat.channels(messages, runs: runs, jobIDs: ["a"]).first { $0.jobID == "a" }
        XCTAssertEqual(a?.runs, 3)
        XCTAssertEqual(a?.messages, 0)
        XCTAssertEqual(a?.lastRun, ApiDate.parse("2026-11-21T11:00:00Z"))
    }

    func testAShortAgeFitsANarrowColumn() {
        let now = ApiDate.parse("2026-11-23T12:00:00Z")!
        XCTAssertEqual([30.0, 300, 3 * 3600, 2 * 86400, 20 * 86400].map { Chat.shortAge(now.addingTimeInterval(-$0), now: now) },
                       ["now", "5m", "3h", "2d", "2w"])
    }
}
