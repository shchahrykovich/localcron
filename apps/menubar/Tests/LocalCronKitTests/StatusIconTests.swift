import Foundation
import XCTest
@testable import LocalCronKit

final class StatusIconTests: XCTestCase {
    private func status(running: Int = 0, paused: Bool = false) throws -> StatusResult {
        let json = """
        {"daemon_version":"0.1.1","api_version":"1.1","pid":1,"started_at":"2026-10-28T11:02:52Z","jobs":2,
         "enabled_jobs":2,"running":\(running),"queued":0,"max_concurrent":2,"paused":\(paused),
         "data_dir":"/d","logs_dir":"/l"}
        """
        return try Api.decoder.decode(StatusResult.self, from: Data(json.utf8))
    }

    private func job(_ id: String, last: String?) throws -> JobView {
        let lastRun = last.map {
            #","last_run":{"id":"\#(id).1","job_id":"\#(id)","trigger":"schedule","status":"\#($0)","queued_at":"2026-10-28T11:00:00Z"}"#
        } ?? ""
        let json = #"{"id":"\#(id)","schedule":"@daily","kind":"shell","command":"true","dir":"/tmp","schedule_text":"Every day"\#(lastRun)}"#
        return try Api.decoder.decode(JobView.self, from: Data(json.utf8))
    }

    func testAnIdleDaemonShowsThePlainClock() throws {
        let icon = StatusIcon(status: try status(), jobs: [try job("a", last: "succeeded"), try job("b", last: nil)])
        XCTAssertEqual(icon, StatusIcon(symbol: "clock", paused: false, failedJobs: []))
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"), "LocalCron")
    }

    func testPausedAndFailedJobsAddTheirBadges() throws {
        let jobs = [try job("a", last: "failed"), try job("b", last: "timed_out"), try job("c", last: "canceled")]
        let icon = StatusIcon(status: try status(running: 1, paused: true), jobs: jobs)
        XCTAssertEqual(icon.symbol, "clock.arrow.circlepath")
        XCTAssertEqual(icon.running, 1)
        XCTAssertTrue(icon.paused)
        XCTAssertEqual(icon.failedJobs, ["a", "b"], "a canceled run is not a failure")
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"),
                       "LocalCron\n1 run is running.\nPaused: scheduled runs do not start.\nThe last run failed: a, b")
    }

    func testAJobWaitingForSecretsShowsTheWarning() throws {
        var waiting = try job("deploy", last: "failed")
        waiting.secretsAllowed = false
        var allowed = try job("ok", last: nil)
        allowed.secretsAllowed = true
        let icon = StatusIcon(status: try status(), jobs: [waiting, allowed])
        XCTAssertTrue(icon.warning)
        XCTAssertEqual(icon.waitingJobs, ["deploy"])
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"), "LocalCron\nWaiting for your OK to read secrets: deploy")
    }

    func testRunningRunsAddThePlayBadge() throws {
        let icon = StatusIcon(status: try status(running: 2), jobs: [try job("a", last: "succeeded")])
        XCTAssertEqual(icon, StatusIcon(symbol: "clock.arrow.circlepath", running: 2, paused: false, failedJobs: []))
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"), "LocalCron\n2 runs are running.")
    }

    func testNoDaemonShowsOnlyTheProblem() throws {
        let icon = StatusIcon(status: nil, jobs: [try job("a", last: "failed")])
        XCTAssertEqual(icon, StatusIcon(symbol: "clock.badge.exclamationmark", paused: false, failedJobs: []))
        XCTAssertEqual(icon.toolTip(appName: "LocalCron"), "LocalCron\nThe daemon is not running.")
    }
}
