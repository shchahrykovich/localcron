import Foundation
import XCTest
@testable import LocalCronKit

final class ClaudeSessionTests: XCTestCase {
    /// What the session wrote, line by line.
    private final class Wire: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [JSON] = []
        func add(_ data: Data) {
            lock.lock()
            lines.append(JSON.parse(data.dropLast())!)
            lock.unlock()
        }
        func add(_ json: JSON) {
            lock.lock()
            lines.append(json)
            lock.unlock()
        }
        var all: [JSON] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    private func line(_ text: String) -> Data { Data(text.utf8) }

    func testAMessageWaitsForItsResultAndTheRestGoesToTheHandler() async throws {
        let wire = Wire(), seen = Wire()
        let session = ClaudeSession { wire.add($0) }
        session.onMessage = { seen.add($0) }
        async let answer = session.send("hi")
        while wire.all.isEmpty { await Task.yield() }
        XCTAssertEqual(wire.all[0], ["type": "user", "message": ["role": "user", "content": [["type": "text", "text": "hi"]]]])
        session.receive(line: line(#"{"type":"system","subtype":"init","session_id":"s1"}"#))
        session.receive(line: line("not json"))
        session.receive(line: line(#"{"type":"control_response","response":{}}"#))
        session.receive(line: line(#"{"type":"result","subtype":"success","session_id":"s1","result":"Hello"}"#))
        let result = try await answer
        XCTAssertEqual(result["result"]?.string, "Hello")
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(seen.all.map { $0["type"] }, ["system"], "the result and control responses are not handed on")
    }

    func testAMessageWithAPictureSendsItsContentBlocks() async throws {
        let wire = Wire()
        let session = ClaudeSession { wire.add($0) }
        let content: JSON = [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAAA"]],
                             ["type": "text", "text": "see"]]
        async let answer = session.send(content: content)
        while wire.all.isEmpty { await Task.yield() }
        XCTAssertEqual(wire.all[0], ["type": "user", "message": ["role": "user", "content": content]])
        session.receive(line: line(#"{"type":"result","subtype":"success","session_id":"s1","result":"ok"}"#))
        _ = try await answer
    }

    func testAnswersAndAStopAreControlLines() {
        let wire = Wire()
        let session = ClaudeSession { wire.add($0) }
        session.respond(to: "r1", ["behavior": "deny", "message": "no"])
        session.interrupt()
        XCTAssertEqual(wire.all[0], ["type": "control_response",
                                     "response": ["subtype": "success", "request_id": "r1",
                                                  "response": ["behavior": "deny", "message": "no"]]])
        XCTAssertEqual(wire.all[1]["type"], "control_request")
        XCTAssertEqual(wire.all[1]["request"], ["subtype": "interrupt"])
    }

    func testAClosedSessionFailsTheTurnThatWaitsAndEveryLaterOne() async {
        let wire = Wire()
        let session = ClaudeSession { wire.add($0) }
        async let lost = session.send("hi")
        while wire.all.isEmpty { await Task.yield() }
        session.close("Claude stopped: boom")
        do {
            _ = try await lost
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Claude stopped: boom")
        }
        do {
            _ = try await session.send("again")
            XCTFail("a closed session took a message")
        } catch {}
        XCTAssertTrue(session.isClosed)
    }

    func testLinesArriveInPiecesOfAnySize() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"a\":".utf8)), [])
        XCTAssertEqual(buffer.append(Data("1}\n\n{\"b\":2}\n{\"c\"".utf8)).map { String(decoding: $0, as: UTF8.self) },
                       [#"{"a":1}"#, #"{"b":2}"#])
        XCTAssertEqual(buffer.append(Data(":3}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"c":3}"#])
    }

    /// The real process: a shell script stands in for `claude`. It answers
    /// one message, then fails on the second with a reason on stderr.
    func testAProcessAnswersAndItsEndFailsWhatWaits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        read line
        echo '{"type":"system","subtype":"init","session_id":"s9"}'
        echo '{"type":"result","subtype":"success","result":"one"}'
        read line
        echo 'No conversation found' >&2
        exit 1
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let claude = try ClaudeProcess(executable: script, arguments: [], directory: dir, environment: ["PATH": "/usr/bin:/bin"])
        let first = try await claude.session.send("1")
        XCTAssertEqual(first["result"]?.string, "one")
        XCTAssertEqual(claude.session.id, "s9")
        do {
            _ = try await claude.session.send("2")
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Claude stopped: No conversation found")
        }
    }
}

final class ManagerTests: XCTestCase {
    private let t0 = ApiDate.parse("2026-11-22T21:00:00Z")!

    private func text(_ piece: String, message: String = "m1", index: Int = 1) -> JSON {
        ["type": "stream_event", "api_message_id": .string(message), "parent_tool_use_id": .null,
         "event": ["type": "content_block_delta", "index": .number(Double(index)),
                   "delta": ["type": "text_delta", "text": .string(piece)]]]
    }

    private func toolUse(_ id: String, _ name: String, _ input: JSON, parent: JSON = .null) -> JSON {
        ["type": "assistant", "parent_tool_use_id": parent,
         "message": ["content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]]]
    }

    private func toolResult(_ id: String, error: Bool = false) -> JSON {
        ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": .string(id), "is_error": .bool(error)]]]]
    }

    func testTheManagersTextComesInPiecesOfOneBlock() {
        var entries: [ManagerEntry] = []
        for piece in ["There", " are **15", "**"] { Manager.apply(text(piece), at: t0, to: &entries) }
        Manager.apply(text("Next", message: "m2"), at: t0, to: &entries)
        Manager.apply(["type": "assistant", "message": ["content": [["type": "text", "text": "There are **15**"]]]],
                      at: t0, to: &entries)
        Manager.apply(["type": "rate_limit_event"], at: t0, to: &entries)
        Manager.apply(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                                         "delta": ["type": "thinking_delta", "thinking": "hm"]]],
                      at: t0, to: &entries)
        XCTAssertEqual(entries.map(\.text), ["There are **15**", "Next"], "the whole text block is not added a second time")
        XCTAssertEqual(entries.map(\.kind), [.agent, .agent])
    }

    func testAToolShowsWhatItDoesAndHowItEnded() {
        var entries: [ManagerEntry] = []
        Manager.apply(toolUse("t0", "ToolSearch", ["query": "select:x"]), at: t0, to: &entries)
        Manager.apply(toolUse("t1", "mcp__localcron__get_run_log", ["run_id": "deps.3"]), at: t0, to: &entries)
        Manager.apply(toolUse("t2", "Bash", ["command": "ls -la", "description": "List the files"]), at: t0, to: &entries)
        Manager.apply(toolUse("t3", "Read", ["file_path": "/Users/me/shop/notes.md"]), at: t0, to: &entries)
        Manager.apply(toolUse("t4", "Bash", ["command": "ls"], parent: "t9"), at: t0, to: &entries)
        Manager.apply(toolResult("t1"), at: t0, to: &entries)
        Manager.apply(toolResult("t2", error: true), at: t0, to: &entries)
        Manager.apply(toolResult("t0"), at: t0, to: &entries)
        XCTAssertEqual(entries.map(\.text), ["localcron: get_run_log", "List the files", "Read notes.md"],
                       "ToolSearch and a subagent's tools are left out")
        XCTAssertEqual(entries.map(\.status), ["completed", "failed", "pending"])
    }

    func testAPermissionRequestBecomesAQuestionWithItsAnswers() {
        let entry = Manager.permission(["subtype": "can_use_tool", "tool_name": "mcp__localcron__run_job",
                                        "input": ["id": "daily-review"], "tool_use_id": "t9"], at: t0)
        XCTAssertEqual(entry.kind, .permission)
        XCTAssertEqual(entry.id, "ask-t9")
        XCTAssertEqual(entry.status, "mcp__localcron__run_job")
        XCTAssertTrue(entry.text.hasPrefix("Use localcron: run_job?"), entry.text)
        XCTAssertTrue(entry.text.contains("\"id\" : \"daily-review\""), entry.text)
        XCTAssertEqual(entry.options.map(\.name), ["Allow", "Always Allow localcron: run_job Here", "Reject"])
        XCTAssertEqual(entry.options.map(\.allows), [true, true, false])
        let input: JSON = ["id": "daily-review"]
        XCTAssertEqual(Manager.permissionResponse(entry.options[0], input: input), ["behavior": "allow", "updatedInput": input])
        XCTAssertEqual(Manager.permissionResponse(entry.options[2], input: input)["behavior"], "deny")
        XCTAssertEqual(Manager.permissionResponse(nil, input: input)["behavior"], "deny")
    }

    func testAFailedTurnSaysWhy() {
        XCTAssertNil(Manager.failure(["type": "result", "subtype": "success", "is_error": false, "result": "ok"]))
        XCTAssertEqual(Manager.failure(["type": "result", "subtype": "success", "is_error": true, "result": "Credit balance is too low"]),
                       "Credit balance is too low")
        XCTAssertEqual(Manager.failure(["type": "result", "subtype": "error_max_turns"]), "Claude stopped: error max turns.")
        XCTAssertEqual(Manager.failure(["type": "result", "subtype": "error_during_execution", "errors": ["boom"]]), "boom")
    }

    func testClaudeGetsTheStreamTheToolsTheServerAndTheSession() throws {
        let args = Manager.arguments(instructions: "Be the manager.", allowedTools: ["mcp__lc__status", "Read"],
                                     mcpServer: ("lc", "/A/LocalCron.app/Contents/Helpers/lc"), resume: "s1")
        XCTAssertEqual(Array(args.prefix(9)), ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                                               "--include-partial-messages", "--permission-prompt-tool", "stdio"])
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).map { args[$0 + 1] } }
        XCTAssertEqual(value("--append-system-prompt"), "Be the manager.")
        XCTAssertEqual(value("--allowedTools"), "mcp__lc__status,Read")
        XCTAssertEqual(value("--resume"), "s1")
        let config = try XCTUnwrap(value("--mcp-config").flatMap { JSON.parse(Data($0.utf8)) })
        XCTAssertEqual(config, ["mcpServers": ["lc": ["command": "/A/LocalCron.app/Contents/Helpers/lc", "args": ["mcp"]]]])
        let bare = Manager.arguments(instructions: "x", allowedTools: [], mcpServer: nil, resume: nil)
        XCTAssertNil(bare.firstIndex(of: "--resume"))
        XCTAssertNil(bare.firstIndex(of: "--mcp-config"))
        XCTAssertNil(bare.firstIndex(of: "--allowedTools"))
    }

    func testTheInstructionsNameTheJobWithoutItsIconAndTheNote() {
        let job = Job(id: "daily-review", schedule: "0 21 * * *", kind: .claude, prompt: "Review the day", model: "opus",
                      dir: "/Users/me/school", icon: "<svg>big</svg>")
        let text = Manager.instructions(note: "# LocalCron\nthe note", job: job, scheduleText: "At 21:00", jobIDs: [],
                                        server: "localcron")
        XCTAssertTrue(text.contains("channel of the job `daily-review`"))
        XCTAssertTrue(text.contains("\"prompt\" : \"Review the day\""))
        XCTAssertTrue(text.contains("Schedule: At 21:00."))
        XCTAssertFalse(text.contains("<svg>"), "the icon is long and says nothing")
        XCTAssertTrue(text.hasSuffix("# LocalCron\nthe note"))
        let all = Manager.instructions(note: nil, job: nil, scheduleText: nil, jobIDs: ["a", "b"], server: "localcron-dev")
        XCTAssertTrue(all.contains("All jobs channel"))
        XCTAssertTrue(all.contains("- `a`\n- `b`"))
        XCTAssertTrue(all.contains("MCP server `localcron-dev`"))
        XCTAssertEqual(Manager.allowedTools(server: "localcron"), ["mcp__localcron"], "every LocalCron tool, without asking")
        XCTAssertEqual(Manager.allowedTools(server: "localcron-dev"), ["mcp__localcron-dev"])
        XCTAssertTrue(text.contains("without a question to the user"))
    }

    func testAPromptSaysWhichRunItIsAboutAndTheNewestRuns() {
        let failed = makeRun("deps.3", .failed, start: "2026-11-22T20:00:00Z", end: "2026-11-22T20:01:00Z", exit: 2)
        let ok = makeRun("deps.2", .succeeded, start: "2026-11-21T20:00:00Z", end: "2026-11-21T20:01:00Z", exit: 0)
        let text = Manager.prompt("why did it fail?", about: failed, recent: [failed, ok], now: t0)
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("[Now: 2026-11-22T"))
        XCTAssertTrue(lines[1].hasPrefix("[About run deps.3: failed, started 2026-11-22T20:00:00Z, exit 2, Failed with exit code 2"))
        XCTAssertTrue(lines[2].hasPrefix("[Newest runs: deps.2 succeeded"), lines[2])
        XCTAssertFalse(lines[2].contains("deps.3"), "the run it is about is not said twice")
        XCTAssertEqual(lines.last, "why did it fail?")
        XCTAssertEqual(Manager.prompt("hi", about: nil, recent: [], now: t0).components(separatedBy: "\n").count, 3)
    }

    func testAChatIsSavedAndReadBack() throws {
        let chat = ManagerChat(jobID: "deps", sessionID: "s1", entries: [
            ManagerEntry(id: "u1", kind: .user, at: t0, text: "hi", runID: "deps.3"),
            ManagerEntry(id: "a1", kind: .permission, at: t0, text: "Use x?", status: "mcp__lc__run_job",
                         options: Manager.options(for: "mcp__lc__run_job"), choice: "Allow"),
        ], allowed: ["mcp__lc__run_job"])
        let data = try JSONEncoder().encode([Manager.key("deps"): chat, Manager.key(nil): ManagerChat(jobID: nil)])
        let back = try JSONDecoder().decode([String: ManagerChat].self, from: data)
        XCTAssertEqual(back["deps"], chat)
        XCTAssertEqual(back[""]?.entries, [])
        XCTAssertNil(back[""]?.allowed)
    }

    func testAUserMessageKeepsItsFilesAndAnOldSavedEntryStillReads() throws {
        let entry = ManagerEntry(id: "u1", kind: .user, at: t0, text: "look", files: [
            ManagerEntry.File(name: "shot.png", path: "/tmp/shot.png", image: true),
            ManagerEntry.File(name: "notes.txt", path: "/tmp/notes.txt", image: false),
        ])
        let back = try JSONDecoder().decode(ManagerEntry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(back, entry)
        let old = #"{"id":"u0","kind":"user","at":0,"text":"hi","options":[]}"#
        let saved = try JSONDecoder().decode(ManagerEntry.self, from: Data(old.utf8))
        XCTAssertNil(saved.files, "saved before there were files")
        XCTAssertEqual(saved.text, "hi")
    }
}

final class AttachmentTests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    func testAPictureIsKnownByItsExtensionOrItsFirstBytes() {
        XCTAssertEqual(["png", "JPG", "jpeg", "gif", "webp", "tiff", "pdf", ""].map { Attachments.mediaType(forExtension: $0) },
                       ["image/png", "image/jpeg", "image/jpeg", "image/gif", "image/webp", nil, nil, nil])
        XCTAssertEqual(Attachments.mediaType(sniffing: png), "image/png")
        XCTAssertEqual(Attachments.mediaType(sniffing: Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(Attachments.mediaType(sniffing: Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(Attachments.mediaType(sniffing: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(Attachments.mediaType(sniffing: Data("MM\0*".utf8)), "TIFF is turned into PNG first")
        XCTAssertNil(Attachments.mediaType(sniffing: Data()))
    }

    func testPicturesGoAsImageBlocksBeforeTheTextAndOtherFilesAsPaths() {
        let picture = Attachment(name: "shot.png", path: "/tmp/shot.png", mediaType: "image/png", data: png)
        let file = Attachment(name: "report.csv", path: "/Users/me/report.csv")
        XCTAssertEqual(Attachments.content("what is wrong here?", files: [picture, file]), [
            ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": .string(png.base64EncodedString())]],
            ["type": "text", "text": "what is wrong here?\n\nAttached file: /Users/me/report.csv"],
        ])
        XCTAssertEqual(Attachments.content("", files: [picture]).array?.count, 1, "a picture alone needs no text block")
        XCTAssertEqual(Attachments.content("", files: [file]), [["type": "text", "text": "Attached file: /Users/me/report.csv"]])
        XCTAssertEqual(Attachments.content("hi", files: []), [["type": "text", "text": "hi"]])
        XCTAssertEqual(picture.saved, ManagerEntry.File(name: "shot.png", path: "/tmp/shot.png", image: true))
        XCTAssertFalse(file.isImage)
    }
}

final class ChatTalkTests: XCTestCase {
    private let now = ApiDate.parse("2026-11-22T21:00:00Z")!

    private func entry(_ id: String, _ kind: ManagerEntry.Kind, _ at: String, _ text: String = "x") -> ManagerEntry {
        ManagerEntry(id: id, kind: kind, at: ApiDate.parse(at)!, text: text)
    }

    func testTheConversationGoesBetweenTheRunsByTimeAndJoinsPostsOfOneAuthor() {
        let runs = [makeRun("deps.1", .succeeded, start: "2026-11-22T10:00:00Z", end: "2026-11-22T10:01:00Z", exit: 0),
                    makeRun("deps.2", .succeeded, start: "2026-11-22T10:05:00Z", end: "2026-11-22T10:06:00Z", exit: 0),
                    makeRun("deps.3", .failed, start: "2026-11-22T12:00:00Z", end: "2026-11-22T12:00:05Z", exit: 1)]
        let talk = [entry("u1", .user, "2026-11-22T12:10:00Z", "why?"),
                    entry("u2", .user, "2026-11-22T12:10:20Z", "and fix it"),
                    entry("a1", .agent, "2026-11-22T12:10:40Z"),
                    entry("t1", .tool, "2026-11-22T12:10:50Z"),
                    entry("a2", .agent, "2026-11-22T12:11:00Z"),
                    entry("u3", .user, "2026-11-22T12:30:00Z")]
        let day = Chat.timeline([], runs: runs, talk: talk, jobID: "deps", now: now, calendar: utcCalendar)[0]
        XCTAssertEqual(day.groups.map(\.id), ["deps.1", "deps.2", "deps.3", "talk-u1", "talk-a1", "talk-u3"])
        XCTAssertEqual(day.groups.map(\.author), [.job, .job, .job, .user, .manager, .user])
        XCTAssertEqual(day.groups[3].talk.map(\.id), ["u1", "u2"])
        XCTAssertEqual(day.groups[4].talk.map(\.id), ["a1", "t1", "a2"])
        XCTAssertEqual(day.groups.map(\.continues), [false, true, false, false, false, false],
                       "deps.2 is 4 minutes after deps.1; deps.3 is two hours later; u3 is 19 minutes after u2")
    }

    func testRunsOfOtherJobsDoNotJoin() {
        let runs = [makeRun("deps.1", .succeeded, start: "2026-11-22T10:00:00Z", end: "2026-11-22T10:01:00Z", exit: 0),
                    makeRun("wiki.1", .succeeded, start: "2026-11-22T10:02:00Z", end: "2026-11-22T10:03:00Z", exit: 0),
                    makeRun("wiki.2", .succeeded, start: "2026-11-22T10:04:00Z", end: "2026-11-22T10:05:00Z", exit: 0)]
        let day = Chat.timeline([], runs: runs, jobID: nil, now: now, calendar: utcCalendar)[0]
        XCTAssertEqual(day.groups.map(\.continues), [false, false, true])
    }

    func testSearchKeepsThePostsWhoseTextHasTheWords() {
        let runs = [makeRun("deps.1", .succeeded, start: "2026-11-21T10:00:00Z", end: "2026-11-21T10:01:00Z", exit: 0),
                    makeRun("deps.2", .failed, start: "2026-11-22T10:00:00Z", end: "2026-11-22T10:01:00Z", exit: 7)]
        let messages = [Message(id: 1, jobId: "deps", runId: "deps.1", at: "2026-11-21T10:00:30Z", text: "Disk is FULL", read: true)]
        let talk = [entry("u1", .user, "2026-11-22T11:00:00Z", "is the disk full again?"),
                    entry("a1", .agent, "2026-11-22T11:00:10Z", "No.")]
        func ids(_ query: String) -> [String] {
            Chat.timeline(messages, runs: runs, talk: talk, jobID: "deps", query: query, now: now, calendar: utcCalendar)
                .flatMap(\.groups).map(\.id)
        }
        XCTAssertEqual(ids("disk is full"), ["deps.1"])
        XCTAssertEqual(ids("no such words"), [])
        XCTAssertEqual(ids("  full "), ["deps.1", "talk-u1"])
        XCTAssertEqual(ids("exit code 7"), ["deps.2"])
        XCTAssertEqual(ids("deps.1"), ["deps.1"])
        XCTAssertEqual(ids(""), ["deps.1", "deps.2", "talk-u1", "talk-a1"])
    }
}
