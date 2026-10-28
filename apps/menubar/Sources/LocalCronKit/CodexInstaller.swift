// "Add to Codex" does two things:
//   1. The note: a symlink in Codex home into the app bundle, and a line in
//      AGENTS.md that tells Codex to read it. Codex has no @file import.
//   2. The MCP server: a `[mcp_servers.localcron]` table at the end of
//      config.toml, added only when the file has no such table. The rest of
//      the file stays byte for byte.

import Foundation

public struct CodexInstaller {
    public enum Outcome: Equatable {
        /// `instructionAdded` and `serverAdded` are false when the files
        /// already had them.
        case installed(link: URL, agentsMD: URL, instructionAdded: Bool, configTOML: URL, serverAdded: Bool)
        /// There is no Codex home folder, so nothing was done.
        case noCodex(URL)
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case noteMissing(URL)
        case occupied(URL)
        case io(String)

        public var errorDescription: String? {
            switch self {
            case let .noteMissing(url): "The Codex note is missing from the app: \(url.path)"
            case let .occupied(url): "\(url.path) already exists and is not a LocalCron link. Remove it first."
            case let .io(text): text
            }
        }
    }

    /// An absolute path: Codex may be working in any project.
    public var instructionLine: String {
        "When the user asks to run something later or on a schedule, read and follow the instructions in `\(link.path)` if that file exists."
    }

    public var note: URL
    public var codexDir: URL
    public var instance: Instance

    /// The note of the running app and Codex home.
    public init(bundle: Bundle = .main, instance: Instance = .current,
                codexDir: URL = CodexInstaller.defaultDirectory()) {
        self.note = bundle.bundleURL.appendingPathComponent(BundleLayout.claudeNote)
        self.codexDir = codexDir
        self.instance = instance
    }

    public init(note: URL, codexDir: URL, instance: Instance = .current) {
        self.note = note
        self.codexDir = codexDir
        self.instance = instance
    }

    public var link: URL { codexDir.appendingPathComponent(instance.note) }
    public var configTOML: URL { codexDir.appendingPathComponent("config.toml") }

    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }

    /// Codex loads only the first non-empty global instruction file.
    public func instructionsFile() throws -> URL {
        let override = codexDir.appendingPathComponent("AGENTS.override.md")
        if !((try read(override)).trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty {
            return override
        }
        return codexDir.appendingPathComponent("AGENTS.md")
    }

    /// Read both files before changing anything, so a file that cannot be
    /// read stops the install before the link is made.
    public func install(commandPath: String) throws -> Outcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: codexDir.path, isDirectory: &isDir), isDir.boolValue else {
            return .noCodex(codexDir)
        }
        guard fm.fileExists(atPath: note.path) else { throw Failure.noteMissing(note) }
        let agents = try instructionsFile()
        let existingAgents = try read(agents)
        let existingConfig = try read(configTOML)
        try linkNote()
        let instructionAdded = try write(agents, Self.withInstruction(existingAgents, line: instructionLine))
        let serverAdded = try write(configTOML, Self.withMCPServer(existingConfig, name: instance.cli, command: commandPath))
        return .installed(link: link, agentsMD: agents, instructionAdded: instructionAdded, configTOML: configTOML,
                          serverAdded: serverAdded)
    }

    /// Remove our link. The instruction and the server table stay in the
    /// user's files; the instruction says "if that file exists".
    public func uninstall() {
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), Self.isOurNote(dest) {
            try? FileManager.default.removeItem(at: link)
        }
    }

    static func isOurNote(_ path: String) -> Bool {
        path.hasSuffix("/" + BundleLayout.claudeNote)
    }

    private func linkNote() throws {
        let fm = FileManager.default
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

    private func read(_ url: URL) throws -> String {
        do {
            return try String(contentsOf: url.resolvingSymlinksInPath(), encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        } catch {
            throw Failure.io("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Writes `text` unless it is nil. Returns true when it wrote.
    private func write(_ url: URL, _ text: String?) throws -> Bool {
        guard let text else { return false }
        do {
            // Keep a user's symlink into a dotfiles repository.
            try Data(text.utf8).write(to: url.resolvingSymlinksInPath(), options: .atomic)
        } catch {
            throw Failure.io("cannot update \(url.path): \(error.localizedDescription)")
        }
        return true
    }

    static func withInstruction(_ existing: String, line: String) -> String? {
        if existing.split(separator: "\n", omittingEmptySubsequences: false)
            .contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) {
            return nil
        }
        return line + "\n\n" + existing
    }

    /// True when config.toml has a table for this server, also one of its
    /// sub-tables such as `[mcp_servers.localcron.env]`.
    static func hasMCPServer(_ toml: String, name: String) -> Bool {
        let heads = ["[mcp_servers.\(name)]", "[mcp_servers.\"\(name)\"]"]
        let prefixes = ["[mcp_servers.\(name).", "[mcp_servers.\"\(name)\"."]
        return toml.split(separator: "\n", omittingEmptySubsequences: false).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            return heads.contains { line.hasPrefix($0) } || prefixes.contains { line.hasPrefix($0) }
        }
    }

    /// config.toml with the server table added at the end, or nil when the
    /// file already has one.
    static func withMCPServer(_ existing: String, name: String, command: String) -> String? {
        if hasMCPServer(existing, name: name) { return nil }
        var text = existing
        if !text.isEmpty {
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n"
        }
        text += "[mcp_servers.\(name)]\ncommand = \(tomlString(command))\nargs = [\"mcp\"]\n"
        return text
    }

    /// A TOML basic string.
    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
