import Foundation
import XCTest
@testable import LocalCronKit

final class StatusIconTests: XCTestCase {
    private func status(running: Int = 0, paused: Bool = false, next: String? = nil) throws -> StatusResult {
        let nextJSON = next.map { #","next":{"job_id":"a","at":"\#($0)"}"# } ?? ""
        let json = """
        {"daemon_version":"0.1.1","api_version":"1.1","pid":1,"started_at":"2026-10-28T11:02:52Z","jobs":2,
         "enabled_jobs":2,"running":\(running),"queued":0,"max_concurrent":2,"paused":\(paused),
         "data_dir":"/d","logs_dir":"/l"\(nextJSON)}
        """
        return try Api.decoder.decode(StatusResult.self, from: Data(json.utf8))
    }

    private func job(_ id: String, last: String?, startedAt: String? = nil) throws -> JobView {
        let lastRun = last.map {
            #","last_run":{"id":"\#(id).1","job_id":"\#(id)","trigger":"schedule","status":"\#($0)","queued_at":"2026-10-28T11:00:00Z"}"#
        } ?? ""
        let active = startedAt.map {
            #","active_run":{"id":"\#(id).2","job_id":"\#(id)","trigger":"manual","status":"running","queued_at":"\#($0)","started_at":"\#($0)"}"#
        } ?? ""
        let json = #"{"id":"\#(id)","schedule":"@daily","kind":"shell","command":"true","dir":"/tmp","schedule_text":"Every day"\#(lastRun)\#(active)}"#
        return try Api.decoder.decode(JobView.self, from: Data(json.utf8))
    }

    private let now = ApiDate.parse("2026-10-30T10:40:00Z")!
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testAnIdleDaemonShowsTheNextTime() throws {
        let icon = StatusIcon(status: try status(next: "2026-10-30T12:00:00Z"), jobs: [try job("a", last: "succeeded")])
        XCTAssertEqual(icon.state, .idle)
        XCTAssertEqual(icon.label(now: now, calendar: utc), "12:00")
        XCTAssertEqual(icon.ringFraction(now: now), 1 - 80.0 / 120, accuracy: 0.001, "1 h 20 min left of 2 hours")
        XCTAssertEqual(StatusIcon(next: now.addingTimeInterval(3 * 86400)).label(now: now, calendar: utc), "Mon")
        XCTAssertEqual(StatusIcon().label(now: now), "", "no next run, no text")
        XCTAssertEqual(StatusIcon(next: now.addingTimeInterval(5 * 3600)).ringFraction(now: now), 0)
    }

    func testAWorkingRunComesFirstAndShowsHowLongItWorks() throws {
        let jobs = [try job("a", last: "failed", startedAt: "2026-10-30T10:37:00Z"), try job("b", last: nil)]
        let icon = StatusIcon(status: try status(running: 1, paused: true), jobs: jobs)
        XCTAssertEqual(icon.state, .working)
        XCTAssertEqual(icon.label(now: now), "3 min")
        XCTAssertEqual(StatusIcon(running: 1, runningSince: now.addingTimeInterval(-7300)).label(now: now), "2 h")
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"),
                       "LocalCron\n1 run is running.\nPaused: scheduled runs do not start.\nThe last run failed: a")
    }

    func testFailedThenWaitingThenPaused() throws {
        let failed = StatusIcon(status: try status(paused: true), jobs: [try job("a", last: "failed"), try job("b", last: "timed_out"),
                                                                          try job("c", last: "canceled")])
        XCTAssertEqual(failed.failedJobs, ["a", "b"], "a canceled run is not a failure")
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.label(now: now), "2 failed")

