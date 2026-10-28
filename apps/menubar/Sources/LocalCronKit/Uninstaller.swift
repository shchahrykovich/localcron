// The file part of "Uninstall LocalCron…": the instance's data and logs
// folders, its CLI link, its notes and its Claude Code MCP server. The app
// unregisters the daemon itself. Another instance's files are never touched.

import Foundation

public struct Uninstaller {
    public var dataDir: URL
    public var logsDir: URL
    public var cli: CLIInstaller
    public var claude: ClaudeInstaller
    public var codex: CodexInstaller?

    /// The running instance's folders and links.
    public init(instance: Instance = .current) {
        self.init(dataDir: Paths.dataDir, logsDir: Paths.logsDir,
                  cli: CLIInstaller(instance: instance), claude: ClaudeInstaller(instance: instance),
                  codex: CodexInstaller(instance: instance))
    }

    public init(dataDir: URL, logsDir: URL, cli: CLIInstaller, claude: ClaudeInstaller, codex: CodexInstaller? = nil) {
        self.dataDir = dataDir
        self.logsDir = logsDir
        self.cli = cli
        self.claude = claude
        self.codex = codex
    }

    public func removeFiles() {
        let fm = FileManager.default
        try? fm.removeItem(at: dataDir)
        try? fm.removeItem(at: logsDir)
        cli.uninstall()
        claude.uninstall()
        codex?.uninstall()
    }
}
