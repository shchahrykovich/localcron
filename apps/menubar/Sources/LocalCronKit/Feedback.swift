// What a command tells the user when it finishes: the title and text of an
// alert, and the same words in the window footer.

import Foundation

public struct Feedback: Equatable, Sendable {
    public var title: String
    public var detail: String
    /// Shown as a warning, not as information.
    public var failed: Bool

    public init(title: String, detail: String, failed: Bool = false) {
        self.title = title
        self.detail = detail
        self.failed = failed
    }

    /// One line for the window footer.
    public var summary: String { detail.isEmpty ? title : "\(title). \(detail)" }

    public static func cliInstalled(link: URL, onPath: Bool, pathHint: String) -> Feedback {
        onPath
            ? Feedback(title: "Command line tool installed",
                       detail: "\(link.path) links to this app. Open a new terminal and run: \(link.lastPathComponent) list")
            : Feedback(title: "Command line tool installed",
                       detail: "\(link.path) links to this app, but \(link.deletingLastPathComponent().path) is not on PATH. Add it with:\n\(pathHint)")
    }

    public static func claudeInstalled(link: URL, claudeMD: URL, importAdded: Bool, mcp: ClaudeInstaller.MCPOutcome) -> Feedback {
        let note = importAdded
            ? "\(link.path) links to this app, and @\(link.lastPathComponent) is now the first line of \(claudeMD.path)."
            : "\(link.path) links to this app. \(claudeMD.path) already reads it."
        switch mcp {
        case .added:
            return Feedback(title: "Added to Claude Code",
                            detail: "\(note) The MCP server is added for your user. Start a new Claude Code session.")
        case .alreadyPresent:
            return Feedback(title: "Added to Claude Code",
                            detail: "\(note) The MCP server was already there. Start a new Claude Code session.")
        case let .claudeMissing(command):
            return Feedback(title: "The note is installed, the MCP server is not",
                            detail: "\(note) The claude command was not found. Run this in a terminal:\n\(command)", failed: true)
        case let .failed(command, output):
            return Feedback(title: "The note is installed, the MCP server is not",
                            detail: "\(note) This command failed: \(command)\n\(output)", failed: true)
        }
    }

    public static func noClaude(_ dir: URL) -> Feedback {
        Feedback(title: "Claude Code is not installed",
                 detail: "\(dir.path) does not exist. Install Claude Code, then try again.", failed: true)
    }

    public static func codexInstalled(link: URL, agentsMD: URL, instructionAdded: Bool, configTOML: URL, serverAdded: Bool) -> Feedback {
        let instruction = instructionAdded
            ? "An instruction to read it was added to \(agentsMD.path)."
            : "\(agentsMD.path) already tells Codex to read it."
        let server = serverAdded
            ? "The MCP server was added to \(configTOML.path)."
            : "\(configTOML.path) already has the MCP server."
        return Feedback(title: "Added to Codex",
                        detail: "\(link.path) links to this app. \(instruction) \(server) Start a new Codex session.")
    }

    public static func noCodex(_ dir: URL) -> Feedback {
        Feedback(title: "Codex home was not found",
                 detail: "\(dir.path) does not exist. Run Codex first, then try again.", failed: true)
    }

    public static func upToDate(version: String) -> Feedback {
        Feedback(title: "\(Instance.current.appName) is up to date", detail: "Version \(version) is the latest version.")
    }

    public static func updateAvailable(_ release: Updater.Release, current: String) -> Feedback {
        let name = Instance.current.appName
        return Feedback(title: "\(name) \(release.version) is available",
                        detail: "You have version \(current). \(name) restarts after the update. Running jobs are stopped.")
    }

    public static func failed(_ title: String, _ reason: String) -> Feedback {
        Feedback(title: title, detail: reason, failed: true)
    }
}