        var waiting = try job("deploy", last: "failed")
        waiting.secretsAllowed = false
        let icon = StatusIcon(status: try status(paused: true), jobs: [waiting])
        XCTAssertEqual(icon.state, .waiting, "it failed because it waits: it counts as waiting")
        XCTAssertEqual(icon.label(now: now), "1 waits")
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"),
                       "LocalCron\nPaused: scheduled runs do not start.\nWaiting for your OK to read secrets: deploy")

        let paused = StatusIcon(status: try status(paused: true, next: "2026-10-30T12:00:00Z"), jobs: [])
        XCTAssertEqual(paused.state, .paused)
        XCTAssertEqual(paused.label(now: now), "Paused")
        XCTAssertNil(paused.next, "a paused daemon starts no run")
    }

    func testNoDaemonShowsOnlyTheProblem() throws {
        let icon = StatusIcon(status: nil, jobs: [try job("a", last: "failed")])
        XCTAssertEqual(icon, StatusIcon(down: true))
        XCTAssertEqual(icon.state, .down)
        XCTAssertEqual(icon.label(now: now), "Off")
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"), "LocalCron\nThe daemon is not running.")
    }

    func testTheSavedStyleFallsBackToTheClock() {
        XCTAssertEqual(IconStyle.saved("ring"), .ring)
        XCTAssertEqual(IconStyle.saved("text"), .clockText)
        XCTAssertEqual(IconStyle.saved("spiral"), .clock)
        XCTAssertEqual(IconStyle.saved(nil), .clock)
    }

    func testUnreadMessagesComeFromTheStatusAndShowFirstInTheText() throws {
        var s = try status(running: 1, next: "2026-10-30T12:00:00Z")
        s.unreadMessages = 2
        let icon = StatusIcon(status: s, jobs: [try job("a", last: "succeeded", startedAt: "2026-10-30T10:30:00Z")])
        XCTAssertEqual(icon.unreadMessages, 2)
        XCTAssertTrue(icon.attention)
        // The state still says a run works; the dot is drawn on top.
        XCTAssertEqual(icon.state, .working)
        XCTAssertEqual(icon.label(now: now, calendar: utc), "2 messages")
        XCTAssertEqual(StatusIcon(unreadMessages: 1).label(now: now), "1 message")
        XCTAssertTrue(icon.toolTip(appName: "LocalCron", now: now).contains("2 new messages from jobs."))
        // The daemon is down: only that.
        XCTAssertEqual(StatusIcon(down: true, unreadMessages: 1).label(now: now), "Off")
        XCTAssertFalse(StatusIcon().attention)
    }

    func testAJobThatReportedAnErrorCountsAsFailed() throws {
        var view = try job("a", last: "succeeded")
        view.lastRun?.reported = Reported(status: .error, note: "3 files missing", at: "2026-10-30T10:00:00Z")
        let icon = StatusIcon(status: try status(), jobs: [view])
        XCTAssertEqual(icon.state, .failed)
        view.lastRun?.reported?.status = .success
        XCTAssertEqual(StatusIcon(status: try status(), jobs: [view]).state, .idle)
    }

    func testADismissedFailureHidesUntilTheNextOne() throws {
        let jobs = [try job("a", last: "failed"), try job("b", last: "failed")]
        let some = StatusIcon(status: try status(), jobs: jobs, dismissed: ["a.1"])
        XCTAssertEqual(some.failedJobs, ["b"])
        XCTAssertEqual(StatusIcon(status: try status(), jobs: jobs, dismissed: ["a.1", "b.1"]).state, .idle)

        // The next run of a fails again: a new run id, so it shows.
        var again = jobs[0]
        again.lastRun?.id = "a.2"
        XCTAssertEqual(StatusIcon(status: try status(), jobs: [again, jobs[1]], dismissed: ["a.1", "b.1"]).failedJobs, ["a"])
    }

    func testDismissedRunsKeepOnlyTheLastRunsOfJobs() throws {
        var a = try job("a", last: "succeeded")
        a.lastRun?.id = "a.2"
        let kept = DismissedFailures.prune(["a.1", "b.1", "gone.7"], jobs: [a, try job("b", last: "failed")])
        XCTAssertEqual(kept, ["b.1"], "a.1 is no longer the last run; gone.7 belongs to no job")
        XCTAssertEqual(DismissedFailures.ids(of: [a, try job("b", last: "failed"), try job("c", last: "timed_out")]), ["b.1", "c.1"])
    }
}
