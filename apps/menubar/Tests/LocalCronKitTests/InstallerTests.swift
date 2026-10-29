import Foundation
import XCTest
@testable import LocalCronKit

/// Records commands and answers with prepared results. A real `claude` is
/// never started.
final class FakeRunner: CommandRunner {
    var calls: [[String]] = []
    var answers: [String: CommandOutput] = [:]

    func run(_ argv: [String]) -> CommandOutput {
        calls.append(argv)
        // Keyed by the first three words: "claude mcp get".
        return answers[argv.prefix(3).joined(separator: " ")] ?? CommandOutput(status: 0, output: "")
    }
}

class TempDirTestCase: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A fake bundle with the note and the CLI.
    func makeBundle() throws -> URL {
        let app = root.appendingPathComponent("LocalCron.app")
        let note = app.appendingPathComponent(BundleLayout.claudeNote)
        let cli = app.appendingPathComponent(BundleLayout.cli(for: .release))
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# LocalCron\n".write(to: note, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return app
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}

final class InstanceTests: XCTestCase {
    func testNames() throws {
        let dev = try Instance(suffix: "-dev")
        XCTAssertEqual(dev.appName, "LocalCron-dev")
        XCTAssertEqual(dev.bundleID, "dev.localcron.app-dev")
        XCTAssertEqual(dev.daemonLabel, "dev.localcron.app-dev.daemon")
        XCTAssertEqual(dev.daemonProgram, "localcrond-dev")
        XCTAssertEqual(dev.cli, "localcron-dev")
        XCTAssertEqual(dev.note, "LocalCron-dev.md")
        XCTAssertEqual(dev.dataFolder, "Library/Application Support/LocalCron-dev")
        XCTAssertEqual(dev.logsFolder, "Library/Logs/LocalCron-dev")
        XCTAssertEqual(Instance.release.cli, "localcron")
        XCTAssertEqual(BundleLayout.cli(for: dev), "Contents/Helpers/localcron-dev")
        XCTAssertEqual(BundleLayout.daemon(for: dev), "Contents/MacOS/localcrond-dev")
        XCTAssertEqual(Instance.infoKey, "LCInstanceSuffix")
    }

    func testBadSuffixes() {
        for bad in ["dev", "-", "-Dev", "-dev_1", "-0123456789abcdef"] {
            XCTAssertThrowsError(try Instance(suffix: bad), bad)
        }
    }

    func testPaths() throws {
        let home = URL(fileURLWithPath: "/Users/me")
        let p = Paths.resolve(instance: try Instance(suffix: "-dev"), localHome: nil, home: home)
        XCTAssertEqual(p.data.path, "/Users/me/Library/Application Support/LocalCron-dev")
        let t = Paths.resolve(instance: .release, localHome: "/tmp/x", home: home)
        XCTAssertEqual(t.logs.path, "/tmp/x/logs")
    }
}

final class CLILinkTests: TempDirTestCase {
    func testLinksAndPrefersTheLinkForMCP() throws {
        let app = try makeBundle()
        let tool = app.appendingPathComponent(BundleLayout.cli(for: .release))
        let bin = root.appendingPathComponent("bin")
        let installer = CLIInstaller(tool: tool, binDir: bin, pathVariable: bin.path, instance: .release)
        XCTAssertEqual(installer.commandPath, tool.path)
        XCTAssertEqual(try installer.install(), .installed(link: bin.appendingPathComponent("localcron"), onPath: true))
        XCTAssertEqual(installer.commandPath, bin.appendingPathComponent("localcron").path)
        // Again: nothing changes.
        XCTAssertEqual(try installer.install(), .installed(link: bin.appendingPathComponent("localcron"), onPath: true))
        installer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.link.path))
    }

    func testAForeignFileIsLeftAlone() throws {
        let app = try makeBundle()
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "mine".write(to: bin.appendingPathComponent("localcron"), atomically: true, encoding: .utf8)
        let installer = CLIInstaller(tool: app.appendingPathComponent(BundleLayout.cli(for: .release)), binDir: bin,
                                     pathVariable: "", instance: .release)
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(try read(bin.appendingPathComponent("localcron")), "mine")
    }
}

final class ClaudeInstallerTests: TempDirTestCase {
    private func installer(_ runner: FakeRunner) throws -> ClaudeInstaller {
        let claude = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        return ClaudeInstaller(note: try makeBundle().appendingPathComponent(BundleLayout.claudeNote), claudeDir: claude,
                               instance: .release, runner: runner)
    }

