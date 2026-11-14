import Foundation

/// The commands of the menu bar icon's right-click menu. The views only draw
/// it; what each command does is `Action`, run by StatusItemController.
public enum AppMenu {
    public enum Action: Hashable, Sendable {
        case openWindow, newJob
        /// Pause (true) or resume (false) every schedule.
        case setPaused(Bool)
        case showLog(String)
        /// Ask the user to allow the job (by id) to read its secrets.
        case allowSecrets(String)
        /// A run more of the job (by id); `runEarly` runs its next
        /// scheduled time now instead.
        case runNow(String), runEarly(String)
        case installCLI, installClaude, installCodex, copyMCPCommand
        case openLogsFolder, openHelp
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
        case submenu(title: String, symbol: String?, detail: String?, entries: [Entry])
    }

    /// The failed last run of a job, in the menu.
    public struct RunEntry: Equatable, Sendable {
        public var runID: String
        public var jobID: String
        /// "today 09:05, exit 2".
        public var detail: String?
        public init(runID: String, jobID: String, detail: String?) {
            self.runID = runID
            self.jobID = jobID
            self.detail = detail
        }
    }

    /// A job that may not read its secrets until the user allows it.
    public struct WaitingJob: Equatable, Sendable {
        public var jobID: String
        /// The secrets it names.
        public var secrets: [String]

        public init(jobID: String, secrets: [String]) {
            self.jobID = jobID
            self.secrets = secrets
        }
    }

    /// What the menu depends on; read again at each open.
    public struct Context: Sendable {
        public var appName: String
        public var cliInstalled: Bool
        /// "3 jobs, next: weekly-review in 2 days"; nil when the daemon is not running.
        public var summary: String?
        public var paused: Bool
        /// Jobs whose last run failed or timed out.
        public var failed: [RunEntry]
        /// Jobs waiting for the user to allow their secrets.
        public var waiting: [WaitingJob]
        /// Every job, for Run a Job Now.
        public var jobIDs: [String]

        public init(appName: String, cliInstalled: Bool, summary: String?, paused: Bool = false,
                    failed: [RunEntry] = [], waiting: [WaitingJob] = [], jobIDs: [String] = []) {
            self.appName = appName
            self.cliInstalled = cliInstalled
            self.summary = summary
            self.paused = paused
            self.failed = failed
            self.waiting = waiting
            self.jobIDs = jobIDs
        }
    }

    public static func entries(_ c: Context) -> [Entry] {
        var entries: [Entry] = [
            .item(Item(title: "Open \(c.appName)", symbol: "clock", action: .openWindow, detail: c.summary, emphasized: true)),
            .item(Item(title: "New Job…", symbol: "plus", action: .newJob, shortcut: "n")),
        ]
        if c.summary != nil {
            entries.append(c.paused
                ? .item(Item(title: "Resume All Jobs", symbol: "play.fill", action: .setPaused(false),
                             detail: "Times missed while paused are not run"))
                : .item(Item(title: "Pause All Jobs", symbol: "pause.fill", action: .setPaused(true),
                             detail: "No scheduled run starts")))
        }
        if !c.waiting.isEmpty {
            entries.append(.separator)
            entries.append(.header("Waiting for your OK"))
            for job in c.waiting {
                entries.append(.item(Item(title: "Allow Secrets for \(job.jobID)…", symbol: "key", action: .allowSecrets(job.jobID),
                                          detail: "Reads \(job.secrets.joined(separator: ", ")); runs fail until you allow it")))
            }
        }
        // A waiting job failed for that reason: its entry above says it.
        let waitingIDs = Set(c.waiting.map(\.jobID))
        let failed = c.failed.filter { !waitingIDs.contains($0.jobID) }
        if !failed.isEmpty {
            entries.append(.separator)
            entries.append(.header("Last run failed"))
            for run in failed {
                entries.append(.item(Item(title: run.jobID, symbol: "exclamationmark.triangle", action: .showLog(run.runID),
                                          detail: run.detail)))
            }
        }
        if c.summary != nil && !c.jobIDs.isEmpty {
            entries.append(.separator)
            entries.append(.submenu(title: "Run a Job Now", symbol: "play", detail: nil,
                                    entries: c.jobIDs.map { .item(Item(title: $0, action: .runNow($0))) }))
        }
        return entries + [
            .separator,
            .submenu(title: "Coding Agents", symbol: "sparkles", detail: nil, entries: [
                .item(Item(title: "Add to Claude Code…", symbol: "sparkles", action: .installClaude)),
                .item(Item(title: "Add to Codex…", symbol: "chevron.left.forwardslash.chevron.right", action: .installCodex)),
                .item(Item(title: "Install Command Line Tool…", symbol: "terminal", action: .installCLI, checked: c.cliInstalled)),
                .item(Item(title: "Copy MCP Command", symbol: "doc.on.doc", action: .copyMCPCommand)),
            ]),
            .item(Item(title: "Show Run Logs Folder", symbol: "folder", action: .openLogsFolder)),
            .item(Item(title: "Help", symbol: "questionmark.circle", action: .openHelp,
                       detail: "Every command, for you and your agents")),
            .item(Item(title: "Check for Updates…", symbol: "arrow.clockwise", action: .checkForUpdates)),
            .item(Item(title: "Settings…", symbol: "slider.horizontal.3", action: .settings, shortcut: ",")),
            .separator,
            .item(Item(title: "Quit \(c.appName)", action: .quit, shortcut: "q")),
        ]
    }
}
