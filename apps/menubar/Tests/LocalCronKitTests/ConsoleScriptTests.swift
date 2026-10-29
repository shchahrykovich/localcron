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
}