    func testLinksTheNoteImportsItAndAddsTheServer() throws {
        let runner = FakeRunner()
        runner.answers["claude mcp get"] = CommandOutput(status: 1, output: "No MCP server found")
        let i = try installer(runner)
        try "# Mine\n".write(to: i.claudeMD, atomically: true, encoding: .utf8)
        let outcome = try i.install(commandPath: "/Users/me/.local/bin/localcron")
        XCTAssertEqual(outcome, .installed(link: i.link, importAdded: true, mcp: .added))
        XCTAssertEqual(try read(i.claudeMD), "@LocalCron.md\n# Mine\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: i.link.path), i.note.path)
        XCTAssertEqual(runner.calls, [
            ["claude", "mcp", "get", "localcron"],
            ["claude", "mcp", "add", "--scope", "user", "localcron", "--", "/Users/me/.local/bin/localcron", "mcp"],
        ])
        // Again: the import is not added twice.
        runner.answers["claude mcp get"] = CommandOutput(status: 0, output: "localcron: …")
        XCTAssertEqual(try i.install(commandPath: "/x"), .installed(link: i.link, importAdded: false, mcp: .alreadyPresent))
        XCTAssertEqual(try read(i.claudeMD), "@LocalCron.md\n# Mine\n")
    }

    func testAnExistingServerIsNotAddedAgain() throws {
        let runner = FakeRunner()
        let i = try installer(runner)
        XCTAssertEqual(i.registerMCP(commandPath: "/x"), .alreadyPresent)
        XCTAssertEqual(runner.calls, [["claude", "mcp", "get", "localcron"]])
    }

    func testMissingClaudeGivesTheCommandToCopy() throws {
        let runner = FakeRunner()
        runner.answers["claude mcp get"] = CommandOutput(status: 127, output: "zsh: command not found: claude")
        let i = try installer(runner)
        XCTAssertEqual(i.registerMCP(commandPath: "/Users/me/my tools/localcron"),
                       .claudeMissing(command: "claude mcp add --scope user localcron -- '/Users/me/my tools/localcron' mcp"))
    }

    func testAFailedAddIsReported() throws {
        let runner = FakeRunner()
        runner.answers["claude mcp get"] = CommandOutput(status: 1, output: "")
        runner.answers["claude mcp add"] = CommandOutput(status: 1, output: "boom\n")
        let i = try installer(runner)
        guard case let .failed(_, output) = i.registerMCP(commandPath: "/x") else { return XCTFail("not failed") }
        XCTAssertEqual(output, "boom")
    }

    func testNoClaudeFolderDoesNothing() throws {
        let runner = FakeRunner()
        let i = ClaudeInstaller(note: try makeBundle().appendingPathComponent(BundleLayout.claudeNote),
                                claudeDir: root.appendingPathComponent("missing"), instance: .release, runner: runner)
        XCTAssertEqual(try i.install(commandPath: "/x"), .noClaude(root.appendingPathComponent("missing")))
        XCTAssertEqual(runner.calls, [])
    }

    func testImportLineIsAddedOnlyOnce() {
        XCTAssertEqual(ClaudeInstaller.withImport(""), "@LocalCron.md\n")
        XCTAssertNil(ClaudeInstaller.withImport("x\n  @LocalCron.md \n"))
        XCTAssertNotNil(ClaudeInstaller.withImport("See @LocalCron.md for jobs.\n"))
    }

    func testShellQuoting() {
        XCTAssertEqual(shellQuote("/a/b-c.d"), "/a/b-c.d")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(shellQuote(""), "''")
        XCTAssertEqual(commandLine(["a", "b c"]), "a 'b c'")
    }
}

final class CodexInstallerTests: TempDirTestCase {
    private func installer() throws -> CodexInstaller {
        let codex = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return CodexInstaller(note: try makeBundle().appendingPathComponent(BundleLayout.claudeNote), codexDir: codex, instance: .release)
    }

    func testAddsTheInstructionAndTheServerOnce() throws {
        let i = try installer()
        let config = "model = \"gpt-5\"\n\n[mcp_servers.kola]\ncommand = \"/k\"\nargs = [\"x\"]"
        try config.write(to: i.configTOML, atomically: true, encoding: .utf8)
        let agents = i.codexDir.appendingPathComponent("AGENTS.md")
        try "# Mine\n".write(to: agents, atomically: true, encoding: .utf8)

        let outcome = try i.install(commandPath: "/Users/me/.local/bin/localcron")
        XCTAssertEqual(outcome, .installed(link: i.link, agentsMD: agents, instructionAdded: true, configTOML: i.configTOML, serverAdded: true))
        XCTAssertEqual(try read(i.configTOML),
                       config + "\n\n[mcp_servers.localcron]\ncommand = \"/Users/me/.local/bin/localcron\"\nargs = [\"mcp\"]\n")
        XCTAssertEqual(try read(agents), i.instructionLine + "\n\n# Mine\n")

        let again = try i.install(commandPath: "/other")
        XCTAssertEqual(again, .installed(link: i.link, agentsMD: agents, instructionAdded: false, configTOML: i.configTOML, serverAdded: false))
        XCTAssertTrue(try read(i.configTOML).hasSuffix("command = \"/Users/me/.local/bin/localcron\"\nargs = [\"mcp\"]\n"))
    }

    func testAnEmptyConfigGetsOnlyTheTable() {
        XCTAssertEqual(CodexInstaller.withMCPServer("", name: "localcron-dev", command: "/a \"b\"\\c"),
                       "[mcp_servers.localcron-dev]\ncommand = \"/a \\\"b\\\"\\\\c\"\nargs = [\"mcp\"]\n")
    }

