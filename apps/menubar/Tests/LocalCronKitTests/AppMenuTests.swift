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
                         waiting: [AppMenu.WaitingJob] = [], daemon: Bool = true) -> AppMenu.Context {
        AppMenu.Context(appName: "LocalCron", cliInstalled: false, summary: daemon ? "2 jobs" : nil, paused: paused,
                        running: running, failed: failed, waiting: waiting)
    }

    func testEntries() {
        let entries = AppMenu.entries(.init(appName: "LocalCron", cliInstalled: true, summary: "2 jobs"))
        guard case let .item(first) = entries.first else { return XCTFail("no first item") }
        XCTAssertEqual(first.title, "Open LocalCron")
        XCTAssertEqual(first.detail, "2 jobs")
        let actions = entries.compactMap { if case let .item(i) = $0 { i.action } else { nil } }
        for needed: AppMenu.Action in [.installClaude, .installCodex, .installCLI, .openHelp, .checkForUpdates, .quit] {
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

    func testAJobWaitingForSecretsIsOfferedNearTheTopAndNotAsAFailure() {
        let waiting = AppMenu.WaitingJob(jobID: "deploy", secrets: ["github-token", "npm-token"])
        let failed = [AppMenu.RunEntry(runID: "deploy.1", jobID: "deploy", detail: "Failed"),
                      AppMenu.RunEntry(runID: "nightly.4", jobID: "nightly", detail: "exit 2")]
        let entries = AppMenu.entries(context(failed: failed, waiting: [waiting]))
        XCTAssertEqual(Array(titles(entries).prefix(5)),
                       ["Open LocalCron", "New Job…", "Pause All Jobs", "# Waiting for your OK", "Allow Secrets for deploy…"])
        let items = entries.compactMap { if case let .item(i) = $0 { i } else { nil } }
        let allow = items.first { $0.action == .allowSecrets("deploy") }
        XCTAssertEqual(allow?.detail, "Reads github-token, npm-token; runs fail until you allow it")
        XCTAssertFalse(items.contains { $0.title == "deploy" }, "listed again as a failure")
        XCTAssertTrue(items.contains { $0.title == "nightly" })
        XCTAssertFalse(titles(AppMenu.entries(context())).contains("# Waiting for your OK"))
    }

    func testARunInAConsoleCanBeOpenedFromTheMenu() {
        let console = AppMenu.RunEntry(runID: "learn.3", jobID: "learn", detail: "running for 2 min", console: true)
        let plain = AppMenu.RunEntry(runID: "backup.9", jobID: "backup", detail: "running for 1 min")
        let items = AppMenu.entries(context(running: [console, plain])).compactMap { if case let .item(i) = $0 { i } else { nil } }
        XCTAssertEqual(items.first { $0.title == "Open Terminal for learn" }?.action, .openTerminal("learn.3"))
        XCTAssertFalse(items.contains { $0.title == "Open Terminal for backup" }, "a run without a console")
    }

    func testTheConsoleOpensInKittyWhenItIsThere() {
        XCTAssertEqual(ConsoleTerminal.chosen(saved: nil, kittyInstalled: true), .kitty)
        XCTAssertEqual(ConsoleTerminal.chosen(saved: nil, kittyInstalled: false), .terminal)
        XCTAssertEqual(ConsoleTerminal.chosen(saved: "terminal", kittyInstalled: true), .terminal)
        XCTAssertEqual(ConsoleTerminal.chosen(saved: "kitty", kittyInstalled: false), .terminal, "kitty was removed")
        XCTAssertEqual(ConsoleTerminal.kittyArguments(command: "/opt/homebrew/bin/tmux -L localcron-learn attach", runID: "learn.3"),
                       ["--title", "learn.3 console", "/bin/sh", "-c", "exec /opt/homebrew/bin/tmux -L localcron-learn attach"])
    }
}
