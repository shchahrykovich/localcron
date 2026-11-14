import Foundation
import XCTest
@testable import LocalCronKit

final class ConsoleScriptTests: XCTestCase {
    func testTheScriptExecsTheConsoleCommand() throws {
        let command = "/opt/homebrew/bin/tmux -L localcron-weekly.3 attach -t run"
        let text = ConsoleScript.text(runID: "weekly.3", command: command)
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(text.contains("\nexec \(command)\n"), text)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ConsoleScript.write(runID: "weekly/../x.3", command: command, in: dir)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL, "stays in its folder")
        XCTAssertEqual(url.pathExtension, "command")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path))
    }

    func testARunDecodesItsConsole() throws {
        let json = #"{"id":"a.1","job_id":"a","trigger":"manual","status":"running","queued_at":"2026-10-29T14:00:00Z","console":"/opt/homebrew/bin/tmux -L localcron-a.1 attach -t run"}"#
        let run = try Api.decoder.decode(Run.self, from: Data(json.utf8))
        XCTAssertEqual(run.console, "/opt/homebrew/bin/tmux -L localcron-a.1 attach -t run")
        XCTAssertTrue(String(decoding: try Api.encoder.encode(run), as: UTF8.self).contains("\"console\""))
    }

    func testResumeOpensTheSessionInTheLoginShell() {
        let id = "4abdcd7d-1dc4-4dad-a53d-a3cee0a3d889"
        XCTAssertEqual(ConsoleScript.resumeCommand(session: id, shell: "/bin/zsh"),
                       "'/bin/zsh' -lic 'claude --resume \(id)'")
        XCTAssertNil(ConsoleScript.resumeCommand(session: "x'; rm -rf ~", shell: "/bin/zsh"), "only a session id")
    }

    func testAScriptWithAFolderGoesThereFirst() {
        let text = ConsoleScript.text(runID: "a.1", command: "claude", dir: "/Users/me/it's here", note: "Resume a.1")
        XCTAssertTrue(text.contains("\n# Resume a.1\ncd -- '/Users/me/it'\\''s here' || exit 1\nexec claude\n"), text)
        XCTAssertFalse(ConsoleScript.text(runID: "a.1", command: "x").contains("cd --"))
    }

    func testKittyStartsInTheFolder() {
        XCTAssertEqual(ConsoleTerminal.kittyArguments(command: "claude", runID: "a.1", title: "a.1 resume", dir: "/tmp/x"),
                       ["--title", "a.1 resume", "--directory", "/tmp/x", "/bin/sh", "-c", "exec claude"])
    }
}
