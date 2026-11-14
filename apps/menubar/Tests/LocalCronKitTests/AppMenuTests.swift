import Foundation
import XCTest
@testable import LocalCronKit

final class AppMenuTests: XCTestCase {
    private func titles(_ entries: [AppMenu.Entry]) -> [String] {
        entries.compactMap {
            switch $0 {
            case let .item(item): item.title
            case let .header(title): "# \(title)"
            case let .submenu(title, _, _, _): "\(title) ▸"
            case .separator: nil
            }
        }
    }

    /// Every item, also those in submenus.
    private func allItems(_ entries: [AppMenu.Entry]) -> [AppMenu.Item] {
        entries.flatMap { entry -> [AppMenu.Item] in
            switch entry {
            case let .item(item): [item]
            case let .submenu(_, _, _, children): allItems(children)
            default: []
            }
        }
    }

    private func submenu(_ title: String, in entries: [AppMenu.Entry]) -> (detail: String?, entries: [AppMenu.Entry])? {
        for case let .submenu(t, _, detail, children) in entries where t == title { return (detail, children) }
        return nil
    }

    private func context(paused: Bool = false, failed: [AppMenu.RunEntry] = [],
                         waiting: [AppMenu.WaitingJob] = [], jobIDs: [String] = [],
                         daemon: Bool = true) -> AppMenu.Context {
        AppMenu.Context(appName: "LocalCron", cliInstalled: false, summary: daemon ? "2 jobs" : nil, paused: paused,
                        failed: failed, waiting: waiting, jobIDs: jobIDs)
    }

    func testEntries() {
        let entries = AppMenu.entries(.init(appName: "LocalCron", cliInstalled: true, summary: "2 jobs"))
        guard case let .item(first) = entries.first else { return XCTFail("no first item") }
        XCTAssertEqual(first.title, "Open LocalCron")
        XCTAssertEqual(first.detail, "2 jobs")
        let actions = allItems(entries).map(\.action)
        for needed: AppMenu.Action in [.installClaude, .installCodex, .installCLI, .openHelp, .checkForUpdates, .quit] {
            XCTAssertTrue(actions.contains(needed), "\(needed)")
        }
        XCTAssertNotNil(submenu("Coding Agents", in: entries), "the agent commands are one submenu")
        XCTAssertTrue(titles(entries).contains("Help"), "not \"LocalCron Help\"")
    }

    func testTheMenuDoesNotListRunningOrNextRuns() throws {
        // The popover and the Runs window show them; the menu only offers to run a job.
        let entries = AppMenu.entries(context(jobIDs: ["nightly-tests", "pr-review"]))
        let list = titles(entries)
        for gone in ["# Working now", "Stop a", "Stop All Runs", "Open Terminal for a", "# Next to run", "pr-review ▸"] {
            XCTAssertFalse(list.contains(gone), gone)
        }
        let any = try XCTUnwrap(submenu("Run a Job Now", in: entries))
        XCTAssertEqual(allItems(any.entries).map(\.action), [.runNow("nightly-tests"), .runNow("pr-review")])
        XCTAssertNil(submenu("Run a Job Now", in: AppMenu.entries(context(daemon: false))))
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

    func testTheConsoleOpensInKittyWhenItIsThere() {
        XCTAssertEqual(ConsoleTerminal.chosen(saved: nil, kittyInstalled: true), .kitty)
        XCTAssertEqual(ConsoleTerminal.chosen(saved: nil, kittyInstalled: false), .terminal)
        XCTAssertEqual(ConsoleTerminal.chosen(saved: "terminal", kittyInstalled: true), .terminal)
        XCTAssertEqual(ConsoleTerminal.chosen(saved: "kitty", kittyInstalled: false), .terminal, "kitty was removed")
        XCTAssertEqual(ConsoleTerminal.kittyArguments(command: "/opt/homebrew/bin/tmux -L localcron-learn attach", runID: "learn.3"),
                       ["--title", "learn.3 console", "/bin/sh", "-c", "exec /opt/homebrew/bin/tmux -L localcron-learn attach"])
    }
}
