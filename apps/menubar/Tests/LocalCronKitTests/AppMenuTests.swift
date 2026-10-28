import Foundation
import XCTest
@testable import LocalCronKit

final class AppMenuTests: XCTestCase {
    private func titles(_ entries: [AppMenu.Entry]) -> [String] {
        entries.compactMap {
            switch $0 {
            case let .item(item): item.title
            case let .header(title): "# \(title)"
            default: nil
            }
        }
    }

    private func context(paused: Bool = false, running: [AppMenu.RunEntry] = [], failed: [AppMenu.RunEntry] = [],
                         daemon: Bool = true) -> AppMenu.Context {
        AppMenu.Context(appName: "LocalCron", cliInstalled: false, summary: daemon ? "2 jobs" : nil, paused: paused,
                        running: running, failed: failed)
    }

    func testEntries() {
        let entries = AppMenu.entries(.init(appName: "LocalCron", cliInstalled: true, summary: "2 jobs"))
        guard case let .item(first) = entries.first else { return XCTFail("no first item") }
        XCTAssertEqual(first.title, "Open LocalCron")
        XCTAssertEqual(first.detail, "2 jobs")
        let actions = entries.compactMap { if case let .item(i) = $0 { i.action } else { nil } }
        for needed: AppMenu.Action in [.installClaude, .installCodex, .installCLI, .checkForUpdates, .quit] {
            XCTAssertTrue(actions.contains(needed), "\(needed)")
        }
    }

    func testPauseIsOfferedWhileTheDaemonRuns() {
        let entries = AppMenu.entries(context())
        XCTAssertTrue(titles(entries).contains("Pause All Jobs"))
        XCTAssertFalse(titles(entries).contains("# Running"))
        XCTAssertFalse(titles(AppMenu.entries(context(daemon: false))).contains("Pause All Jobs"))
    }

    func testPausedOffersResume() {
        let items = AppMenu.entries(context(paused: true)).compactMap { if case let .item(i) = $0 { i } else { nil } }
        let resume = items.first { $0.action == .setPaused(false) }
        XCTAssertEqual(resume?.title, "Resume All Jobs")
        XCTAssertFalse(items.contains { $0.action == .setPaused(true) })
    }

    func testEachActiveRunCanBeStoppedAndSeveralAtOnce() {
        let one = AppMenu.RunEntry(runID: "a.1", jobID: "a", detail: "running for 2 min")
        let two = AppMenu.RunEntry(runID: "b.3", jobID: "b", detail: "queued")
        XCTAssertEqual(titles(AppMenu.entries(context(running: [one]))).filter { $0.contains("Stop") || $0.hasPrefix("#") },
                       ["# Running", "Stop a", "# Coding agents"])
        let entries = AppMenu.entries(context(running: [one, two]))
        XCTAssertTrue(titles(entries).contains("Stop All Runs"))
        let items = entries.compactMap { if case let .item(i) = $0 { i } else { nil } }
        XCTAssertEqual(items.first { $0.title == "Stop b" }?.action, .stopRun("b.3"))
    }

    func testFailedRunsOpenTheirLog() {
        let failed = AppMenu.RunEntry(runID: "nightly.4", jobID: "nightly", detail: "exit 2")
        let entries = AppMenu.entries(context(failed: [failed]))
        XCTAssertTrue(titles(entries).contains("# Last run failed"))
        let items = entries.compactMap { if case let .item(i) = $0 { i } else { nil } }
        XCTAssertEqual(items.first { $0.title == "nightly" }?.action, .showLog("nightly.4"))
    }
}
