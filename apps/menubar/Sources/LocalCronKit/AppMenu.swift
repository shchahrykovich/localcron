import Foundation

/// The commands of the menu bar icon's right-click menu. The views only draw
/// it; what each command does is `Action`, run by StatusItemController.
public enum AppMenu {
    public enum Action: Hashable, Sendable {
        case openWindow, newJob
        case installCLI, installClaude, installCodex, copyMCPCommand
        case openLogsFolder
        case checkForUpdates, settings, quit
    }

    public struct Item: Equatable, Sendable {
        public var title: String
        /// An SF Symbol name.
        public var symbol: String?
        public var action: Action
        /// Small text under the title.
        public var detail: String?
        /// A key that runs the item with ⌘.
        public var shortcut: String?
        public var checked = false
        public var emphasized = false
    }

    public indirect enum Entry: Equatable, Sendable {
        case item(Item)
        case header(String)
        case separator
        case submenu(title: String, symbol: String, entries: [Entry])
    }

    /// What the menu depends on; read again at each open.
    public struct Context: Sendable {
        public var appName: String
        public var cliInstalled: Bool
        /// "3 jobs, next: weekly-review in 2 days"; nil when the daemon is not running.
        public var summary: String?

        public init(appName: String, cliInstalled: Bool, summary: String?) {
            self.appName = appName
            self.cliInstalled = cliInstalled
            self.summary = summary
        }
    }

    public static func entries(_ c: Context) -> [Entry] {
        [
            .item(Item(title: "Open \(c.appName)", symbol: "clock", action: .openWindow, detail: c.summary, emphasized: true)),
            .item(Item(title: "New Job…", symbol: "plus", action: .newJob, shortcut: "n")),
            .separator,
            .header("Coding agents"),
            .item(Item(title: "Add to Claude Code…", symbol: "sparkles", action: .installClaude)),
            .item(Item(title: "Add to Codex…", symbol: "chevron.left.forwardslash.chevron.right", action: .installCodex)),
            .item(Item(title: "Install Command Line Tool…", symbol: "terminal", action: .installCLI, checked: c.cliInstalled)),
            .item(Item(title: "Copy MCP Command", symbol: "doc.on.doc", action: .copyMCPCommand)),
            .separator,
            .item(Item(title: "Show Run Logs Folder", symbol: "folder", action: .openLogsFolder)),
            .item(Item(title: "Check for Updates…", symbol: "arrow.clockwise", action: .checkForUpdates)),
            .item(Item(title: "Settings…", symbol: "slider.horizontal.3", action: .settings, shortcut: ",")),
            .separator,
            .item(Item(title: "Quit \(c.appName)", action: .quit, shortcut: "q")),
        ]
    }
}
