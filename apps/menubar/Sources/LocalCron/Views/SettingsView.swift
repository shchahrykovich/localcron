import LocalCronKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, runs, agents, daemon, updates, help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .runs: "Runs"
        case .agents: "Coding Agents"
        case .daemon: "Daemon"
        case .updates: "Updates"
        case .help: "Help"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .runs: "play.rectangle"
        case .agents: "sparkles"
        case .daemon: "server.rack"
        case .updates: "arrow.down.circle"
        case .help: "questionmark.circle"
        }
    }
}

/// The Settings window: the pages on the left, the chosen page on the right.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    static let pageKey = "settingsPage"
    @AppStorage(SettingsView.pageKey) private var page: SettingsPage = .general
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: Binding(get: { page }, set: { if let p = $0 { page = p } })) {
                    ForEach(SettingsPage.allCases) { p in
                        HStack {
                            Label(p.title, systemImage: p.symbol)
                            if p == .daemon {
                                Spacer()
                                Circle().fill(model.running ? Theme.online : Theme.warning).frame(width: 6, height: 6)
                                    .accessibilityLabel(model.running ? "running" : "not running")
                            }
                        }
                        .badge(p == .updates && updateAvailable ? 1 : 0)
                        .tag(p)
                    }
                }
                .listStyle(.sidebar)
                Text("\(Instance.current.appName) \(model.version)")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .frame(width: 200)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.title).font(.system(size: 20, weight: .semibold))
                    switch page {
                    case .general: GeneralPage()
                    case .runs: RunsPage()
                    case .agents: AgentsPage(perform: perform)
                    case .daemon: DaemonPage()
                    case .updates: UpdatesPage(perform: perform)
                    case .help: HelpPage(perform: perform)
                    }
                }
                .padding(24)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.ground)
        }
        .disabled(model.busy)
        .tint(Theme.accentFill)
    }

    private var updateAvailable: Bool {
        if case .available = model.update { return true }
        return false
    }
}