    func testAnExistingTableIsFound() {
        XCTAssertTrue(CodexInstaller.hasMCPServer("[mcp_servers.localcron]\ncommand = \"x\"", name: "localcron"))
        XCTAssertTrue(CodexInstaller.hasMCPServer("  [mcp_servers.\"localcron\"]", name: "localcron"))
        XCTAssertTrue(CodexInstaller.hasMCPServer("[mcp_servers.localcron.env]\nA = \"1\"", name: "localcron"))
        XCTAssertFalse(CodexInstaller.hasMCPServer("[mcp_servers.localcron-dev]", name: "localcron"))
        XCTAssertFalse(CodexInstaller.hasMCPServer("# [mcp_servers.localcron]", name: "localcron"))
    }

    func testASymlinkedConfigStaysALink() throws {
        let i = try installer()
        let real = root.appendingPathComponent("dotfiles-config.toml")
        try "a = 1\n".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: i.configTOML, withDestinationURL: real)
        _ = try i.install(commandPath: "/x")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: i.configTOML.path))
        XCTAssertTrue(try read(real).contains("[mcp_servers.localcron]"))
    }

    func testNoCodexFolderDoesNothing() throws {
        let i = CodexInstaller(note: try makeBundle().appendingPathComponent(BundleLayout.claudeNote),
                               codexDir: root.appendingPathComponent("none"), instance: .release)
        XCTAssertEqual(try i.install(commandPath: "/x"), .noCodex(root.appendingPathComponent("none")))
    }
}

final class FormattingTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ s: String) -> Date { ApiDate.parse(s)! }

    func testNextRunText() {
        let now = at("2026-10-28T10:00:00Z") // a Wednesday
        XCTAssertEqual(Formatting.next(at("2026-10-28T10:05:00Z"), now: now, calendar: calendar), "in 5 min, 10:05")
        XCTAssertEqual(Formatting.next(at("2026-10-28T17:00:00Z"), now: now, calendar: calendar), "today 17:00")
        XCTAssertEqual(Formatting.next(at("2026-10-29T09:00:00Z"), now: now, calendar: calendar), "tomorrow 09:00")
        XCTAssertEqual(Formatting.next(at("2026-11-02T09:00:00Z"), now: now, calendar: calendar), "in 5 days, Mon 09:00")
        XCTAssertEqual(Formatting.next(at("2026-11-11T09:00:00Z"), now: now, calendar: calendar), "11 Nov 2026 09:00")
        XCTAssertEqual(Formatting.past(at("2026-10-27T09:00:00Z"), now: now, calendar: calendar), "yesterday 09:00")
    }

    func testDurations() {
        XCTAssertEqual(Formatting.duration(0.42), "0.4 s")
        XCTAssertEqual(Formatting.duration(185), "3 min 5 s")
        XCTAssertEqual(Formatting.duration(3720), "1 h 2 min")
    }

    func testArgs() {
        XCTAssertEqual(Formatting.splitArgs("--max-turns 30"), ["--max-turns", "30"])
        XCTAssertEqual(Formatting.splitArgs("--allowedTools \"Bash(git *) Read\""), ["--allowedTools", "Bash(git *) Read"])
        XCTAssertEqual(Formatting.splitArgs("--allowedTools\nBash(git *) Read\n"), ["--allowedTools", "Bash(git *) Read"])
        XCTAssertEqual(Formatting.splitArgs("  "), [])
        XCTAssertEqual(Formatting.joinArgs(["--allowedTools", "Bash(git *)"]), "--allowedTools\nBash(git *)")
        XCTAssertEqual(Formatting.joinArgs(["--max-turns", "30"]), "--max-turns 30")
    }
}

final class JobDraftTests: XCTestCase {
    func testRoundTripThroughTheForm() {
        let job = Job(id: "weekly-review", schedule: "0 9 * * wed", kind: .claude, prompt: "Review PRs", model: "sonnet",
                      permissionMode: "acceptEdits", args: ["--max-turns", "30"], dir: "/Users/me/shop",
                      env: ["A": "1"], secretEnv: ["GH_TOKEN": "github-token"], timeoutSecs: 1800, note: "n")
        var draft = JobDraft(job: job)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.timeoutMinutes, 30)
        XCTAssertEqual(try draft.job().get(), job)
        // Switching to shell drops the agent fields.
        draft.kind = .shell
        draft.command = "make test"
        let shell = try? draft.job().get()
        XCTAssertNil(shell?.prompt)
        XCTAssertNil(shell?.model)
        XCTAssertEqual(shell?.args, [])
        XCTAssertEqual(shell?.command, "make test")
    }

    func testMissingFieldsAreNamed() {
        var draft = JobDraft(home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(draft.dir, "/Users/me")
        guard case let .failure(e) = draft.job() else { return XCTFail("no error") }
        XCTAssertTrue(e.message.contains("id"))
        draft.id = "x"
        guard case let .failure(e2) = draft.job() else { return XCTFail("no error") }
        XCTAssertTrue(e2.message.contains("prompt"))
    }
}
