import Foundation
import XCTest
@testable import LocalCronKit

final class ChatTests: XCTestCase {
    private let now = ApiDate.parse("2026-11-22T21:00:00Z")!

    private func message(_ id: UInt64, _ run: String, _ at: String, read: Bool = true) -> Message {
        Message(id: id, jobId: String(run.split(separator: ".")[0]), runId: run, at: at, text: "m\(id)", read: read)
    }

    /// Newest first, as the daemon sends them.
    private lazy var messages: [Message] = [
        message(6, "deps.3", "2026-11-22T20:00:05Z", read: false),
        message(5, "wiki.9", "2026-11-22T19:05:00Z", read: false),
        message(4, "wiki.9", "2026-11-22T19:00:30Z"),
        message(3, "wiki.8", "2026-11-22T18:00:10Z"),
        message(2, "wiki.7", "2026-11-21T10:00:10Z"),
        message(1, "deps.1", "2026-11-21T09:00:10Z"),
    ]

    /// wiki.7 is no longer kept by the daemon; its message is.
    private let runs: [Run] = [
        makeRun("wiki.10", .running, start: "2026-11-22T20:30:00Z"),
        makeRun("deps.3", .succeeded, start: "2026-11-22T20:00:00Z", end: "2026-11-22T20:00:09Z", exit: 0),
        makeRun("wiki.9", .failed, start: "2026-11-22T19:00:00Z", end: "2026-11-22T19:06:00Z", exit: 1),
        makeRun("wiki.8", .succeeded, start: "2026-11-22T18:00:00Z", end: "2026-11-22T18:01:00Z", exit: 0),
        makeRun("deps.1", .succeeded, start: "2026-11-21T09:00:00Z", end: "2026-11-21T09:00:20Z", exit: 0),
    ]

    func testAChannelPerJobWithTheNewestRunOrMessageFirstAndJobsWithNothingLast() {
        let channels = Chat.channels(messages, runs: runs, jobIDs: ["wiki", "deps", "quiet", "idle"])
        XCTAssertEqual(channels.map(\.jobID), ["wiki", "deps", "idle", "quiet"])
        XCTAssertEqual(channels.map(\.unread), [1, 1, 0, 0])
        // wiki.10 started at 20:30, after the newest message of wiki.
        XCTAssertEqual(channels[0].last, ApiDate.parse("2026-11-22T20:30:00Z"))
        XCTAssertNil(channels[3].last)
    }

    func testAJobThatIsGoneStillHasAChannelWhileItsMessagesAreKept() {
        let channels = Chat.channels([message(9, "old.1", "2026-11-20T10:00:00Z")], runs: [], jobIDs: ["wiki"])
        XCTAssertEqual(channels.map(\.jobID), ["old", "wiki"])
    }

    func testEachRunIsAPostWithTheMessagesItSentOldestFirst() {
        let days = Chat.timeline(messages, runs: runs, jobID: "wiki", now: now, calendar: utcCalendar)
        XCTAssertEqual(days.map(\.title), ["Yesterday", "Today, Sunday 22 November"])
        XCTAssertEqual(days[1].groups.map(\.runID), ["wiki.8", "wiki.9", "wiki.10"])
        XCTAssertEqual(days[1].groups.map { $0.messages.map(\.id) }, [[3], [4, 5], []])
        XCTAssertEqual(days[1].groups[1].run?.status, .failed)
        XCTAssertEqual(days[1].groups[1].at, ApiDate.parse("2026-11-22T19:00:00Z"))
    }

    func testMessagesOfARunTheDaemonNoLongerKeepsStillShowWithoutTheRun() {
        let days = Chat.timeline(messages, runs: runs, jobID: "wiki", now: now, calendar: utcCalendar)
        let gone = days[0].groups[0]
        XCTAssertEqual(gone.runID, "wiki.7")
        XCTAssertNil(gone.run)
        XCTAssertEqual(gone.messages.map(\.id), [2])
        XCTAssertEqual(gone.at, ApiDate.parse("2026-11-21T10:00:10Z"))
    }

    func testAllJobsShowsEveryRunInTimeOrder() {
        let days = Chat.timeline(messages, runs: runs, jobID: nil, now: now, calendar: utcCalendar)
        XCTAssertEqual(days[0].groups.map(\.runID), ["deps.1", "wiki.7"])
        XCTAssertEqual(days[1].groups.map(\.runID), ["wiki.8", "wiki.9", "deps.3", "wiki.10"])
    }

    func testTheNewLineGoesAboveThePostWithTheOldestUnreadMessage() {
        XCTAssertEqual(Chat.firstUnread(messages, jobID: "wiki"), 5)
        XCTAssertEqual(Chat.firstUnread(messages, jobID: nil), 5)
        XCTAssertNil(Chat.firstUnread(messages.map { var m = $0; m.read = true; return m }, jobID: nil))
        let days = Chat.timeline(messages, runs: runs, jobID: "wiki", now: now, calendar: utcCalendar)
        XCTAssertEqual(days[1].groups.filter { $0.contains(message: 5) }.map(\.runID), ["wiki.9"])
    }

    func testAMessageWithAnUnreadableTimeIsLeftOut() {
        let bad = [message(9, "x.1", "yesterday")]
        XCTAssertTrue(Chat.channels(bad).isEmpty)
        XCTAssertTrue(Chat.timeline(bad, jobID: nil).isEmpty)
    }

    func testMarkdownLinksAndBoldAreKeptAndLineBreaksStay() {
        let rich = Chat.rich("PR **ready**: [open](https://github.com/a/b/pull/1)\nnext line")
        XCTAssertEqual(String(rich.characters), "PR ready: open\nnext line")
        XCTAssertTrue(rich.runs.contains { $0.link == URL(string: "https://github.com/a/b/pull/1") })
        XCTAssertEqual(String(Chat.rich("a [b").characters), "a [b")
    }
}