/// A setting: its title and explanation on the left, its control on the right.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @State private var openAtLogin = OpenAtLogin().isOn

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 18) {
            Card {
                SettingRow(title: "Open at login", detail: "The daemon runs jobs without the app; the app shows them.") {
                    Toggle("", isOn: $openAtLogin).labelsHidden().toggleStyle(.switch)
                        .onChange(of: openAtLogin) { _, on in
                            if let problem = OpenAtLogin().choose(on) { model.say(problem, failed: true) }
                            openAtLogin = OpenAtLogin().isOn
                        }
                }
                if let note = OpenAtLogin().note {
                    RowDivider()
                    LinkButton(note) { model.openLoginItems() }.padding(14)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("The icon in the menu bar")
                Card {
                    ForEach(Array(IconStyle.allCases.enumerated()), id: \.element) { i, style in
                        if i > 0 { RowDivider() }
                        styleRow(style)
                    }
                    RowDivider()
                    SettingRow(title: "Show problems in color",
                               detail: "Green while a run works, red for a failed run, orange for a job that waits for your OK.") {
                        Toggle("", isOn: $model.iconColor).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
            Card(padding: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What every style keeps").font(.system(size: 12, weight: .semibold))
                    ForEach(["A click opens the window; a right click opens the menu.",
                             "A failed run stays shown until a run of that job ends well.",
                             "The tooltip lists everything that is going on.",
                             "A development build is orange."], id: \.self) {
                        Label($0, systemImage: "checkmark").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func styleRow(_ style: IconStyle) -> some View {
        let selected = model.iconStyle == style
        return Button {
            model.iconStyle = style
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.accent : .secondary)
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarIconRenderer.image(style: style, icon: model.statusIcon, colored: model.iconColor, dev: false))
                    if style == .clockText {
                        Text(model.statusIcon.label()).font(.system(size: 12).monospacedDigit())
                    }
                }
                .frame(width: 64, height: 24)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                    Text(style.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RunsPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ConsoleTerminal.defaultsKey) private var consoleTerminal = ""
    /// The choices of the log space, in MB.
    private static let budgets: [UInt32] = [100, 500, 1024, 5120]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let config = model.config {
                Card {
                    SettingRow(title: "Runs at the same time",
                               detail: "More runs wait in a queue. A job never runs twice at once: a second run is skipped.") {
                        Stepper("\(config.maxConcurrent)",
                                value: Binding(get: { Int(config.maxConcurrent) },
                                               set: { n in Task { await model.setConfig(maxConcurrent: UInt32(n)) } }),
                                in: 1...16)
                            .font(.system(size: 13).monospacedDigit())
                            .fixedSize()
                    }
                    RowDivider()
                    SettingRow(title: "Space for run logs",
                               detail: "When the logs use more, the oldest are deleted first. The newest run of each job is always kept.") {
                        Picker("", selection: Binding(get: { config.logBudgetMB },
                                                      set: { mb in Task { await model.setConfig(logBudgetMB: mb) } })) {
                            ForEach(budgetChoices(config.logBudgetMB), id: \.self) { Text(Formatting.bytes(UInt64($0) * 1024 * 1024)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if model.kittyURL != nil {
                        RowDivider()
                        SettingRow(title: "Open run consoles in",
                                   detail: "A Claude Code run works in a console you can watch and type into. It needs tmux.") {
                            Picker("", selection: Binding(
                                get: { ConsoleTerminal.chosen(saved: consoleTerminal, kittyInstalled: true) },
                                set: { consoleTerminal = $0.rawValue })) {
                                ForEach(ConsoleTerminal.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        }
                    }
                    RowDivider()
                    SettingRow(title: "Pause all jobs",
                               detail: "No scheduled run starts. Run Now still works. A time missed while paused is not caught up.") {
                        Toggle("", isOn: Binding(get: { model.paused }, set: { on in Task { await model.setPaused(on) } }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
            } else {
                Text("The daemon is not running: these settings are kept by it.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Run logs") { LinkButton("Show in Finder") { model.openLogsFolder() } }
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let logs = model.status?.logs {
                            Text("\(Formatting.bytes(logs.bytes)) of \(Formatting.bytes(logs.budgetBytes))")
                                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            ProgressView(value: min(1, Double(logs.bytes) / Double(max(1, logs.budgetBytes))))
                                .tint(Theme.accentFill)
                            Text(usageText(logs)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        if let status = model.status {
                            Text(JobGroups.tilde(status.logsDir + "/runs")).font(Theme.mono).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text("A secret's value never reaches a log: it shows as <secret NAME>.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The fixed choices, and the saved value when it is none of them (set
    /// with the CLI).
    private func budgetChoices(_ current: UInt32) -> [UInt32] {
        Self.budgets.contains(current) ? Self.budgets : (Self.budgets + [current]).sorted()
    }

    /// "212 logs. pr-review uses the most: 21 MB."
    private func usageText(_ logs: LogUsage) -> String {
        var text = logs.files == 1 ? "1 log." : "\(logs.files) logs."
        if let job = logs.largestJob, logs.files > 1 { text += " \(job) uses the most: \(Formatting.bytes(logs.largestJobBytes))." }
        return text
    }
}

private struct AgentsPage: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Claude Code and Codex add, change and run jobs through the \(Instance.current.appName) MCP server. They read a short note on how to use it.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Card {
                agentRow("Claude Code", detail: "Adds the MCP server and a note to ~/.claude/CLAUDE.md.", button: "Add", action: .installClaude)
                RowDivider()
                agentRow("Codex", detail: "Adds the MCP server to config.toml and a note to AGENTS.md.", button: "Add", action: .installCodex)
                RowDivider()
                agentRow("Command line tool",
                         detail: model.cliInstalled ? "Installed in ~/.local/bin." : "Links \(Instance.current.cli) into ~/.local/bin.",
                         button: model.cliInstalled ? "Reinstall" : "Install", action: .installCLI)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("MCP command, for another agent")
                CopyLine(text: model.mcpCommand)
            }
        }
    }

    /// The button's last result shows under it: when nothing changes (the
    /// tool is installed already), a click must still show that it worked.
    private func agentRow(_ title: String, detail: String, button: String, action: AppMenu.Action) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                if let result = model.agentResult, result.action == action {
                    Label(result.feedback.summary, systemImage: result.feedback.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(result.feedback.failed ? Theme.dangerText : Theme.successText)
                        .textSelection(.enabled)
                        .id(result.at)
                        .transition(.opacity)
                }
            }
            .animation(.easeIn(duration: 0.25), value: model.agentResult?.at)
            Spacer()
            SmallButton(button) { perform(action) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct DaemonPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                if let status = model.status {
                    SettingRow(title: "Version") { Text("\(status.daemonVersion), pid \(status.pid)").foregroundStyle(.secondary) }
                    RowDivider()
                    SettingRow(title: "Jobs") { Text("\(status.enabledJobs) on, \(status.jobs) in all").foregroundStyle(.secondary) }
                    RowDivider()
                    SettingRow(title: "Data") {
                        Text(JobGroups.tilde(status.dataDir)).font(Theme.mono).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } else {
                    SettingRow(title: "Not running", detail: model.daemonProblem) {
                        SmallButton("Start the Daemon", prominent: true) {
                            model.registerDaemon()
                            model.pollNow()
                        }
                    }
                }
            }
            if let note = model.serviceNote {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.warningText)
            }
            LinkButton("Open Login Items in System Settings") { model.openLoginItems() }
        }
    }
}

private struct UpdatesPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoUpdate") private var autoUpdate = true
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        Card {
            SettingRow(title: "Check for updates automatically", detail: "Every 6 hours. An update is installed only when you click it.") {
                Toggle("", isOn: $autoUpdate).labelsHidden().toggleStyle(.switch)
            }
            RowDivider()
            SettingRow(title: "\(Instance.current.appName) \(model.version)", detail: updateDetail) {
                updateControl
            }
        }
    }

    private var updateDetail: String? {
        switch model.update {
        case .upToDate: "Up to date."
        case let .failed(why): why
        case let .available(release): "Version \(release.version) is available."
        default: nil
        }
    }

    @ViewBuilder
    private var updateControl: some View {
        switch model.update {
        case .idle, .upToDate, .failed:
            SmallButton("Check for Updates") { perform(.checkForUpdates) }
        case .checking:
            ProgressView().controlSize(.small)
        case let .available(release):
            SmallButton("Install \(release.version)", prominent: true) { Task { await model.installUpdate(release) } }
        case let .downloading(release):
            HStack {
                ProgressView().controlSize(.small)
                Text("Installing \(release.version)…").font(.caption)
            }
        }
    }
}

private struct HelpPage: View {
    @Environment(AppModel.self) private var model
    let perform: (AppMenu.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Card {
                SettingRow(title: "Help", detail: "Every command and the agent instructions, in your browser. Copy as Markdown gives it to an agent.") {
                    SmallButton("Open") { perform(.openHelp) }
                }
            }
            Card {
                SettingRow(title: "Uninstall \(Instance.current.appName)",
                           detail: "Stops the daemon and deletes every job, run and log, the command line tool link, the notes and the Claude Code MCP server.") {
                    Button("Uninstall…", role: .destructive) {
                        if confirm("Uninstall \(Instance.current.appName)?",
                                   "This stops the daemon and deletes every job, run and log, the command line tool link, the notes and the Claude Code MCP server.",
                                   button: "Uninstall") {
                            Task { await model.uninstall() }
                        }
                    }
                }
                RowDivider()
                SettingRow(title: "Quit \(Instance.current.appName)", detail: "The daemon goes on running jobs.") {
                    SmallButton("Quit") { perform(.quit) }
                }
            }
        }
    }
}
