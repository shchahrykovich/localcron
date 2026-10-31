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
}
