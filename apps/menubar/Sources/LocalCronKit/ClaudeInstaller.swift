// "Add to Claude Code" does two things:
//   1. The note: a symlink ~/.claude/LocalCron.md into the app bundle, and one
//      line `@LocalCron.md` at the top of ~/.claude/CLAUDE.md, so every session
//      knows LocalCron exists and when to use it.
//   2. The MCP server: `claude mcp add --scope user localcron -- <path> mcp`,
//      so every session has the tools. Claude Code owns its config file, so
//      the app asks the `claude` command instead of writing the file.
// Rules, the same as VibeViewer's VV.md and LocalRouter's note:
//   - A link, never a copy: an update of the app updates the note.
//   - A name that is taken is left alone: only a link into some LocalCron
//     bundle is replaced.
//   - No ~/.claude folder means no Claude Code here: nothing is created.
//   - Each instance has its own note, line and server: LocalCron-dev.md,
//     @LocalCron-dev.md and localcron-dev for -dev.

import Foundation

public struct ClaudeInstaller {
    public enum MCPOutcome: Equatable, Sendable {
        case added
        case alreadyPresent
        /// The `claude` command was not found; the user can run `command`.
        case claudeMissing(command: String)
        case failed(command: String, output: String)
    }

    public enum Outcome: Equatable {
        /// The note is linked. `importAdded` is false when CLAUDE.md already
        /// had the line.
        case installed(link: URL, importAdded: Bool, mcp: MCPOutcome)
        /// There is no ~/.claude folder, so nothing was done.
        case noClaude(URL)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noteMissing(URL)
        case occupied(URL)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case let .noteMissing(url): "The Claude Code note is missing from the app: \(url.path)"
            case let .occupied(url): "\(url.path) already exists and is not a LocalCron link. Remove it first."
            case let .io(text): text
            }
        }
    }

    /// The line in CLAUDE.md that imports an instance's note. Claude Code
    /// reads the name relative to the folder CLAUDE.md is in.
    public static func importLine(for instance: Instance) -> String { "@\(instance.note)" }

    public var note: URL
    public var claudeDir: URL
    public var instance: Instance
    public var runner: CommandRunner

    /// The note of the running app and ~/.claude.
    public init(bundle: Bundle = .main, instance: Instance = .current,
                claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
                runner: CommandRunner = LoginShellRunner()) {
        self.init(note: bundle.bundleURL.appendingPathComponent(BundleLayout.claudeNote), claudeDir: claudeDir,
                  instance: instance, runner: runner)
    }

    public init(note: URL, claudeDir: URL, instance: Instance = .current, runner: CommandRunner) {
        self.note = note
        self.claudeDir = claudeDir
        self.instance = instance
        self.runner = runner
    }

    public var importLine: String { Self.importLine(for: instance) }
    public var link: URL { claudeDir.appendingPathComponent(instance.note) }
    public var claudeMD: URL { claudeDir.appendingPathComponent("CLAUDE.md") }

    /// `claude mcp add --scope user localcron -- /Users/me/.local/bin/localcron mcp`
    public func addCommand(commandPath: String) -> [String] {
        ["claude", "mcp", "add", "--scope", "user", instance.cli, "--", commandPath, "mcp"]
    }

    /// Link the note, make sure CLAUDE.md imports it, then register the MCP
    /// server. The line is added only after the link exists: an import of a
    /// missing file would fail in every session.
    public func install(commandPath: String) throws -> Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: claudeDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .noClaude(claudeDir)
        }
        guard fm.fileExists(atPath: note.path) else { throw Failure.noteMissing(note) }
        try linkNote()
        let added = try ensureImport()
        return .installed(link: link, importAdded: added, mcp: registerMCP(commandPath: commandPath))
    }

    /// Ask `claude` whether the server exists; add it when it does not. An
    /// existing server is left as the user set it.
    public func registerMCP(commandPath: String) -> MCPOutcome {
        let add = addCommand(commandPath: commandPath)
        let get = runner.run(["claude", "mcp", "get", instance.cli])
        if get.notFound { return .claudeMissing(command: commandLine(add)) }
        if get.status == 0 { return .alreadyPresent }
        let result = runner.run(add)
        if result.notFound { return .claudeMissing(command: commandLine(add)) }
        if result.status != 0 {
            return .failed(command: commandLine(add), output: result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .added
    }

    /// Remove the link if it is ours, and the MCP server. The line in
    /// CLAUDE.md stays: it is the user's file, and an import of a missing
    /// file does no harm.
    public func uninstall() {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), Self.isOurNote(dest) {
            try? FileManager.default.removeItem(at: link)
        }
        _ = runner.run(["claude", "mcp", "remove", "--scope", "user", instance.cli])
    }

    /// A link into any LocalCron bundle, wherever it is and even if the
    /// bundle is gone, has this shape.
    static func isOurNote(_ path: String) -> Bool {
        path.hasSuffix("/" + BundleLayout.claudeNote)
    }

    private func linkNote() throws {
        let fm = FileManager.default
        // destinationOfSymbolicLink, not fileExists: fileExists follows the
        // link and says "nothing there" for a link into a deleted bundle.
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            if existing == note.path { return }
            guard Self.isOurNote(existing) else { throw Failure.occupied(link) }
            try? fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw Failure.occupied(link)
        }
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: note.path)
        } catch {
            throw Failure.io("cannot link \(link.path): \(error.localizedDescription)")
        }
    }

    /// Returns true when the line was added.
    private func ensureImport() throws -> Bool {
        // CLAUDE.md may be a link into a dotfiles repository. Write the real
        // file, so the link stays.
        let file = claudeMD.resolvingSymlinksInPath()
        let existing: String
        do {
            existing = try String(contentsOf: file, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            existing = ""
        } catch {
            // A file that cannot be read is not an empty file: writing would
            // replace what the user has.
            throw Failure.io("cannot read \(claudeMD.path): \(error.localizedDescription)")
        }
        guard let text = Self.withImport(existing, line: importLine) else { return false }
        do {
            try Data(text.utf8).write(to: file, options: .atomic)
        } catch {
            throw Failure.io("cannot add \(importLine) to \(claudeMD.path): \(error.localizedDescription)")
        }
        return true
    }

    /// CLAUDE.md with the import line added as the first line, or nil when a
    /// line already is the import. The rest of the file follows unchanged.
    static func withImport(_ existing: String, line: String = importLine(for: .release)) -> String? {
        if existing.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            return nil
        }
        return line + "\n" + existing
    }
}
